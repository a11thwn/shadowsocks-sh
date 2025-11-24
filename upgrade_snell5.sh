#!/bin/bash

# ========================================
# Snell5 服务器升级脚本
# 功能：自动下载、升级 Snell5 代理服务器并重启服务
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

# 检查服务是否存在
check_service() {
    if [[ ! -f /usr/local/bin/snell-server ]]; then
        log_error "未找到 Snell5 服务器，请先运行安装脚本"
        exit 1
    fi
    
    if ! systemctl list-unit-files | grep -q snell.service; then
        log_error "未找到 Snell5 服务，请先运行安装脚本"
        exit 1
    fi
    
    log_info "检测到已安装的 Snell5 服务"
}

# 获取当前版本
get_current_version() {
    if [[ -f /usr/local/bin/snell-server ]]; then
        CURRENT_VERSION=$(/usr/local/bin/snell-server -v 2>&1 | head -n 1 || echo "未知版本")
        log_info "当前版本: $CURRENT_VERSION"
    fi
}

# 下载 Snell5
download_snell() {
    log_info "开始下载 Snell5 最新版本..."
    
    # 创建临时目录
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # 下载 Snell5
    if wget -q --show-progress https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip; then
        log_info "Snell5 下载完成"
    else
        log_error "Snell5 下载失败"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
}

# 停止服务
stop_service() {
    log_info "停止 Snell5 服务..."
    
    if systemctl is-active --quiet snell 2>/dev/null; then
        systemctl stop snell
        log_info "Snell5 服务已停止"
    else
        log_warn "Snell5 服务未运行"
    fi
}

# 备份旧版本
backup_old_version() {
    log_info "备份旧版本..."
    
    BACKUP_DIR="/usr/local/bin/backup"
    mkdir -p "$BACKUP_DIR"
    
    BACKUP_FILE="$BACKUP_DIR/snell-server-$(date +%Y%m%d-%H%M%S).bak"
    cp /usr/local/bin/snell-server "$BACKUP_FILE" 2>/dev/null || true
    
    if [[ -f "$BACKUP_FILE" ]]; then
        log_info "旧版本已备份到: $BACKUP_FILE"
    fi
}

# 升级 Snell5
upgrade_snell() {
    log_info "开始升级 Snell5..."
    
    # 解压到指定目录
    unzip -o snell-server-v5*.zip -d /usr/local/bin/
    
    # 添加执行权限
    chmod +x /usr/local/bin/snell-server
    
    log_info "Snell5 升级完成"
}

# 重启服务
restart_service() {
    log_info "重启 Snell5 服务..."
    
    # 重载 systemd
    systemctl daemon-reload
    
    # 启动服务
    systemctl start snell
    
    # 等待服务启动
    sleep 2
    
    # 检查服务状态
    if systemctl is-active --quiet snell; then
        log_info "Snell5 服务重启成功"
    else
        log_error "Snell5 服务重启失败"
        systemctl status snell
        exit 1
    fi
}

# 显示服务状态
show_status() {
    log_info "Snell5 服务状态:"
    systemctl status snell --no-pager -l
    
    # 显示新版本信息
    if [[ -f /usr/local/bin/snell-server ]]; then
        NEW_VERSION=$(/usr/local/bin/snell-server -v 2>&1 | head -n 1 || echo "未知版本")
        log_info "新版本: $NEW_VERSION"
    fi
    
    # 显示端口监听状态,套了一层shadow-tls端口为45632
    log_info "端口监听检查:"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep :45632 || log_warn "端口 45632 未在监听"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep :45632 || log_warn "端口 45632 未在监听"
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
    log_info "开始升级 Snell5 服务器..."
    
    # 检查前置条件
    check_root
    check_architecture
    check_service
    
    # 获取当前版本
    get_current_version
    
    # 执行升级步骤
    download_snell
    stop_service
    backup_old_version
    upgrade_snell
    restart_service
    
    # 显示状态
    show_status
    
    # 清理
    cleanup
    
    log_info "Snell5 升级完成！"
}

# 错误处理
trap 'log_error "升级过程中发生错误，正在清理..."; cleanup; exit 1' ERR

# 执行主函数
main "$@"

