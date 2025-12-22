#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="$INSTALL_DIR/config.json"
CERT_DIR="$INSTALL_DIR/cert"
BIN="/usr/local/bin/sing-box"

BACKEND_LISTEN="127.0.0.1"
BACKEND_PORT=5443
DIRECT_PORT=443

need_root() {
  [[ $EUID -eq 0 ]] || { echo "❌ 请用 root 运行"; exit 1; }
}

install_deps() {
  apt update
  apt install -y curl unzip jq openssl ca-certificates
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    return
  fi
  local ver
  ver="$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')"
  curl -L -o /tmp/sb.tgz \
    "https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-amd64.tar.gz"
  tar -xzf /tmp/sb.tgz -C /tmp
  install /tmp/sing-box-*/sing-box "$BIN"
}

detect_existing() {
  command -v sing-box >/dev/null 2>&1 || systemctl list-unit-files | grep -q sing-box.service
}

uninstall_singbox() {
  echo "⚠️ 将卸载 sing-box"
  read -rp "确认？[y/N]: " c
  [[ "$c" =~ ^[Yy]$ ]] || exit 0
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -rf /etc/sing-box /etc/systemd/system/sing-box.service /usr/local/bin/sing-box
  systemctl daemon-reload
}

port_in_use() {
  ss -lnt | awk '{print $4}' | grep -qE "(:|\\.)$1$"
}

owner_443() {
  ss -lntp | awk '$4 ~ /:443$/ {print $0}' | grep -o '(".*")' | head -n1 | tr -d '"'
}

gen_cert() {
  mkdir -p "$CERT_DIR"
  [[ -f "$CERT_DIR/server.crt" ]] && return
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=anytls"
}

write_systemd() {
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box AnyTLS
After=network.target

[Service]
ExecStart=$BIN run -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
}

start_service() {
  systemctl reset-failed sing-box || true
  systemctl restart sing-box
}

direct_mode() {
  echo "🟢 443 空闲，直接部署 AnyTLS @443"
  mkdir -p "$INSTALL_DIR"
  gen_cert
  PASS="$(openssl rand -base64 24 | tr -d '\n')"

  cat > "$CONFIG_FILE" <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "password": "$PASS" }],
      "tls": {
        "enabled": true,
        "alpn": ["h2","http/1.1"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

  write_systemd
  start_service
  echo "✅ Surge:"
  echo "anytls, 服务器IP, 443, password=$PASS, tls=true, skip-cert-verify=true"
}

tsp_mode() {
  echo "🟡 443 被 tls-shunt-proxy 占用，走后端模式"
  read -rp "请输入 AnyTLS 子域名: " DOMAIN
  [[ -n "$DOMAIN" ]] || exit 1

  mkdir -p "$INSTALL_DIR"
  gen_cert
  PASS="$(openssl rand -base64 24 | tr -d '\n')"

  cat > "$CONFIG_FILE" <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "listen": "$BACKEND_LISTEN",
      "listen_port": $BACKEND_PORT,
      "users": [{ "password": "$PASS" }],
      "tls": {
        "enabled": true,
        "alpn": ["h2","http/1.1"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

  write_systemd
  start_service

  echo "👉 TSP vhost:"
  cat <<EOF
- name: $DOMAIN
  tlsoffloading: true
  managedcert: true
  alpn: h2,http/1.1
  trojan:
    handler: proxyPass
    args: 127.0.0.1:$BACKEND_PORT
EOF

  echo "👉 Surge:"
  echo "anytls, $DOMAIN, 443, password=$PASS, tls=true, sni=$DOMAIN"
}

main() {
  need_root
  install_deps
  install_singbox

  if detect_existing; then
    echo "检测到已安装 sing-box"
    echo "1) 退出  2) 重装  3) 卸载重来"
    read -rp "请选择 [1/2/3]: " c
    case "$c" in
      1|"") exit 0 ;;
      2) systemctl stop sing-box || true ;;
      3) uninstall_singbox ;;
    esac
  fi

  if port_in_use 443; then
    [[ "$(owner_443)" == "tls-shunt-proxy" ]] || { echo "❌ 443 被其他进程占用"; exit 1; }
    tsp_mode
  else
    direct_mode
  fi
}

main
