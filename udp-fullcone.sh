#!/usr/bin/env bash
set -e

# ===== 参数处理 =====
if [ -z "$1" ]; then
  echo "Usage: $0 <udp_port>"
  exit 1
fi

UDP_PORT="$1"

if ! [[ "$UDP_PORT" =~ ^[0-9]+$ ]] || [ "$UDP_PORT" -lt 1 ] || [ "$UDP_PORT" -gt 65535 ]; then
  echo "Invalid UDP port: $UDP_PORT"
  exit 1
fi

SERVICE_NAME="udp${UDP_PORT}-fullcone"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
IPTABLES="/sbin/iptables"

echo "[*] Configuring Full Cone NAT for UDP port ${UDP_PORT}"

# ===== 写 systemd 服务 =====
cat << EOL > "${SERVICE_FILE}"
[Unit]
Description=Allow UDP ${UDP_PORT} Full Cone NAT (bypass conntrack)
After=network.target

[Service]
Type=oneshot
ExecStart=${IPTABLES} -C INPUT  -p udp --dport ${UDP_PORT} -j ACCEPT || ${IPTABLES} -I INPUT  -p udp --dport ${UDP_PORT} -j ACCEPT
ExecStart=${IPTABLES} -C OUTPUT -p udp -j ACCEPT || ${IPTABLES} -I OUTPUT -p udp -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

chmod 644 "${SERVICE_FILE}"

# ===== 启用并启动 =====
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "[✓] Done."
echo "    UDP ${UDP_PORT} will keep Full Cone NAT (A)"
echo "    systemd service: ${SERVICE_NAME}"

