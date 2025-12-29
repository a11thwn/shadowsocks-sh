#!/bin/bash
# 升级脚本：从 shadowsocks-simple-obfs 迁移到 shadow-tls
# 适用于已安装 shadowsocks-rust 和 shadowsocks-simple-obfs 的系统

# 脚本需要root权限执行
if [ "$(id -u)" != "0" ]; then
    echo -e "\033[31m错误：本脚本需要使用root权限执行\033[0m"
    echo "请使用 sudo 执行该脚本"
    exit 1
fi

# 设置错误立即退出和显示执行命令
set -ex

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m  升级到 Shadow-TLS 迁移脚本\033[0m"
echo -e "\033[36m========================================\033[0m"

# 步骤1：停止 shadowsocks 服务
echo -e "\n\033[36m[1/7] 正在停止 shadowsocks-rust 服务...\033[0m"
systemctl stop shadowsocks-rust-server || true

# 步骤2：检测并卸载 shadowsocks-simple-obfs
echo -e "\n\033[36m[2/7] 检测并卸载 shadowsocks-simple-obfs...\033[0m"
if dpkg -l | grep -q shadowsocks-simple-obfs; then
    echo "检测到 shadowsocks-simple-obfs，正在卸载..."
    apt remove -y shadowsocks-simple-obfs
    echo -e "\033[32mshadowsocks-simple-obfs 已卸载\033[0m"
else
    echo "未检测到 shadowsocks-simple-obfs，跳过卸载步骤"
fi

# 步骤3：备份并更新 shadowsocks 配置文件
echo -e "\n\033[36m[3/7] 更新 shadowsocks 配置文件...\033[0m"
CONFIG_FILE="/etc/shadowsocks/shadowsocks-rust-config.json"

# 备份原配置文件
if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "已备份原配置文件"
fi

# 创建新配置文件（移除 plugin 相关配置）
cat > $CONFIG_FILE << EOF
{
    "server": "127.0.0.1",
    "server_port": 45632,
    "password": "qwertyuiop222",
    "timeout": 300,
    "method": "aes-256-gcm",
    "fast_open": true,
    "nameserver":"1.1.1.1",
    "mode":"tcp_and_udp"
}
EOF
chmod 644 $CONFIG_FILE
echo -e "\033[32m配置文件已更新（移除 plugin 配置）\033[0m"

# 步骤4：下载并安装 shadow-tls
echo -e "\n\033[36m[4/7] 正在下载并安装 shadow-tls...\033[0m"

# 检测是否已安装
if [ -f "/usr/bin/shadow-tls" ]; then
    echo "检测到已安装 shadow-tls，将进行覆盖安装"
fi

# 下载 shadow-tls
cd /tmp
wget -O shadow-tls https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl
mv shadow-tls /usr/bin/shadow-tls
chmod +x /usr/bin/shadow-tls
echo -e "\033[32mshadow-tls 已安装到 /usr/bin/shadow-tls\033[0m"

# 步骤5：创建 shadow-tls systemd 服务
echo -e "\n\033[36m[5/7] 创建 shadow-tls 服务...\033[0m"
cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Custom Server Service
Documentation=man:sstls-server(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# --listen :::8000 外部端口
# --server 127.0.0.1:45632 内部端口
ExecStart=/usr/bin/shadow-tls --v3 --fastopen server --listen :::8000 --password qwertyuiop2202 --server 127.0.0.1:45632 --tls www.bing.com:443

[Install]
WantedBy=multi-user.target
EOF
echo -e "\033[32mshadow-tls 服务文件已创建\033[0m"

# 步骤6：重新加载 systemd 并启动服务
echo -e "\n\033[36m[6/7] 正在启动服务...\033[0m"
systemctl daemon-reload

# 启动 shadowsocks
systemctl start shadowsocks-rust-server
systemctl enable shadowsocks-rust-server
echo "shadowsocks-rust-server 已启动"

# 启动 shadow-tls
systemctl enable shadow-tls.service
systemctl start shadow-tls.service
echo "shadow-tls 已启动"

# 步骤7：显示服务状态
echo -e "\n\033[36m[7/7] 检查服务状态...\033[0m"
echo ""
echo "shadowsocks-rust-server 状态："
systemctl status shadowsocks-rust-server --no-pager || true
echo ""
echo "shadow-tls 状态："
systemctl status shadow-tls.service --no-pager || true

# 显示完成信息
echo -e "\n\033[32m========================================\033[0m"
echo -e "\033[32m  升级完成！\033[0m"
echo -e "\033[32m========================================\033[0m"
echo -e "\n服务器配置信息："
echo -e "Shadowsocks端口：\033[33m45632\033[0m (内部)"
echo -e "Shadow-TLS端口：\033[33m8000\033[0m (外部)"
echo -e "Shadow-TLS密码：\033[33mqwertyuiop2202\033[0m"
echo -e "Shadow-TLS伪装域名：\033[33mwww.bing.com\033[0m"
echo -e "Shadowsocks密码：\033[33mqwertyuiop222\033[0m"
echo -e "加密方式：\033[33maes-256-gcm\033[0m"

echo -e "\n\033[33m注意：请更新客户端配置！\033[0m"
echo -e "客户端需要配置 Shadow-TLS 客户端，连接端口改为 8000"

echo -e "\n可以使用以下命令检查服务状态："
echo -e "systemctl status shadowsocks-rust-server"
echo -e "systemctl status shadow-tls.service"
