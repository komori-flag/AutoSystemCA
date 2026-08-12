# Changelog

## v1.0

- 首次发布：开机自动从 `certs/` 目录注入系统 CA 证书
  - DER / PEM 自动识别与转换
  - `subject_hash_old` 命名 + hash 冲突 `.0/.1/.2` 处理
  - Android 14+ `/apex/com.android.conscrypt/cacerts` 支持
  - SELinux context 修复、清单式自动清理
  - KernelSU / Magisk / APatch 兼容
