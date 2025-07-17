#!/bin/bash

# ========================================
# Snell5 服务器安装脚本
# 功能：自动下载、安装和配置 Snell5 代理服务器
# 作者：系统管理员
# 创建时间：$(date)
# ========================================

# 设置错误时退出
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检查系统架构
check_architecture() {
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        log_error "此脚本仅支持 x86_64 架构，当前架构: $ARCH"
        exit 1
    fi
}

# 下载 Snell5
download_snell() {
    log_info "开始下载 Snell5 服务器..."
    
    # 创建临时目录
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # 下载 Snell5
    if wget -q --show-progress https://dl.nssurge.com/snell/snell-server-v5.0.0-linux-amd64.zip; then
        log_info "Snell5 下载完成"
    else
        log_error "Snell5 下载失败"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
}

# 安装 Snell5
install_snell() {
    log_info "开始安装 Snell5..."
    
    # 解压到指定目录
    unzip -o snell-server-v5*.zip -d /usr/local/bin/
    
    # 添加执行权限
    chmod +x /usr/local/bin/snell-server
    
    log_info "Snell5 安装完成"
}

# 创建配置文件
create_config() {
    log_info "创建 Snell5 配置文件..."
    
    # 创建配置目录
    mkdir -p /etc/snell
    
    # 创建配置文件
    cat > /etc/snell/snell-server.conf << 'EOF'
[snell-server]
listen = 0.0.0.0:8005
psk = qwertyuiop222
ipv6 = true
EOF
    
    log_info "配置文件创建完成: /etc/snell/snell-server.conf"
}

# 创建 Systemd 服务
create_service() {
    log_info "创建 Systemd 服务文件..."
    
    cat > /lib/systemd/system/snell.service << 'EOF'
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "Systemd 服务文件创建完成"
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙规则..."
    
    # 检查防火墙类型
    if command -v ufw >/dev/null 2>&1; then
        # Ubuntu/Debian UFW
        log_info "检测到 UFW 防火墙，配置端口规则..."
        ufw allow 8005/tcp
        ufw allow 8005/udp
        log_info "UFW 防火墙规则配置完成"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        # CentOS/RHEL/Fedora firewalld
        log_info "检测到 firewalld 防火墙，配置端口规则..."
        firewall-cmd --permanent --add-port=8005/tcp
        firewall-cmd --permanent --add-port=8005/udp
        firewall-cmd --reload
        log_info "firewalld 防火墙规则配置完成"
    elif command -v iptables >/dev/null 2>&1; then
        # 传统 iptables
        log_info "检测到 iptables，配置端口规则..."
        iptables -A INPUT -p tcp --dport 8005 -j ACCEPT
        iptables -A INPUT -p udp --dport 8005 -j ACCEPT
        log_info "iptables 规则配置完成"
        log_warn "请确保保存 iptables 规则，避免重启后丢失"
    else
        log_warn "未检测到常见防火墙，请手动开放端口 8005 (TCP/UDP)"
    fi
}

# 启动服务
start_service() {
    log_info "启动 Snell5 服务..."
    
    # 重载 systemd
    systemctl daemon-reload
    
    # 启用服务
    systemctl enable snell
    
    # 启动服务
    systemctl start snell
    
    # 检查服务状态
    if systemctl is-active --quiet snell; then
        log_info "Snell5 服务启动成功"
    else
        log_error "Snell5 服务启动失败"
        systemctl status snell
        exit 1
    fi
}

# 显示服务状态
show_status() {
    log_info "Snell5 服务状态:"
    systemctl status snell --no-pager
    
    log_info "配置文件位置: /etc/snell/snell-server.conf"
    log_info "服务端口: 8005 (TCP/UDP)"
    log_info "PSK: qwertyuiop222"
    
    # 显示防火墙状态
    log_info "防火墙端口检查:"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep :8005 || log_warn "端口 8005 未在监听"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep :8005 || log_warn "端口 8005 未在监听"
    fi
}

# 清理临时文件
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_info "临时文件清理完成"
    fi
}

# 主函数
main() {
    log_info "开始安装 Snell5 服务器..."
    
    # 检查前置条件
    check_root
    check_architecture
    
    # 执行安装步骤
    download_snell
    install_snell
    create_config
    create_service
    configure_firewall
    start_service
    
    # 显示状态
    show_status
    
    # 清理
    cleanup
    
    log_info "Snell5 安装完成！"
}

# 错误处理
trap 'log_error "安装过程中发生错误，正在清理..."; cleanup; exit 1' ERR

# 执行主函数
main "$@"
