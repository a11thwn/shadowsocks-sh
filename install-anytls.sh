#!/usr/bin/env bash
set -e

# ========= 基本参数 =========
ANYTLS_PORT=443
SNI_DOMAIN="www.cloudflare.com"
INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="$INSTALL_DIR/config.json"

echo "🚀 开始安装 AnyTLS (sing-box)..."

# ========= 检查系统 =========
if [[ $EUID -ne 0 ]]; then
  echo "❌ 请使用 root 用户运行"
  exit 1
fi

# ========= 安装依赖 =========
apt update
apt install -y curl unzip jq

# ========= 安装 sing-box =========
echo "📦 安装 sing-box..."
LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
curl -L -o /tmp/sing-box.tar.gz \
  https://github.com/SagerNet/sing-box/releases/download/${LATEST}/sing-box-${LATEST#v}-linux-amd64.tar.gz

tar -xzf /tmp/sing-box.tar.gz -C /tmp
install /tmp/sing-box-*/sing-box /usr/local/bin/
mkdir -p $INSTALL_DIR

# ========= 生成凭证 =========
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(openssl rand -hex 16)

# ========= 写配置 =========
cat > $CONFIG_FILE <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": $ANYTLS_PORT,
      "users": [
        {
          "name": "surge",
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI_DOMAIN"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# ========= systemd =========
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box AnyTLS Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# ========= 输出信息 =========
IP=$(curl -s https://api.ipify.org)

echo ""
echo "✅ AnyTLS 安装完成！"
echo "--------------------------------------"
echo "📡 服务器 IP: $IP"
echo "🔐 Password : $PASSWORD"
echo "🌐 Port     : $ANYTLS_PORT"
echo "🧭 SNI      : $SNI_DOMAIN"
echo ""
echo "📲 Surge 节点示例："
echo "anytls, $IP, 443, password=$PASSWORD, tls=true, sni=$SNI_DOMAIN, alpn=h2,http/1.1"
echo "--------------------------------------"
