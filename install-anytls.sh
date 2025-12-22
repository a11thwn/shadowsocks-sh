#!/usr/bin/env bash
set -e

### ===== 固定参数 =====
SB_CONF="/etc/sing-box/config.json"
SB_CERT_DIR="/etc/sing-box/cert"
SB_SERVICE="/etc/systemd/system/sing-box.service"

DEFAULT_PASSWORD="qwertyuiop222"
PORT_START=5443

echo "====== AnyTLS + TSP 安装（deployX 原味流程） ======"

### ===== 1. 必须由 TSP 占用 443 =====
if ! ss -lntp '( sport = :443 )' | grep -q tls-shunt-proxy; then
  echo "[FATAL] 443 端口未被 tls-shunt-proxy 占用"
  echo "请先手工安装并启动 tls-shunt-proxy"
  echo "脚本地址（修改版）：https://raw.githubusercontent.com/a11thwn/shadowsocks-sh/refs/heads/master/deploy.sh"
  exit 1
fi
echo "[OK] 443 已由 tls-shunt-proxy 占用"

### ===== 2. 输入域名 / 密码 =====
read -rp "请输入 AnyTLS 域名（例如 yourdomain.com）: " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "[FATAL] 域名不能为空"; exit 1; }

read -rp "请输入 AnyTLS 密码（默认 ${DEFAULT_PASSWORD}，回车）: " PASSWORD
PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"

### ===== 3. 校验 域名 A 记录 ⇄ 公网 IP =====
echo "[INFO] 校验域名 DNS 是否指向本机公网 IP..."

echo "[INFO] 正在获取公网 IP，请耐心等待..."
PUBLIC_IP=$(curl -s https://api64.ipify.org)
[[ -z "$PUBLIC_IP" ]] && { echo "[FATAL] 无法获取公网 IP"; exit 1; }

# 使用 ping 获取域名解析 IP（无需 dig/dnsutils）
DOMAIN_IP=$(ping -q -c 1 -t 1 "${DOMAIN}" 2>/dev/null | grep PING | sed -e "s/).*//g" | sed -e "s/.*(//g")

echo "  域名 A 记录: $DOMAIN_IP"
echo "  本机公网 IP: $PUBLIC_IP"

if [[ "$DOMAIN_IP" == "$PUBLIC_IP" ]]; then
  echo "[OK] 域名 DNS 解析 IP 与本机 IP 匹配"
else
  echo "[WARN] 域名 DNS 解析 IP 与本机 IP 不匹配，可能导致 SSL 证书申请失败"
  read -rp "是否继续安装？(Y/N) [N]: " install_confirm
  case $install_confirm in
    [yY][eE][sS] | [yY])
      echo "[INFO] 继续安装..."
      ;;
    *)
      echo "[FATAL] 安装终止"
      exit 2
      ;;
  esac
fi

### ===== 4. 选择后端端口 =====
PORT=$PORT_START
while ss -lnt "( sport = :$PORT )" | grep -q LISTEN; do
  PORT=$((PORT+1))
done
echo "[OK] 使用 sing-box 后端端口: $PORT"

### ===== 5. 安装 sing-box =====
echo "[INFO] 安装 / 检查 sing-box..."
systemctl stop sing-box 2>/dev/null || true

# 如果 sing-box 未安装则安装
if ! command -v sing-box &>/dev/null; then
  echo "[INFO] 正在安装 sing-box..."
  curl -fsSL https://sing-box.app/install.sh | bash
fi

# 检测 sing-box 实际安装路径
SB_BIN=$(which sing-box 2>/dev/null)
if [[ -z "$SB_BIN" ]]; then
  echo "[FATAL] sing-box 安装失败，找不到可执行文件"
  exit 1
fi
echo "[OK] sing-box 路径: $SB_BIN"

mkdir -p /etc/sing-box "$SB_CERT_DIR"

### ===== 6. 修改 TSP vhost（先用 tlsoffloading: true 申请证书） =====
TSP_CONF="/etc/tls-shunt-proxy/config.yaml"
TSP_CERT_DIR="/etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory"

cp "$TSP_CONF" "${TSP_CONF}.bak.$(date +%s)"
echo "[OK] 已备份 TSP 配置"

# 先添加/更新 vhost，使用 tlsoffloading: true 让 TSP 申请证书
if grep -q "name: ${DOMAIN}" "$TSP_CONF"; then
  echo "[INFO] 更新已存在的 vhost: $DOMAIN（先启用 TLS offloading 以申请证书）"
  # 使用 Python 来安全地修改 YAML 配置
  python3 - "$TSP_CONF" "$DOMAIN" "$PORT" <<'PYEOF'
import sys
import re

conf_path = sys.argv[1]
domain = sys.argv[2]
port = sys.argv[3]

with open(conf_path, 'r') as f:
    content = f.read()

# 简单匹配并替换整个 vhost 块
pattern = rf'(  - name: {re.escape(domain)}.*?)(?=\n  - name:|\n[^ ]|\Z)'
replacement = f'''  - name: {domain}
    tlsoffloading: true
    managedcert: true
    keytype: p256
    alpn: h2,http/1.1
    protocols: tls12,tls13
    http:
      handler: fileServer
      args: /var/www/html'''

content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF
else
  echo "[INFO] 新增 vhost: $DOMAIN（先启用 TLS offloading 以申请证书）"
  cat >>"$TSP_CONF" <<EOF

  - name: ${DOMAIN}
    tlsoffloading: true
    managedcert: true
    keytype: p256
    alpn: h2,http/1.1
    protocols: tls12,tls13
    http:
      handler: fileServer
      args: /var/www/html
EOF
fi

# 创建临时网站目录
mkdir -p /var/www/html
echo "<h1>Certificate Pending</h1>" > /var/www/html/index.html

systemctl restart tls-shunt-proxy
echo "[OK] 已重启 tls-shunt-proxy，开始申请证书..."

### ===== 7. 等待 TSP 申请证书 =====
echo "[INFO] 等待 Let's Encrypt 证书申请..."
echo "[INFO] 发送 HTTPS 请求触发证书申请..."

# 尝试触发证书申请（忽略错误，因为证书还没好）
curl -sk "https://${DOMAIN}/" >/dev/null 2>&1 || true
sleep 3

CERT_FILE="${TSP_CERT_DIR}/${DOMAIN}/${DOMAIN}.crt"
KEY_FILE="${TSP_CERT_DIR}/${DOMAIN}/${DOMAIN}.key"

MAX_WAIT=120
WAITED=0
while [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; do
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "[FATAL] 等待证书超时（${MAX_WAIT}秒），请检查："
    echo "  1. 域名 DNS 是否正确指向本机"
    echo "  2. 80/443 端口是否被防火墙阻止"
    echo "  3. 运行 journalctl -u tls-shunt-proxy -f 查看日志"
    exit 1
  fi
  echo "[INFO] 等待证书文件生成... (${WAITED}s/${MAX_WAIT}s)"
  sleep 5
  WAITED=$((WAITED + 5))
  # 再次触发
  curl -sk "https://${DOMAIN}/" >/dev/null 2>&1 || true
done

echo "[OK] 证书已生成！"
echo "  证书: $CERT_FILE"
echo "  私钥: $KEY_FILE"

### ===== 8. 创建证书软链接给 sing-box =====
echo "[INFO] 创建证书软链接..."
mkdir -p "$SB_CERT_DIR"
ln -sf "$CERT_FILE" "${SB_CERT_DIR}/server.crt"
ln -sf "$KEY_FILE" "${SB_CERT_DIR}/server.key"
echo "[OK] 证书软链接已创建"

### ===== 9. 更新 TSP 配置为 tlsoffloading: false =====
echo "[INFO] 切换 TSP 为透传模式（tlsoffloading: false）..."

python3 - "$TSP_CONF" "$DOMAIN" "$PORT" <<'PYEOF'
import sys
import re

conf_path = sys.argv[1]
domain = sys.argv[2]
port = sys.argv[3]

with open(conf_path, 'r') as f:
    content = f.read()

# 替换为 tlsoffloading: false 的配置
pattern = rf'(  - name: {re.escape(domain)}.*?)(?=\n  - name:|\n[^ ]|\Z)'
replacement = f'''  - name: {domain}
    tlsoffloading: false
    managedcert: true
    keytype: p256
    alpn: h2,http/1.1
    protocols: tls12,tls13
    default:
      handler: proxyPass
      args: 127.0.0.1:{port}'''

content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF

systemctl restart tls-shunt-proxy
echo "[OK] TSP 已切换为透传模式"

### ===== 10. 写 sing-box AnyTLS 配置 =====
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
echo "[OK] sing-box 配置已生成"

### ===== 11. systemd 服务 =====
cat >"$SB_SERVICE" <<EOF
[Unit]
Description=sing-box AnyTLS Service
After=network.target tls-shunt-proxy.service

[Service]
ExecStart=${SB_BIN} run -c ${SB_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# 检查 sing-box 是否启动成功
sleep 2
if systemctl is-active sing-box &>/dev/null; then
  echo "[OK] sing-box 服务已启动"
else
  echo "[WARN] sing-box 启动可能有问题，请运行以下命令检查："
  echo "  journalctl -u sing-box -f"
fi

echo
echo "==========================================="
echo "✅ AnyTLS 安装完成！"
echo "==========================================="
echo
echo "📡 域名: ${DOMAIN}"
echo "🔐 密码: ${PASSWORD}"
echo "🔌 端口: 443 (TSP) -> ${PORT} (sing-box)"
echo
echo "📲 Surge 节点配置："
echo "hk-anytls 🇭🇰 = anytls, ${DOMAIN}, 443, password=${PASSWORD}, tls=true, sni=${DOMAIN}, alpn=h2, skip-cert-verify=false"
echo
echo "==========================================="
