#!/usr/bin/env bash
set -e

CERT_BASE="/etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
SB_CERT_DIR="/etc/sing-box/cert"
SB_SERVICE="/etc/systemd/system/sing-box.service"
DEFAULT_PASSWORD="qwertyuiop222"
PORT_START=5443

echo "====== AnyTLS + TSP 一键部署（deployX 逻辑版） ======"

### 1. 校验 443 必须被 TSP 占用
if ! ss -lntp '( sport = :443 )' | grep -q tls-shunt-proxy; then
  echo "[FATAL] 443 未被 tls-shunt-proxy 占用，退出"
  exit 1
fi

### 2. 输入参数
read -rp "请输入 AnyTLS 域名（例如 yourdomain.com）: " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "[FATAL] 域名不能为空"; exit 1; }

read -rp "请输入 AnyTLS 密码（默认 ${DEFAULT_PASSWORD}，回车）: " PASSWORD
PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"

### 3. 选择后端端口
PORT=$PORT_START
while ss -lnt "( sport = :$PORT )" | grep -q LISTEN; do
  PORT=$((PORT+1))
done
echo "[OK] 使用后端端口: $PORT"

### 4. 重装 sing-box
systemctl stop sing-box 2>/dev/null || true
rm -f "$SB_BIN"
curl -fsSL https://sing-box.app/install.sh | bash

mkdir -p /etc/sing-box "$SB_CERT_DIR"

### 5. 修改 TSP vhost
TSP_CONF="/etc/tls-shunt-proxy/config.yaml"
cp "$TSP_CONF" "${TSP_CONF}.bak.$(date +%s)"

if grep -q "name: ${DOMAIN}" "$TSP_CONF"; then
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
echo "[OK] TSP 已重启"

### ⭐ 6. 主动触发 ACME（deployX 核心）
echo "[INFO] 主动触发一次 TLS SNI 握手以启动 ACME..."
timeout 5 bash -c "
  echo | openssl s_client \
    -connect 127.0.0.1:443 \
    -servername ${DOMAIN} \
    -alpn h2 \
    >/dev/null 2>&1
" || true

### 7. 等待证书生成
CERT_DIR="${CERT_BASE}/${DOMAIN}"
echo "[INFO] 等待证书生成（最多 120 秒）..."
for i in {1..120}; do
  if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    echo "[OK] 证书已生成"
    break
  fi
  sleep 1
done

[[ ! -f "${CERT_DIR}/fullchain.pem" ]] && {
  echo "[FATAL] 证书仍未生成，请检查 TSP ACME 日志"
  exit 1
}

ln -sf "${CERT_DIR}/fullchain.pem" "${SB_CERT_DIR}/server.crt"
ln -sf "${CERT_DIR}/privkey.pem"   "${SB_CERT_DIR}/server.key"

### 8. 写 sing-box 配置
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
  "outbounds": [ { "type": "direct" } ]
}
EOF

sing-box check -c "$SB_CONF"

### 9. systemd
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

### 10. 证书 30 天内到期才重启
cat >/etc/cron.d/tsp-cert-renew <<EOF
0 6 * * * root \
openssl x509 -checkend \$((30*86400)) -noout -in ${CERT_DIR}/fullchain.pem || \
(systemctl restart tls-shunt-proxy && systemctl restart sing-box)
EOF

echo
echo "====== 部署完成 ======"
echo "Surge 节点："
echo "hk3-anytls 🇭🇰 = anytls, ${DOMAIN}, 443, password=${PASSWORD}, tls=true, sni=${DOMAIN}, alpn=h2, skip-cert-verify=false"
