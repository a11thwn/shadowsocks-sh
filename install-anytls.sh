#!/usr/bin/env bash
set -e

### ===== 基本变量 =====
CERT_BASE="/etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
SB_CERT_DIR="/etc/sing-box/cert"
SB_SERVICE="/etc/systemd/system/sing-box.service"
DEFAULT_PASSWORD="qwertyuiop222"
PORT_START=5443

echo "====== AnyTLS + TSP 一键部署 ======"

### ===== 1. 校验 443 必须被 tls-shunt-proxy 占用 =====
if ! ss -lntp '( sport = :443 )' | grep -q tls-shunt-proxy; then
  echo "[FATAL] 443 端口未被 tls-shunt-proxy 占用，脚本终止。"
  echo "请先手工安装并启动 tls-shunt-proxy。"
  exit 1
fi
echo "[OK] 确认 443 由 tls-shunt-proxy 占用"

### ===== 2. 读取参数 =====
read -rp "请输入 AnyTLS 域名（例如 yourdomain.com）: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "[FATAL] 域名不能为空"
  exit 1
fi

read -rp "请输入 AnyTLS 密码（默认 ${DEFAULT_PASSWORD}，直接回车）: " PASSWORD
PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"

### ===== 3. 选择可用端口 =====
PORT=$PORT_START
while ss -lnt "( sport = :$PORT )" | grep -q LISTEN; do
  PORT=$((PORT+1))
done
echo "[OK] 使用 sing-box 后端端口: $PORT"

### ===== 4. 重装 sing-box =====
echo "[INFO] 安装 / 重装 sing-box..."
systemctl stop sing-box 2>/dev/null || true
rm -f "$SB_BIN"

curl -fsSL https://sing-box.app/install.sh | bash
command -v sing-box >/dev/null || { echo "[FATAL] sing-box 安装失败"; exit 1; }

mkdir -p /etc/sing-box "$SB_CERT_DIR"

### ===== 5. 修改 TSP 配置 =====
TSP_CONF="/etc/tls-shunt-proxy/config.yaml"
cp "$TSP_CONF" "${TSP_CONF}.bak.$(date +%s)"
echo "[OK] 已备份 $TSP_CONF"

if grep -q "name: ${DOMAIN}" "$TSP_CONF"; then
  echo "[OK] 已找到 vhost: ${DOMAIN}，修正为 AnyTLS 透传模式"
  sed -i "/name: ${DOMAIN}/,/^[^ ]/c\\
  - name: ${DOMAIN}\n\
    tlsoffloading: false\n\
    managedcert: true\n\
    alpn: h2,http/1.1\n\
    protocols: tls12,tls13\n\
    default:\n\
      handler: proxyPass\n\
      args: 127.0.0.1:${PORT}" "$TSP_CONF"
else
  echo "[OK] 新增 vhost: ${DOMAIN}"
  cat >>"$TSP_CONF" <<EOF

  - name: ${DOMAIN}
    tlsoffloading: false
    managedcert: true
    alpn: h2,http/1.1
    protocols: tls12,tls13
    default:
      handler: proxyPass
      args: 127.0.0.1:${PORT}
EOF
fi

systemctl restart tls-shunt-proxy
echo "[OK] tls-shunt-proxy 已重启"

### ===== 6. 等待证书生成 =====
CERT_DIR="${CERT_BASE}/${DOMAIN}"
echo "[INFO] 等待证书生成（最多 120 秒）..."
for i in {1..120}; do
  if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    echo "[OK] 证书已生成"
    break
  fi
  sleep 1
done

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  echo "[FATAL] 未检测到证书生成，请检查："
  echo "journalctl -u tls-shunt-proxy -n 200 --no-pager | grep -i acme"
  exit 1
fi

ln -sf "${CERT_DIR}/fullchain.pem" "${SB_CERT_DIR}/server.crt"
ln -sf "${CERT_DIR}/privkey.pem"   "${SB_CERT_DIR}/server.key"

### ===== 7. 写 sing-box 配置 =====
cat >"$SB_CONF" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "127.0.0.1",
      "listen_port": ${PORT},
      "users": [
        { "name": "surge", "password": "${PASSWORD}" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h2","http/1.1"],
        "certificate_path": "${SB_CERT_DIR}/server.crt",
        "key_path": "${SB_CERT_DIR}/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

sing-box check -c "$SB_CONF"

### ===== 8. systemd 服务 =====
cat >"$SB_SERVICE" <<EOF
[Unit]
Description=sing-box AnyTLS Service
After=network.target

[Service]
ExecStart=${SB_BIN} run -c ${SB_CONF}
Restart=on-failure
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

### ===== 9. 证书 30 天内到期才重启 TSP =====
CRON="/etc/cron.d/tsp-cert-renew"
cat >"$CRON" <<EOF
0 6 * * * root \
openssl x509 -checkend \$((30*86400)) -noout -in ${CERT_DIR}/fullchain.pem || \
(systemctl restart tls-shunt-proxy && systemctl restart sing-box)
EOF

echo "====== 完成 ======"
echo
echo "Surge 节点配置："
echo "hk3-anytls 🇭🇰 = anytls, ${DOMAIN}, 443, password=${PASSWORD}, tls=true, sni=${DOMAIN}, alpn=h2, skip-cert-verify=false"
