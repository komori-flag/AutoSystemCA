<!--
  使用前请把下面所有 YOUR_GITHUB_USERNAME 替换为你的 GitHub 用户名
  （模块管理器在线更新依赖 module.prop 中的 updateJson 和 update.json）
-->
# AutoSystemCA

![License](https://img.shields.io/github/license/YOUR_GITHUB_USERNAME/AutoSystemCA)
![Release](https://img.shields.io/github/v/release/YOUR_GITHUB_USERNAME/AutoSystemCA)

KernelSU / Magisk / APatch 开机自动系统 CA 注入模块。

把证书丢进 `certs/` 目录 → 重启 → 证书自动以系统证书身份生效（App 默认信任，可用于 mitmproxy / Charles / Burp 抓包）。

[下载最新版本](https://github.com/YOUR_GITHUB_USERNAME/AutoSystemCA/releases/latest/download/AutoSystemCA.zip)

## 原理

```
certs/ 目录 (.crt/.cer/.der/.pem)
   ↓ post-fs-data.sh（开机早期，zygote 启动前）
   ↓ openssl 自动识别 DER/PEM → 转 PEM → 计算 subject_hash_old
   ↓ 转 DER → 按 <hash>.N 命名
   ↓ 写入模块 system/ 覆盖目录：
   │   ├─ system/etc/security/cacerts/            （Android 7-13）
   │   └─ system/apex/com.android.conscrypt/cacerts/ （Android 14+）
   ↓ Root 管理器 magic mount 覆盖真实系统路径
   ↓ Android Framework 加载 → 证书生效
```

- **不修改真实 /system**：OTA 安全、卸载模块即完全恢复。
- Android 14+ 的系统 CA 存储位于 `/apex/com.android.conscrypt/cacerts`，脚本会自动检测并同时覆盖两个位置（`/system/etc/security/cacerts` 若为指向 apex 的软链则只注入 apex）。

## 使用方法

1. 在 KernelSU / Magisk 中安装 `AutoSystemCA.zip`，重启。
2. 把证书（DER 或 PEM 编码均可）拷贝到：
   ```
   /data/adb/modules/auto_system_ca/certs/
   ```
   支持 `.crt` `.cer` `.der` `.pem`，文件名不要含空格。
3. 再次重启（或运行 `su -c 'sh /data/adb/modules/auto_system_ca/post-fs-data.sh'`）。
4. 验证：
   ```bash
   ls /system/etc/security/cacerts/ | grep -E '[0-9a-f]{8}\.0'
   logcat -d | grep AutoSystemCA
   ```
   看到 `installed 9a5ba575.0 <- burp.crt` 即成功。
5. 删除 `certs/` 里的证书文件并重启，对应证书会自动从系统信任库移除。

## 特性

- DER / PEM 自动识别，无需手动转换
- 按 `subject_hash_old` 生成 Android 标准文件名 `hash.0`
- hash 冲突自动使用 `.0/.1/.2...` 递增后缀
- 输出严格为 DER 编码（系统信任库要求，与 MoveCertificate 一致）
- 权限 0644、属主 0:0、SELinux context 修复（`u:object_r:system_file:s0`）
- 清单驱动的自动清理：源文件删除后重启自动移除对应证书
- Android 7~16 自动适配 system / apex 双路径
- 幂等：重复运行不会产生重复安装

## 依赖

- 转换需要 `openssl`（绝大多数 ROM 自带；若缺失，把静态 openssl 放到模块的 `tools/openssl` 即可）
- Android 14+ 的 `/apex` 覆盖需要较新版本的 KernelSU（或 Magisk 26+）

## 在线更新

发布新版本并打 tag（`v1.0`、`v1.1`...）后，模块管理器（KernelSU / Magisk）会通过 `updateJson` 自动检测到更新：

- 仓库每打一个 `v*` 的 tag，[GitHub Actions](.github/workflows/release.yml) 会自动构建 `AutoSystemCA.zip` 并发布到 Release
- 模块管理器读取 [update.json](update.json) 里的 `zipUrl` 完成下载更新
- 前提：把 `module.prop` 和 `update.json` 中的 `YOUR_GITHUB_USERNAME` 替换为你的 GitHub 用户名

## 从源码构建

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/AutoSystemCA.git
cd AutoSystemCA
python build.py        # 生成 AutoSystemCA.zip
```

## 目录结构

```
AutoSystemCA/
├── module.prop          # 模块元信息（含 updateJson 更新检查）
├── customize.sh         # 安装时执行
├── post-fs-data.sh      # 核心注入逻辑（开机早期执行）
├── service.sh           # 开机完成后二次校验（幂等）
├── certs/               # ← 把证书丢这里
├── update.json          # 模块管理器在线更新信息
├── build.py             # 本地打包脚本
├── changelog.md         # 更新日志
├── LICENSE              # MIT
└── .github/workflows/   # CI：自动打包发布 + ShellCheck 检查
```

## 日志

```bash
logcat -d | grep AutoSystemCA
```

## License

[MIT](LICENSE)
