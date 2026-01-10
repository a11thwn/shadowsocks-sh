#!/bin/bash

# =============================================================================
# GOST v2.12.0 一键安装脚本 (普通用户权限优化版)
# =============================================================================

set -e # 遇到错误立即停止

echo "开始安装 GOST..."

# 1. 下载 GOST
GOST_VERSION="2.12.0"
TEMP_FILE="/tmp/gost_linux_amd64.tar.gz"

echo "正在从 GitHub 下载 GOST v${GOST_VERSION}..."
wget -O "$TEMP_FILE" "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz"

# 2. 解压并移动到系统路径 (使用 sudo)
echo "正在安装执行文件..."
tar -zxf "$TEMP_FILE" -C /tmp
sudo mv /tmp/gost /usr/local/bin/gost
sudo chmod +x /usr/local/bin/gost
rm "$TEMP_FILE"

# 3. 创建配置目录和文件 (使用 sudo)
echo "正在配置 GOST (SOCKS5 端口: 5000)..."
sudo mkdir -p /etc/gost
sudo bash -c 'cat > /etc/gost/config.json <<EOF
{
    "Retries": 0,
    "ServeNodes": [
        "socks5://admin:admin@:5000"
    ]
}
EOF'

# 4. 创建 Systemd 服务文件 (使用 sudo)
echo "正在创建系统服务..."
sudo bash -c 'cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF'

# 5. 启动并设置自启动 (使用 sudo)
echo "正在启动并激活服务..."
sudo systemctl daemon-reload
sudo systemctl enable gost
sudo systemctl restart gost

# 6. 最终验证
echo "=========================================="
if sudo systemctl is-active --quiet gost; then
    echo -e "\033[32m安装成功！GOST 正在运行中。\033[0m"
    echo "监听详情: SOCKS5 代理地址为 0.0.0.0:5000"
    echo "认证信息: admin / admin"
else
    echo -e "\033[31m安装失败，请检查 journalctl -u gost 日志。\033[0m"
fi
echo "=========================================="