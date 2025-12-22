#!/bin/bash

# 修改 Trojan-Go WebSocket 路径脚本
# 用于同步修改 TLS-Shunt-Proxy 和 Trojan-Go 配置中的 WS 路径

#Fonts Color
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
GreenBG="\033[42;30m"
RedBG="\033[41;30m"
Font="\033[0m"

# 配置文件路径
TSP_CONF="/etc/tls-shunt-proxy/config.yaml"
TROJAN_CONF="/etc/trojan-go/config.json"

# 固定的 WebSocket 路径（可以根据需要修改）
NEW_WSPATH="/trojan/13b2202/"

# 检查 root 权限
if [ 0 != $UID ]; then
    echo -e "${Red}[错误]${Font} 请使用 root 用户运行此脚本"
    exit 1
fi

# 显示当前配置
echo -e "${Green}========== 当前配置 ==========${Font}"

if [ -f "$TSP_CONF" ]; then
    current_tsp_path=$(grep '#Trojan_WS_Path' "$TSP_CONF" | sed -r 's/.*path: (.*) #.*/\1/')
    echo -e "TLS-Shunt-Proxy 当前 WS 路径: ${Yellow}${current_tsp_path}${Font}"
else
    echo -e "${Red}[错误]${Font} 未找到 TLS-Shunt-Proxy 配置文件: $TSP_CONF"
    exit 1
fi

if [ -f "$TROJAN_CONF" ]; then
    current_trojan_path=$(grep '"path":' "$TROJAN_CONF" | awk -F '"' '{print $4}')
    current_trojan_host=$(grep '"host":' "$TROJAN_CONF" | awk -F '"' '{print $4}')
    echo -e "Trojan-Go 当前 WS 路径: ${Yellow}${current_trojan_path}${Font}"
    echo -e "Trojan-Go 当前 Host: ${Yellow}${current_trojan_host}${Font}"
else
    echo -e "${Red}[错误]${Font} 未找到 Trojan-Go 配置文件: $TROJAN_CONF"
    exit 1
fi

echo -e "${Green}================================${Font}\n"

# 提示用户输入新路径
read -rp "请输入新的 WebSocket 路径（默认: ${NEW_WSPATH}）: " input_path
[[ -n "$input_path" ]] && NEW_WSPATH="$input_path"

# 确保路径格式正确（以 / 开头和结尾）
[[ "${NEW_WSPATH:0:1}" != "/" ]] && NEW_WSPATH="/${NEW_WSPATH}"
[[ "${NEW_WSPATH: -1}" != "/" ]] && NEW_WSPATH="${NEW_WSPATH}/"

echo -e "\n${Yellow}将要修改的新路径: ${NEW_WSPATH}${Font}"
read -rp "确认修改？(Y/N) [N]: " confirm
[[ -z "$confirm" ]] && confirm="N"

case $confirm in
[yY][eE][sS] | [yY])
    echo -e "\n${Green}[开始修改配置...]${Font}"
    ;;
*)
    echo -e "${Yellow}已取消操作${Font}"
    exit 0
    ;;
esac

# 备份配置文件
echo -e "${Green}[1/5]${Font} 备份配置文件..."
cp "$TSP_CONF" "${TSP_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$TROJAN_CONF" "${TROJAN_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# 修改 TLS-Shunt-Proxy 配置
echo -e "${Green}[2/5]${Font} 修改 TLS-Shunt-Proxy 配置..."
sed -i "/#Trojan_WS_Path/c \\      - path: ${NEW_WSPATH} #Trojan_WS_Path" "$TSP_CONF"

# 修改 Trojan-Go 配置
echo -e "${Green}[3/5]${Font} 修改 Trojan-Go 配置..."
# 使用 jq 修改 JSON（如果可用）
if command -v jq &>/dev/null; then
    jq --arg path "$NEW_WSPATH" '.websocket.path = $path' "$TROJAN_CONF" > "${TROJAN_CONF}.tmp" && mv "${TROJAN_CONF}.tmp" "$TROJAN_CONF"
else
    # 使用 sed 替换
    sed -i "s|\"path\": \"[^\"]*\"|\"path\": \"${NEW_WSPATH}\"|g" "$TROJAN_CONF"
fi

# 重启 Trojan-Go 容器
echo -e "${Green}[4/5]${Font} 重启 Trojan-Go 容器..."
docker restart Trojan-Go

# 重启 TLS-Shunt-Proxy 服务
echo -e "${Green}[5/5]${Font} 重启 TLS-Shunt-Proxy 服务..."
systemctl restart tls-shunt-proxy

# 等待服务启动
sleep 3

# 检查服务状态
echo -e "\n${Green}========== 服务状态 ==========${Font}"
if systemctl is-active tls-shunt-proxy &>/dev/null; then
    echo -e "TLS-Shunt-Proxy: ${Green}运行中${Font}"
else
    echo -e "TLS-Shunt-Proxy: ${Red}未运行${Font}"
fi

if docker ps | grep -q Trojan-Go; then
    echo -e "Trojan-Go: ${Green}运行中${Font}"
else
    echo -e "Trojan-Go: ${Red}未运行${Font}"
fi

# 显示修改后的配置
echo -e "\n${Green}========== 修改后配置 ==========${Font}"
new_tsp_path=$(grep '#Trojan_WS_Path' "$TSP_CONF" | sed -r 's/.*path: (.*) #.*/\1/')
new_trojan_path=$(grep '"path":' "$TROJAN_CONF" | awk -F '"' '{print $4}')
echo -e "TLS-Shunt-Proxy WS 路径: ${Green}${new_tsp_path}${Font}"
echo -e "Trojan-Go WS 路径: ${Green}${new_trojan_path}${Font}"
echo -e "${Green}================================${Font}"

# 提示查看日志
echo -e "\n${Yellow}提示: 如需查看 TLS-Shunt-Proxy 日志，请执行:${Font}"
echo -e "journalctl -u tls-shunt-proxy.service --since today"

echo -e "\n${Green}[完成]${Font} WebSocket 路径修改成功！"
