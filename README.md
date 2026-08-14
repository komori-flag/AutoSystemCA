# AutoSystemCA

![License](https://img.shields.io/github/license/komori-flag/AutoSystemCA)
![Release](https://img.shields.io/github/v/release/komori-flag/AutoSystemCA)

KernelSU / Magisk / APatch 开机自动系统 CA 注入模块。

把证书丢进 `certs/` 目录 → 重启 → 证书自动以系统证书身份生效（App 默认信任，可用于 mitmproxy / Charles / Burp 抓包）。

[下载最新版本](https://github.com/komori-flag/AutoSystemCA/releases/latest/download/AutoSystemCA.zip)

## 原理

```
certs/ 目录 (.crt/.cer/.der/.pem)
   ↓ post-fs-data.sh（开机早期，zygote 启动前）
   ↓ openssl 自动识别 DER/PEM → 统一为 PEM → 计算 subject_hash_old
   ↓ 按 <hash>.N 命名（PEM + 信息转储，与系统自带证书同布局）
   ↓ 合并真实信任库内容到模块目录（不隐藏系统证书）
   ↓ 写入模块 system/ 覆盖目录：
   │   ├─ system/etc/security/cacerts/            （Android 7-13）
   │   └─ system/apex/com.android.conscrypt/cacerts/ （Android 14+）
   ↓ bind mount 到真实系统路径（路径已被 metamodule 挂载则自动跳过）
   ↓ Android Framework 加载 → 证书生效
```

- **不修改真实 /system**：bind mount 重启即消失、OTA 安全、卸载模块即完全恢复。
- 注入使用 `mount --bind`，**不依赖 KSU magic mount**（KernelSU 3.0+ 已移除内置挂载，需要 metamodule 如 meta-overlayfs；无 metamodule 或挂载失效时 bind mount 兜底生效）。
- Android 14+ 的系统 CA 存储位于 `/apex/com.android.conscrypt/cacerts`，脚本会自动检测并同时覆盖两个位置（`/system/etc/security/cacerts` 若为指向 apex 的软链则只注入 apex）。

## 使用方法

统一流程：**证书放入 `certs/` → 转换（无 openssl 时需要）→ 重启生效**。

1. 在 KernelSU / Magisk 中安装 `AutoSystemCA.zip`，重启。
2. 把证书（DER 或 PEM 编码均可）拷贝到：
   ```
   /data/adb/modules/auto_system_ca/certs/
   ```
   支持 `.crt` `.cer` `.der` `.pem`，文件名不要含空格。
3. **转换**（二选一）：
   - 设备有 openssl：跳过，直接重启——开机自动转换并注入
   - 设备无 openssl：KSU Manager → 模块 → AutoSystemCA → **「执行」**，转换产物输出到
     `converted/`（原始文件保留）；或放入电脑预转换好的 `<hash>.0` 文件到 `converted/`（见下方命令）
4. **重启生效**（「执行」后也可强制停止目标应用立即生效）。
   - 查看转换来源：`cat /data/adb/modules/auto_system_ca/converted/mapping.txt`（格式 `hash.N|原始文件名`）
5. 验证：
   ```bash
   logcat -d | grep AutoSystemCA
   ```
   看到 `installed 0f4ed297.0` 即成功；root 侧可查 `ls /apex/com.android.conscrypt/cacerts/`。
6. 删除 `certs/` 里的证书文件并重启，对应证书会自动从系统信任库移除。

> **电脑预转换命令**（设备无 openssl 时适用）：
> ```bash
> HASH=$(openssl x509 -in your.crt -subject_hash_old -noout)
> openssl x509 -in your.crt -out $HASH.0                          # PEM 编码的 <hash>.0
> openssl x509 -in $HASH.0 -text -fingerprint -noout >> $HASH.0   # 附加信息转储（与系统文件同布局）
> ```

## 特性

- DER / PEM 自动识别，无需手动转换
- 按 `subject_hash_old` 生成 Android 标准文件名 `hash.0`
- hash 冲突自动使用 `.0/.1/.2...` 递增后缀
- 输出与系统一致：PEM 证书块 + `openssl -text -fingerprint` 信息转储（与设备自带 `system/etc/security/cacerts/` 的 `<hash>.N` 同布局；Android 只解析首个证书块，转储被忽略，PEM/DER 均能解析）
- 权限 0644、属主 0:0、SELinux context 修复（`u:object_r:system_file:s0`）
- 清单驱动的自动清理：源文件删除后重启自动移除对应证书
- Android 7~16 自动适配 system / apex 双路径
- 幂等：重复运行不会产生重复安装

## 常见问题

**证书没有注入 / 没有生效**

1. 确认注入脚本是否运行过：`logcat -d | grep AutoSystemCA`，或查看
   `cat /data/adb/modules/auto_system_ca/last-run.log`（文件日志，开机早期也可靠）。
   - 有 `installed 0f4ed297.0` → 注入成功
   - 有 `no openssl and no pre-converted files` → 设备无 openssl：点模块「执行」完成转换后重启（需要 openssl：Termux `pkg install openssl-tool`，或把静态 openssl 放入模块 `tools/`）
   - 什么都没有 → 模块未执行开机脚本（检查模块是否已启用、KSU 版本；曾因 customize.sh 缺少 `POSTFSDATA` / `LATESTARTSERVICE` 声明导致，v1.1 已修复）
2. root shell 检查证书是否已在系统层：`ls /system/etc/security/cacerts/`（Android 14+ 看 `ls /apex/com.android.conscrypt/cacerts/`）
   - **root 能看到但 App 不信任** → KernelSU「默认卸载模块」设置会让没有自定义 Profile 的应用隐藏模块挂载：关闭该设置，或为目标应用设置「保留模块挂载」，再重启应用
   - **root 也看不到** → 检查 KSU 版本是否支持 Android 14+ 的 `/apex` 覆盖

**修改证书后想立即生效，不想重启**

KSU Manager → 模块 → AutoSystemCA → 「执行」（先转换再注入），然后强制停止目标应用重开（或重启）。

## 依赖

- 转换需要 `openssl`（绝大多数 ROM 自带；若缺失，把静态 openssl 放到模块的 `tools/openssl` 即可）
- Android 14+ 的 `/apex` 覆盖需要较新版本的 KernelSU（或 Magisk 26+）

## 在线更新

发布新版本并打 tag（`v1.0`、`v1.1`...）后，模块管理器（KernelSU / Magisk）会通过 `updateJson` 自动检测到更新：

- 仓库每打一个 `v*` 的 tag，[GitHub Actions](.github/workflows/release.yml) 会自动构建 `AutoSystemCA.zip` 并发布到 Release
- 模块管理器读取 [update.json](update.json) 里的 `zipUrl` 完成下载更新
- 前提：把 `module.prop` 和 `update.json` 中的 `komori-flag` 替换为你的 GitHub 用户名

## 从源码构建

```bash
git clone https://github.com/komori-flag/AutoSystemCA.git
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
├── action.sh            # KSU Manager「执行」按钮：转换 + 注入
├── webroot/             # KSU 模块 WebUI（使用说明/排查）
├── certs/               # ← 原始证书放这里（保留不动）
├── converted/           # 「执行」转换后的 <hash>.N 文件 + mapping.txt 来源映射
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
