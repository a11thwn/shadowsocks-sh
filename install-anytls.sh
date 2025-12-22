#!/usr/bin/env bash
set -euo pipefail

# =========================
# AnyTLS Smart Installer
# - If 443 free: run AnyTLS directly on 443
# - If 443 used by tls-shunt-proxy: run AnyTLS backend on 127.0.0.1:5443 and output TSP vhost snippet
# =========================

INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="$INSTALL_DIR/config.json"
CERT_DIR="$INSTALL_DIR/cert"
BIN="/usr/local/bin/sing-box"

BACKEND_LISTEN="127.0.0.1"
BACKEND_PORT="${ANYTLS_BACKEND_PORT:-5443}"   # only used when 443 is occupied by tls-shunt-proxy
DIRECT_PORT=443                                # direct mode listens on 443

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ 请用 root 运行：sudo bash $0"
    exit 1
  fi
}

install_deps() {
  apt update
  apt install -y curl unzip jq openssl ca-certificates
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "✅ sing-box 已安装：$(sing-box version 2>/dev/null || true)"
    return
  fi

  echo "📦 安装 sing-box..."
  local latest arch url
  latest="$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')"
  arch="amd64"
  url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${latest#v}-linux-${arch}.tar.gz"

  curl -L -o /tmp/sing-box.tar.gz "$url"
  tar -xzf /tmp/sing-box.tar.gz -C /tmp
  install /tmp/sing-box-*/sing-box "$BIN"
}

write_systemd() {
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box AnyTLS Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${BIN} run -c ${CONFIG_FILE}
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
}

reset_and_restart() {
  systemctl reset-failed sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
}

port443_owner() {
  # returns empty if not listening; otherwise prints process name like tls-shunt-proxy/nginx/...
  ss -lntp 2>/dev/null | awk '$4 ~ /:443$/ {print $0}' | head -n1 | sed -n 's/.*users:((".*",pid=.*/\1/p' | tr -d '"'
}

is_listening_443() {
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(:|\.)443$'
}

gen_self_signed_cert() {
  mkdir -p "$CERT_DIR"
  if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
    return
  fi
  echo "🔐 生成自签证书..."
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=anytls"
}

check_port_free_or_exit() {
  local port="$1"
  if ss -lnt | awk '{print $4}' | grep -qE "(:|\\.)${port}\$"; then
    echo "❌ 端口 ${port} 已被占用，无法继续。"
    ss -lntp | grep ":${port}" || true
    exit 1
  fi
}

direct_mode() {
  echo ""
  echo "🟢 检测到 443 空闲：将直接在 443 部署 AnyTLS（无需 tls-shunt-proxy）"
  echo "--------------------------------------------------"

  mkdir -p "$INSTALL_DIR"
  local password
  password="$(openssl rand -base64 24 | tr -d '\n')"

  echo "请选择证书模式："
  echo "1) 自签证书（最快，Surge 需要 skip-cert-verify=true）"
  echo "2) ACME/Let's Encrypt（推荐生产，需要域名解析到本机，并且通常需要 80 可用）"
  read -r -p "请选择 [1/2] (默认1): " mode
  mode="${mode:-1}"

  if [[ "$mode" == "2" ]]; then
    # 这里做一个现实检查：80 是否已被占用
    if ss -lnt | awk '{print $4}' | grep -qE '(:|\.)80$'; then
      echo "⚠️ 检测到 80 已被占用：ACME 可能无法走 HTTP-01 验证。"
      echo "   建议：改用自签(选1)，或释放 80 后再用 ACME。"
      exit 1
    fi

    read -r -p "请输入域名（A/AAAA 已解析到本机）: " domain
    read -r -p "请输入邮箱（ACME 用）: " email
    if [[ -z "$domain" || -z "$email" ]]; then
      echo "❌ 域名/邮箱不能为空"
      exit 1
    fi

    # 注意：sing-box 的 ACME 配置字段随版本可能略有差异；
    # 这里给出常见结构。如你的版本字段不匹配，sing-box check 会直接提示。
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${DIRECT_PORT},
      "users": [
        { "name": "surge", "password": "${password}" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h2", "http/1.1"],
        "acme": {
          "domain": "${domain}",
          "email": "${email}"
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

    echo ""
    echo "✅ 生成配置：AnyTLS(443) + ACME"
    echo "📲 Surge 节点："
    echo "HK-AnyTLS = anytls, ${domain}, 443, password=${password}, tls=true, sni=${domain}, alpn=h2,http/1.1"

  else
    gen_self_signed_cert
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${DIRECT_PORT},
      "users": [
        { "name": "surge", "password": "${password}" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h2", "http/1.1"],
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

    echo ""
    echo "✅ 生成配置：AnyTLS(443) + 自签证书"
    echo "📲 Surge 节点（自签必须跳过校验）："
    echo "HK-AnyTLS = anytls, 服务器IP, 443, password=${password}, tls=true, skip-cert-verify=true, alpn=h2,http/1.1"
  fi

  write_systemd

  echo ""
  echo "🔎 配置校验："
  sing-box check -c "$CONFIG_FILE"

  reset_and_restart
  echo ""
  systemctl status sing-box --no-pager -l || true
  ss -lntp | egrep ':443|sing-box' || true
}

tsp_backend_mode() {
  echo ""
  echo "🟡 检测到 443 被 tls-shunt-proxy 占用：将部署 AnyTLS 后端（由 TSP 443 分流）"
  echo "--------------------------------------------------"

  mkdir -p "$INSTALL_DIR"

  # backend port must be free
  check_port_free_or_exit "$BACKEND_PORT"

  read -r -p "请输入 AnyTLS 使用的子域名（例如 anytls.kr.132202.xyz）: " anytls_domain
  if [[ -z "$anytls_domain" ]]; then
    echo "❌ 子域名不能为空"
    exit 1
  fi

  local password
  password="$(openssl rand -base64 24 | tr -d '\n')"

  # backend TLS needs cert, otherwise missing certificate
  gen_self_signed_cert

  cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "${BACKEND_LISTEN}",
      "listen_port": ${BACKEND_PORT},
      "users": [
        { "name": "surge", "password": "${password}" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h2", "http/1.1"],
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

  write_systemd

  echo ""
  echo "🔎 配置校验："
  sing-box check -c "$CONFIG_FILE"

  reset_and_restart

  echo ""
  echo "✅ AnyTLS 后端已启动：${BACKEND_LISTEN}:${BACKEND_PORT}"
  echo "--------------------------------------"
  echo "🧩 把下面 vhost 追加到 /etc/tls-shunt-proxy/config.yaml 的 vhosts: 下"
  echo "--------------------------------------"
  cat <<TPL
  - name: ${anytls_domain}
    tlsoffloading: true
    managedcert: true
    keytype: p256
    alpn: h2,http/1.1
    protocols: tls12,tls13
    trojan:
      handler: proxyPass
      args: 127.0.0.1:${BACKEND_PORT}
TPL
  echo "--------------------------------------"
  echo ""
  echo "📲 Surge 节点（外部仍用 443）："
  echo "HK-AnyTLS = anytls, ${anytls_domain}, 443, password=${password}, tls=true, sni=${anytls_domain}, alpn=h2,http/1.1"
  echo ""
  echo "✅ 服务状态："
  systemctl status sing-box --no-pager -l || true
  ss -lntp | egrep ":${BACKEND_PORT}|sing-box" || true
}

main() {
  need_root
  install_deps
  install_singbox

  if is_listening_443; then
    owner="$(port443_owner)"
    echo "ℹ️ 443 端口当前被占用：${owner:-<未知进程>}"
    if [[ "$owner" == "tls-shunt-proxy" ]]; then
      tsp_backend_mode
    else
      echo "❌ 443 被其他进程占用（${owner:-unknown}），脚本不会强行改动。"
      echo "   建议：要么释放 443，要么也用分流方式把 AnyTLS 接入该前置（需要按你的前置类型定制）。"
      exit 1
    fi
  else
    direct_mode
  fi
}

main "$@"
