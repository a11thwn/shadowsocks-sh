#!/usr/bin/env bash
# One-key: AnyTLS (sing-box) behind tls-shunt-proxy (TSP) with:
# - TSP: managedcert (Let's Encrypt) + SNI vhost
# - AnyTLS: listens on 127.0.0.1:<auto_port>, uses TSP-issued domain cert/key
# - Auto: systemd .path watches cert/key changes -> restart sing-box
# - Auto: cron weekly check: if cert expires within 30 days -> restart TSP
#
# Defaults requested:
# - AnyTLS password default: qwertyuiop222 (press Enter to accept)
# - Surge output includes: skip-cert-verify=false
#
# Paths:
# - TSP config: /etc/tls-shunt-proxy/config.yaml
# - TSP cert dir (deployX default): /etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory
# - sing-box bin: /usr/local/bin/sing-box
# - sing-box config: /etc/sing-box/config.json

set -euo pipefail

OK="\033[32m[OK]\033[0m"
WARN="\033[33m[WARN]\033[0m"
ERR="\033[31m[ERR]\033[0m"

TSP_CFG="/etc/tls-shunt-proxy/config.yaml"
SBOX_CFG="/etc/sing-box/config.json"
SBOX_BIN="/usr/local/bin/sing-box"

SBOX_PORT_DEFAULT="5443"
DEFAULT_PASS="qwertyuiop222"

# From deployX.sh (h31105) default:
TSP_CERT_DIR="/etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${ERR} 请用 root 运行"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo -e "${ERR} 缺少命令: $1"; exit 1; }
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${OK} 已备份 $f"
  fi
}

prompt_inputs() {
  read -rp "请输入 AnyTLS 域名（例如 yourdomain.com）: " DOMAIN
  DOMAIN="$(echo "${DOMAIN:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  if [[ -z "$DOMAIN" ]]; then
    echo -e "${ERR} 域名不能为空"
    exit 1
  fi

  read -rp "请输入 AnyTLS 密码（默认 ${DEFAULT_PASS}，直接回车）: " PASS
  PASS="$(echo "${PASS:-}" | xargs)"
  if [[ -z "$PASS" ]]; then
    PASS="$DEFAULT_PASS"
  fi
}

# Return 0 if port is free, 1 if occupied
port_free() {
  local p="$1"
  if ss -lntp 2>/dev/null | grep -qE ":[[:space:]]*$p\\b|:$p[[:space:]]"; then
    return 1
  fi
  return 0
}

pick_sbox_port() {
  local start="${1:-5443}"
  local p="$start"
  local max=200
  for _ in $(seq 1 "$max"); do
    if port_free "$p"; then
      echo "$p"
      return 0
    fi
    p=$((p+1))
  done
  echo -e "${ERR} 从 $start 起连续 $max 个端口都被占用，无法选择可用端口" >&2
  exit 1
}

ensure_dirs() {
  mkdir -p /etc/sing-box
}

ensure_tsp_config() {
  if [[ ! -f "$TSP_CFG" ]]; then
    echo -e "${ERR} 未找到 $TSP_CFG，请确认 tls-shunt-proxy 已安装且配置存在"
    exit 1
  fi

  backup_file "$TSP_CFG"

  # If vhost not exist -> append new vhost for AnyTLS
  if ! grep -qE "^[[:space:]]*-[[:space:]]*name:[[:space:]]*$DOMAIN([[:space:]]*#.*)?$" "$TSP_CFG"; then
    echo -e "${WARN} 未找到 vhost: $DOMAIN，开始追加..."
    cat >>"$TSP_CFG" <<EOF

  - name: $DOMAIN
    tlsoffloading: false
    managedcert: true
    keytype: p256
    alpn: h2,http/1.1
    protocols: tls12,tls13
    default:
      handler: proxyPass
      args: 127.0.0.1:$SBOX_PORT
EOF
  else
    echo -e "${OK} 已找到 vhost: $DOMAIN，开始修正为 AnyTLS 透传模式（tlsoffloading:false + default->127.0.0.1:${SBOX_PORT}）"

    export DOMAIN SBOX_PORT
    perl -0777 -i -pe '
      s{
        (\n[ ]{2}-[ ]name:[ ]\Q$ENV{"DOMAIN"}\E\b[\s\S]*?)(?=\n[ ]{2}-[ ]name:|\z)
      }{
        my $blk = $1;

        # tlsoffloading -> false (insert if missing)
        if ($blk =~ /\n[ ]{4}tlsoffloading:/) {
          $blk =~ s/\n[ ]{4}tlsoffloading:[^\n]*/\n    tlsoffloading: false/g;
        } else {
          $blk =~ s/(\n[ ]{2}-[ ]name:[^\n]*\n)/$1."    tlsoffloading: false\n"/e;
        }

        # managedcert -> true (insert if missing)
        if ($blk =~ /\n[ ]{4}managedcert:/) {
          $blk =~ s/\n[ ]{4}managedcert:[^\n]*/\n    managedcert: true/g;
        } else {
          $blk =~ s/(\n[ ]{4}tlsoffloading:[^\n]*\n)/$1."    managedcert: true\n"/e;
        }

        # Ensure default proxyPass to 127.0.0.1:<SBOX_PORT>
        if ($blk =~ /\n[ ]{4}default:/) {
          $blk =~ s/(\n[ ]{4}default:[\s\S]*?\n[ ]{6}args:[ ])([^\n]*)/$1."127.0.0.1:$ENV{SBOX_PORT}"/e;
        } else {
          # remove possible trojan handler block (common 3 lines)
          $blk =~ s/\n[ ]{4}trojan:\n[ ]{6}handler:[^\n]*\n[ ]{6}args:[^\n]*//g;
          # append default block
          $blk .= "\n    default:\n      handler: proxyPass\n      args: 127.0.0.1:$ENV{SBOX_PORT}\n";
        }

        $blk
      }gsxe
    ' "$TSP_CFG"
  fi
}

restart_tsp() {
  echo -e "${OK} 重启 tls-shunt-proxy..."
  systemctl restart tls-shunt-proxy
  if systemctl is-active --quiet tls-shunt-proxy; then
    echo -e "${OK} tls-shunt-proxy 已启动"
  else
    echo -e "${ERR} tls-shunt-proxy 启动失败，请查看：journalctl -u tls-shunt-proxy -n 200 --no-pager"
    exit 1
  fi
}

find_tsp_cert() {
  if [[ ! -d "$TSP_CERT_DIR" ]]; then
    echo -e "${ERR} 找不到 TSP 证书目录：$TSP_CERT_DIR"
    echo -e "${ERR} 如果 deployX 改了路径，你需要改脚本里的 TSP_CERT_DIR"
    exit 1
  fi

  CERT_PATH="$(find "$TSP_CERT_DIR" -type f \( -iname "*${DOMAIN}*fullchain*.pem" -o -iname "*${DOMAIN}*fullchain*.crt" -o -name "${DOMAIN}.crt" -o -name "${DOMAIN}.pem" -o -name "*${DOMAIN}*.crt" -o -name "*${DOMAIN}*.pem" \) 2>/dev/null | head -n 1 || true)"
  KEY_PATH="$(find "$TSP_CERT_DIR" -type f \( -name "${DOMAIN}.key" -o -name "*${DOMAIN}*.key" -o -iname "*${DOMAIN}*privkey*.pem" \) 2>/dev/null | head -n 1 || true)"

  if [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
    echo -e "${WARN} 未在 $TSP_CERT_DIR 找到 $DOMAIN 的证书/私钥。"
    echo -e "${WARN} 请确认："
    echo "  1) $DOMAIN 的 DNS A 记录指向本机公网 IP"
    echo "  2) 443 端口外网可达且 SNI 命中该 vhost"
    echo "  3) 重启 TSP 后等待 10~60 秒再试"
    echo -e "${WARN} 可用命令：journalctl -u tls-shunt-proxy -n 200 --no-pager | grep -iE \"obtain|certificate|acme\""
    exit 1
  fi

  echo -e "${OK} 找到证书：$CERT_PATH"
  echo -e "${OK} 找到私钥：$KEY_PATH"
}

write_singbox_config() {
  if [[ ! -x "$SBOX_BIN" ]]; then
    echo -e "${ERR} 未找到 sing-box 可执行文件：$SBOX_BIN"
    exit 1
  fi

  backup_file "$SBOX_CFG"

  cat >"$SBOX_CFG" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "127.0.0.1",
      "listen_port": $SBOX_PORT,
      "users": [
        { "name": "surge", "password": "$PASS" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h2","http/1.1"],
        "certificate_path": "$CERT_PATH",
        "key_path": "$KEY_PATH"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

  "$SBOX_BIN" check -c "$SBOX_CFG"
  echo -e "${OK} sing-box 配置检查通过"
}

ensure_singbox_service() {
  if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
    echo -e "${WARN} 未找到 /etc/systemd/system/sing-box.service，创建一个..."
    cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box AnyTLS Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=1s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable --now sing-box
  systemctl restart sing-box

  if systemctl is-active --quiet sing-box; then
    echo -e "${OK} sing-box 已启动"
  else
    echo -e "${ERR} sing-box 启动失败：journalctl -u sing-box -n 200 --no-pager"
    exit 1
  fi
}

install_cert_watcher() {
  # Ensure path exists
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    echo -e "${ERR} 证书/私钥文件不存在，无法创建 watcher："
    echo "  CERT=$CERT_PATH"
    echo "  KEY=$KEY_PATH"
    exit 1
  fi

  cat >/etc/systemd/system/sing-box-cert-reload.service <<EOF
[Unit]
Description=Restart sing-box when TLS cert/key changes

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart sing-box
EOF

  cat >/etc/systemd/system/sing-box-cert-reload.path <<EOF
[Unit]
Description=Watch AnyTLS cert/key and restart sing-box

[Path]
PathChanged=$CERT_PATH
PathChanged=$KEY_PATH

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now sing-box-cert-reload.path

  if systemctl is-active --quiet sing-box-cert-reload.path; then
    echo -e "${OK} 已启用证书变更监控：证书更新后自动重启 sing-box"
  else
    echo -e "${ERR} sing-box-cert-reload.path 启动失败：systemctl status sing-box-cert-reload.path -l --no-pager"
    exit 1
  fi
}

install_tsp_renew_check_script() {
  local CHECK_SCRIPT="/usr/local/bin/tsp-renew-check.sh"
  cat >"$CHECK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
CERT_DIR="/etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory"

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: tsp-renew-check.sh yourdomain.com"
  exit 2
fi

CRT="$(find "$CERT_DIR" -type f \
  \( -iname "*${DOMAIN}*fullchain*.pem" -o -iname "*${DOMAIN}*fullchain*.crt" -o -name "${DOMAIN}.crt" -o -name "${DOMAIN}.pem" -o -name "*${DOMAIN}*.crt" -o -name "*${DOMAIN}*.pem" \) \
  2>/dev/null | head -n 1 || true)"

if [[ -z "$CRT" ]]; then
  echo "[WARN] Certificate for $DOMAIN not found in $CERT_DIR, skip."
  exit 0
fi

# If cert expires within 30 days -> restart TSP (to trigger/refresh maintenance)
if openssl x509 -checkend $((30*24*3600)) -noout -in "$CRT" >/dev/null 2>&1; then
  echo "[OK] $DOMAIN certificate valid > 30 days, no action."
else
  echo "[ACTION] $DOMAIN certificate expires within 30 days, restarting tls-shunt-proxy..."
  systemctl restart tls-shunt-proxy
fi
EOF
  chmod +x "$CHECK_SCRIPT"
  echo -e "${OK} 已创建证书到期检查脚本：$CHECK_SCRIPT"
}

setup_cron_job() {
  # Weekly at 04:30 Sunday (server local time)
  local CRON_LINE="30 4 * * 0 /usr/local/bin/tsp-renew-check.sh $DOMAIN >> /var/log/tsp-renew-check.log 2>&1"

  if crontab -l 2>/dev/null | grep -Fq "$CRON_LINE"; then
    echo -e "${OK} cron 任务已存在，跳过"
  else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo -e "${OK} 已添加 cron：每周检查证书是否 30 天内过期（是则重启 TSP）"
  fi
}

print_surge_line() {
  echo
  echo "======================"
  echo "Surge 节点（推荐写法）"
  echo "======================"
  echo "hk3-anytls 🇭🇰 = anytls, $DOMAIN, 443, password=$PASS, tls=true, sni=$DOMAIN, alpn=h2, skip-cert-verify=false"
  echo
}

post_checks() {
  echo -e "${OK} 监听检查（443/80/TSP + AnyTLS 本地端口）："
  ss -lntp | egrep ':443|:80|:'"$SBOX_PORT"'|tls-shunt-proxy|sing-box' || true

  echo
  echo -e "${OK} systemd watcher 状态："
  systemctl status sing-box-cert-reload.path --no-pager -l || true

  echo
  echo -e "${OK} 近期日志（tls-shunt-proxy）："
  journalctl -u tls-shunt-proxy -n 30 --no-pager || true

  echo
  echo -e "${OK} 近期日志（sing-box）："
  journalctl -u sing-box -n 30 --no-pager || true
}

main() {
  need_root
  need_cmd perl
  need_cmd find
  need_cmd systemctl
  need_cmd ss
  need_cmd openssl

  prompt_inputs

  # Choose backend port (default 5443, auto-find if occupied)
  if port_free "$SBOX_PORT_DEFAULT"; then
    SBOX_PORT="$SBOX_PORT_DEFAULT"
  else
    echo -e "${WARN} 端口 $SBOX_PORT_DEFAULT 已被占用，自动寻找可用端口..."
    SBOX_PORT="$(pick_sbox_port "$SBOX_PORT_DEFAULT")"
  fi
  echo -e "${OK} 使用 sing-box 后端端口: $SBOX_PORT"

  ensure_dirs
  ensure_tsp_config
  restart_tsp

  # Cert may not exist until ACME completes; fail-fast with guidance if missing
  find_tsp_cert

  write_singbox_config
  ensure_singbox_service

  # Guarantee: cert/key changes -> restart sing-box
  install_cert_watcher

  # Cron weekly check: if cert expires within 30 days -> restart TSP
  install_tsp_renew_check_script
  setup_cron_job

  print_surge_line
  post_checks

  echo -e "${OK} 完成。现在用 Surge 测试节点即可。"
}

main
