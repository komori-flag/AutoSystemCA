# Changelog

## v1.1

- **修复**：`customize.sh` 未声明 `POSTFSDATA` / `LATESTARTSERVICE` 标志，导致 KernelSU / Magisk 不执行开机脚本（v1.0 证书从未注入）——现已声明，需重新安装模块
- 新增 `action.sh`：KSU Manager 模块页可直接「执行」，免重启注入
- 新增 `last-run.log` 文件日志：即使 logcat 丢失开机早期日志，也能确认脚本是否运行
- openssl 检测加固：显式检查 `/system/bin`、`/system/xbin`

## v1.0

- 首次发布：开机自动从 `certs/` 目录注入系统 CA 证书
  - DER / PEM 自动识别与转换
  - `subject_hash_old` 命名 + hash 冲突 `.0/.1/.2` 处理
  - Android 14+ `/apex/com.android.conscrypt/cacerts` 支持
  - SELinux context 修复、清单式自动清理
  - KernelSU / Magisk / APatch 兼容
