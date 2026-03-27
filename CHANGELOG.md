# Changelog

## 2026-03-27

### 新增
- `renew-anytls-cert.sh`: 独立证书续期脚本，适用于已部署 TSP + sing-box AnyTLS 的服务器
  - 支持手动指定域名或从 sing-box 证书软链接自动提取 AnyTLS 域名
  - 已过期证书自动删除旧文件触发重新申请
  - openssl 验证新证书有效性
  - 出错自动回滚 TSP 到透传模式

### 修复
- `install-anytls.sh`: 修复内嵌证书续期脚本无法实际触发 ACME 续期的问题
  - 原因: 运行态 TSP 为 tlsoffloading: false（透传），重启不会触发 ACME
  - 修复: 续期时临时切换为 tlsoffloading: true，完成后切回
  - 增加 trap ERR 回滚保护，防止 TSP 停留在错误状态
