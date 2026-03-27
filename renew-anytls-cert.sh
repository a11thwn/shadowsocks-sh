#!/bin/bash
# 独立证书续期脚本 — 适用于已部署 TSP + sing-box AnyTLS 的服务器
# 用法: bash renew-anytls-cert.sh [域名]
#   域名可选，不填则自动从 TSP 配置中提取

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] 请使用 root 用户运行"
  exit 1
fi

TSP_CONF="/etc/tls-shunt-proxy/config.yaml"
TSP_CERT_DIR="/etc/ssl/tls-shunt-proxy/certificates/acme-v02.api.letsencrypt.org-directory"
SB_CERT_DIR="/etc/sing-box/cert"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ===== 1. 确定域名 =====
if [[ -n "${1:-}" ]]; then
  DOMAIN="$1"
else
  # 从 sing-box 证书软链接反推 AnyTLS 域名
  # 链接目标: /etc/ssl/tls-shunt-proxy/certificates/.../DOMAIN/DOMAIN.crt
  SB_CERT_LINK="${SB_CERT_DIR}/server.crt"
  if [[ -L "$SB_CERT_LINK" ]]; then
    DOMAIN=$(basename "$(dirname "$(readlink "$SB_CERT_LINK")")")
  fi
  if [[ -z "${DOMAIN:-}" ]]; then
    echo "[FATAL] 无法从 sing-box 证书软链接提取 AnyTLS 域名"
    echo "用法: $0 <域名>"
    exit 1
  fi
fi

log "域名: $DOMAIN"

# ===== 2. 前置检查 =====
if [[ ! -f "$TSP_CONF" ]]; then
  echo "[FATAL] TSP 配置不存在: $TSP_CONF"
  exit 1
fi

if ! command -v tls-shunt-proxy &>/dev/null && [[ ! -f /usr/local/bin/tls-shunt-proxy ]]; then
  echo "[FATAL] tls-shunt-proxy 未安装"
  exit 1
fi

# 检查当前证书状态
CERT_FILE="${TSP_CERT_DIR}/${DOMAIN}/${DOMAIN}.crt"
SB_CERT="${SB_CERT_DIR}/server.crt"

if [[ -f "$CERT_FILE" ]]; then
  EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
  log "当前证书过期时间: $EXPIRY"
  if openssl x509 -checkend 0 -noout -in "$CERT_FILE" 2>/dev/null; then
    log "证书仍在有效期内"
    # 检查是否 30 天内过期
    if openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" 2>/dev/null; then
      log "[INFO] 证书 30 天内不会过期，无需续期"
      read -rp "是否仍要强制续期？(y/N): " force
      [[ ! "$force" =~ ^[yY]$ ]] && { log "跳过续期"; exit 0; }
    else
      log "[WARN] 证书将在 30 天内过期，开始续期"
    fi
  else
    log "[WARN] 证书已过期！立即续期"
  fi
else
  log "[WARN] 证书文件不存在: $CERT_FILE"
fi

# ===== 3. 备份 TSP 配置 =====
cp "$TSP_CONF" "${TSP_CONF}.bak.$(date +%s)"
log "[OK] 已备份 TSP 配置"

# ===== 4. 回滚函数 =====
rollback() {
  log "[ROLLBACK] 恢复 TSP 透传模式..."
  sed -i "s/tlsoffloading: true/tlsoffloading: false/" "$TSP_CONF"
  systemctl restart tls-shunt-proxy 2>/dev/null || true
  systemctl restart sing-box 2>/dev/null || true
}
trap rollback ERR

# ===== 5. 记录旧证书哈希 =====
OLD_HASH=""
if [[ -f "$CERT_FILE" ]]; then
  OLD_HASH=$(md5sum "$CERT_FILE" 2>/dev/null | awk '{print $1}')
fi

# ===== 6. 切换 TSP 为 tlsoffloading: true =====
log "切换 TSP 为 TLS 终结模式以触发 ACME 续期..."

# 处理已过期证书：删除旧证书让 TSP 重新申请
if [[ -f "$CERT_FILE" ]] && ! openssl x509 -checkend 0 -noout -in "$CERT_FILE" 2>/dev/null; then
  log "证书已过期，删除旧证书以触发重新申请..."
  rm -f "${TSP_CERT_DIR}/${DOMAIN}/${DOMAIN}.crt"
  rm -f "${TSP_CERT_DIR}/${DOMAIN}/${DOMAIN}.key"
fi

sed -i "s/tlsoffloading: false/tlsoffloading: true/" "$TSP_CONF"
systemctl restart tls-shunt-proxy
sleep 3

if ! systemctl is-active tls-shunt-proxy &>/dev/null; then
  log "[ERROR] tls-shunt-proxy 重启失败！"
  rollback
  exit 1
fi
log "[OK] TSP 已切换为 TLS 终结模式"

# ===== 7. 触发 ACME 并等待证书 =====
log "触发 ACME 证书申请/续期..."

MAX_WAIT=120
WAITED=0
while [[ ! -f "$CERT_FILE" ]]; do
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    log "[ERROR] 等待证书超时（${MAX_WAIT}s），请检查："
    log "  1. 域名 DNS 是否指向本机"
    log "  2. 80/443 端口是否开放"
    log "  3. journalctl -u tls-shunt-proxy -n 50"
    rollback
    exit 1
  fi
  curl -sk "https://${DOMAIN}/" >/dev/null 2>&1 || true
  sleep 5
  WAITED=$((WAITED + 5))
  log "等待证书... (${WAITED}s/${MAX_WAIT}s)"
done

# 证书文件存在了，再等一轮确保写入完成
sleep 5
curl -sk "https://${DOMAIN}/" >/dev/null 2>&1 || true
sleep 5

# 验证新证书有效性
if ! openssl x509 -checkend 0 -noout -in "$CERT_FILE" 2>/dev/null; then
  log "[ERROR] 新证书无效！"
  rollback
  exit 1
fi

NEW_EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
log "[OK] 新证书有效，过期时间: $NEW_EXPIRY"

# ===== 8. 切回透传模式 =====
log "切回 TSP 透传模式..."
sed -i "s/tlsoffloading: true/tlsoffloading: false/" "$TSP_CONF"
systemctl restart tls-shunt-proxy
sleep 2

if ! systemctl is-active tls-shunt-proxy &>/dev/null; then
  log "[ERROR] TSP 切回透传模式失败！"
  exit 1
fi
log "[OK] TSP 已切回透传模式"

# ===== 9. 更新 sing-box 证书链接并重启 =====
mkdir -p "$SB_CERT_DIR"
ln -sf "$CERT_FILE" "${SB_CERT_DIR}/server.crt"
ln -sf "${TSP_CERT_DIR}/${DOMAIN}/${DOMAIN}.key" "${SB_CERT_DIR}/server.key"

systemctl restart sing-box
sleep 2

if systemctl is-active sing-box &>/dev/null; then
  log "[OK] sing-box 已重启，新证书已加载"
else
  log "[WARN] sing-box 启动异常，请检查: journalctl -u sing-box -n 20"
fi

# 保存证书哈希
NEW_HASH=$(md5sum "$CERT_FILE" 2>/dev/null | awk '{print $1}')
echo "$NEW_HASH" > "${SB_CERT_DIR}/.cert_hash"

log "===== 续期完成 ====="
log "域名: $DOMAIN"
log "证书: $CERT_FILE"
log "过期: $NEW_EXPIRY"
