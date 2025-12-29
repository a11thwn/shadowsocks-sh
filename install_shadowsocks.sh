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
echo -e "\033[36m[1/9] 正在更新软件源并安装依赖...\033[0m"
apt-get update
apt-get -y install lsb-release ca-certificates curl gnupg

# 添加GPG密钥
curl -fsSL https://dl.lamp.sh/shadowsocks/DEB-GPG-KEY-Teddysun | gpg --dearmor --yes -o /usr/share/keyrings/deb-gpg-key-teddysun.gpg
chmod a+r /usr/share/keyrings/deb-gpg-key-teddysun.gpg

# 步骤2：添加软件源
echo -e "\033[36m[2/9] 正在配置软件源...\033[0m"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/deb-gpg-key-teddysun.gpg] https://dl.lamp.sh/shadowsocks/ubuntu/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/teddysun.list

# 步骤3：更新软件源
echo -e "\033[36m[3/9] 正在更新软件源...\033[0m"
apt-get update

# 步骤4：安装Shadowsocks
echo -e "\033[36m[4/9] 正在安装Shadowsocks...\033[0m"
apt install -y shadowsocks-rust

# 步骤5：生成配置文件
echo -e "\033[36m[5/9] 正在创建配置文件...\033[0m"
CONFIG_FILE="/etc/shadowsocks/shadowsocks-rust-config.json"
mkdir -p /etc/shadowsocks

# 使用cat命令生成配置文件避免转义问题
cat > $CONFIG_FILE << EOF
{
    "server": "0.0.0.0",
    "server_port": 45632,
    "password": "qwertyuiop222",
    "timeout": 300,
    "method": "aes-256-gcm",
    "fast_open": true,
    "nameserver":"1.1.1.1",
    "mode":"tcp_and_udp"
}
EOF

# 设置配置文件权限
chmod 644 $CONFIG_FILE

# 步骤6：启动Shadowsocks服务
echo -e "\033[36m[6/9] 正在启动Shadowsocks服务...\033[0m"
systemctl start shadowsocks-rust-server

# 步骤7：设置Shadowsocks开机启动
echo -e "\033[36m[7/9] 正在设置Shadowsocks开机启动...\033[0m"
systemctl enable shadowsocks-rust-server

# 步骤8：安装shadow-tls
echo -e "\033[36m[8/9] 正在安装shadow-tls...\033[0m"

# 下载shadow-tls
wget https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl
mv shadow-tls-x86_64-unknown-linux-musl /usr/bin/shadow-tls
chmod +x /usr/bin/shadow-tls

# 设置开机启动服务
cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Custom Server Service
Documentation=man:sstls-server(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# --listen :::8443 外部端口
# --server 127.0.0.1:45632 内部端口
ExecStart=/usr/bin/shadow-tls --v3 --fastopen server --listen :::8000 --password qwertyuiop2202 --server 127.0.0.1:45632 --tls www.bing.com:443

[Install]
WantedBy=multi-user.target
EOF

# 步骤9：启动shadow-tls服务
echo -e "\033[36m[9/9] 正在启动shadow-tls服务...\033[0m"
systemctl daemon-reload
systemctl enable shadow-tls.service
systemctl start shadow-tls.service

# 显示安装完成信息
echo -e "\n\033[32m安装成功！\033[0m"
echo -e "服务器配置信息："
echo -e "Shadowsocks端口：\033[33m45632\033[0m (内部)"
echo -e "Shadow-TLS端口：\033[33m8000\033[0m (外部)"
echo -e "Shadow-TLS密码：\033[33mqwertyuiop2202\033[0m"
echo -e "Shadow-TLS伪装域名：\033[33mwww.bing.com\033[0m"
echo -e "密码：\033[33mqwertyuiop222\033[0m"
echo -e "加密方式：\033[33maes-256-gcm\033[0m"
echo -e "\n可以使用以下命令检查服务状态："
echo -e "systemctl status shadowsocks-rust-server"
echo -e "systemctl status shadow-tls.service" 