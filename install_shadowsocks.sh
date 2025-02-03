#!/bin/bash
# 脚本需要root权限执行
if [ "$(id -u)" != "0" ]; then
    echo -e "\033[31m错误：本脚本需要使用root权限执行\033[0m"
    echo "请使用 sudo 执行该脚本"
    exit 1
fi

# 设置错误立即退出和显示执行命令
set -ex

# 步骤1：安装基础依赖
echo -e "\033[36m[1/7] 正在更新软件源并安装依赖...\033[0m"
apt-get update
apt-get -y install lsb-release ca-certificates curl gnupg

# 添加GPG密钥
curl -fsSL https://dl.lamp.sh/shadowsocks/DEB-GPG-KEY-Teddysun | gpg --dearmor --yes -o /usr/share/keyrings/deb-gpg-key-teddysun.gpg
chmod a+r /usr/share/keyrings/deb-gpg-key-teddysun.gpg

# 步骤2：添加软件源
echo -e "\033[36m[2/7] 正在配置软件源...\033[0m"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/deb-gpg-key-teddysun.gpg] https://dl.lamp.sh/shadowsocks/ubuntu/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/teddysun.list

# 步骤3：更新软件源
echo -e "\033[36m[3/7] 正在更新软件源...\033[0m"
apt-get update

# 步骤4：安装Shadowsocks
echo -e "\033[36m[4/7] 正在安装Shadowsocks...\033[0m"
apt install -y shadowsocks-rust shadowsocks-simple-obfs

# 步骤5：生成配置文件
echo -e "\033[36m[5/7] 正在创建配置文件...\033[0m"
CONFIG_FILE="/etc/shadowsocks/shadowsocks-rust-config.json"
mkdir -p /etc/shadowsocks

# 使用cat命令生成配置文件避免转义问题
cat > $CONFIG_FILE << EOF
{
    "server": "::",
    "server_port": 8000,
    "password": "qwertyuiop222",
    "timeout": 300,
    "method": "aes-256-gcm",
    "fast_open": true,
    "nameserver":"1.1.1.1",
    "mode":"tcp_and_udp",
    "plugin":"obfs-server",
    "plugin_opts":"obfs=http"
}
EOF

# 设置配置文件权限
chmod 644 $CONFIG_FILE

# 步骤6：启动服务
echo -e "\033[36m[6/7] 正在启动服务...\033[0m"
systemctl start shadowsocks-rust-server

# 步骤7：设置开机启动
echo -e "\033[36m[7/7] 正在设置开机启动...\033[0m"
systemctl enable shadowsocks-rust-server

# 显示安装完成信息
echo -e "\n\033[32m安装成功！\033[0m"
echo -e "服务器配置信息："
echo -e "端口：\033[33m8000\033[0m"
echo -e "密码：\033[33mqwertyuiop222\033[0m"
echo -e "加密方式：\033[33maes-256-gcm\033[0m"
echo -e "\n可以使用以下命令检查服务状态："
echo -e "systemctl status shadowsocks-rust-server" 