#!/bin/bash

# =============================================================================
# GOST 一键安装脚本
# 功能：自动下载、安装、配置 GOST 代理服务并设置开机自启动
# 作者：系统管理员
# 创建时间：2024年
# =============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行，请使用 sudo 执行"
        exit 1
    fi
}

# 检查系统架构
check_architecture() {
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        log_error "当前系统架构为 $ARCH，此脚本仅支持 x86_64 架构"
        exit 1
    fi
    log_info "检测到系统架构: $ARCH"
}

# 下载并安装 GOST
install_gost() {
    log_step "开始下载 GOST..."
    
    # 创建临时目录
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # 下载 GOST
    GOST_VERSION="v2.12.0"
    GOST_URL="https://github.com/ginuerzh/gost/releases/download/${GOST_VERSION}/gost_${GOST_VERSION#v}_linux_amd64.tar.gz"
    
    if wget -q --show-progress "$GOST_URL"; then
        log_info "GOST 下载完成"
    else
        log_error "GOST 下载失败"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 解压并安装
    log_step "解压并安装 GOST..."
    tar -zxf "gost_${GOST_VERSION#v}_linux_amd64.tar.gz"
    mv gost /usr/local/bin/gost
    chmod +x /usr/local/bin/gost
    
    # 清理临时文件
    rm -rf "$TEMP_DIR"
    
    log_info "GOST 安装完成"
}

# 创建配置文件
create_config() {
    log_step "创建 GOST 配置文件..."
    
    # 创建配置目录
    mkdir -p /etc/gost
    
    # 创建配置文件
    cat > /etc/gost/config.json << 'EOF'
{
    "Server": "0.0.0.0:5000",
    "Debug": true,
    "Chains": [
        {
            "Service": "socks5://:5000"
        }
    ]
}
EOF
    
    log_info "配置文件创建完成: /etc/gost/config.json"
}

# 创建 systemd 服务
create_service() {
    log_step "创建 systemd 服务..."
    
    cat > /lib/systemd/system/gost.service << 'EOF'
[Unit]
Description=GOST Proxy Service
Documentation=https://github.com/ginuerzh/gost
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
RestartSec=3
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=gost

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "systemd 服务文件创建完成"
}

# 启动服务
start_service() {
    log_step "启动 GOST 服务..."
    
    # 重载 systemd
    systemctl daemon-reload
    
    # 启用开机自启动
    systemctl enable gost.service
    
    # 启动服务
    systemctl start gost.service
    
    # 检查服务状态
    if systemctl is-active --quiet gost.service; then
        log_info "GOST 服务启动成功"
        log_info "服务状态: $(systemctl is-active gost.service)"
    else
        log_error "GOST 服务启动失败"
        log_error "请检查日志: journalctl -u gost.service -f"
        exit 1
    fi
}

# 显示服务信息
show_info() {
    log_step "GOST 安装完成！"
    echo ""
    echo "=========================================="
    echo "GOST 服务信息:"
    echo "=========================================="
    echo "服务名称: gost"
    echo "监听端口: 5000"
    echo "协议: SOCKS5"
    echo "配置文件: /etc/gost/config.json"
    echo "可执行文件: /usr/local/bin/gost"
    echo ""
    echo "常用命令:"
    echo "  查看服务状态: systemctl status gost"
    echo "  启动服务: systemctl start gost"
    echo "  停止服务: systemctl stop gost"
    echo "  重启服务: systemctl restart gost"
    echo "  查看日志: journalctl -u gost -f"
    echo "  禁用开机启动: systemctl disable gost"
    echo ""
    echo "SOCKS5 代理地址: 127.0.0.1:5000"
    echo "=========================================="
}

# 主函数
main() {
    echo "=========================================="
    echo "GOST 一键安装脚本"
    echo "=========================================="
    
    # 检查环境
    check_root
    check_architecture
    
    # 安装过程
    install_gost
    create_config
    create_service
    start_service
    
    # 显示信息
    show_info
}

# 执行主函数
main "$@"
