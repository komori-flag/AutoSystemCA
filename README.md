# AutoSystemCA

![License](https://img.shields.io/github/license/komori-flag/AutoSystemCA)
![Release](https://img.shields.io/github/v/release/komori-flag/AutoSystemCA)

KernelSU / Magisk / APatch 开机自动系统 CA 注入模块。

把证书丢进 `certs/` 目录 → 重启 → 证书自动以系统证书身份生效（App 默认信任，可用于 mitmproxy / Charles / Burp 抓包）。

[下载最新版本](https://github.com/komori-flag/AutoSystemCA/releases/latest/download/AutoSystemCA.zip)

## 原理（v2.0 安全架构）

```
certs/ 目录 (.crt/.cer/.der/.pem)
   ↓ post-fs-data.sh（开机早期）
   ↓ openssl 自动识别 DER/PEM → 统一为 PEM → 计算 subject_hash_old
   ↓ 按 <hash>.N 命名（PEM + 信息转储，与系统自带证书同布局）
   ↓ 合并真实信任库内容到模块目录（不隐藏系统证书，SELinux 标签修正）
   ↓ 挂载（config: INJECT_MODE=tmpfs 时）：
   │   证书库副本 → 内存 tmpfs（伪装成原厂 apex 文件属性：属主/时间戳/标签）
   │   fail-safe 校验（副本必须不少于真实库，否则中止，绝不挂空目录）
   │   bind → /apex/com.android.conscrypt/cacerts（Android 14+ 唯一触碰的路径）
   │   nsenter 注入 zygote 命名空间（运行中的进程也能立即看到）
   │   锁定为只读（匹配原厂 ro 语义）
   ↓ Android Framework 加载 → 证书生效
```

**与旧版本（v1.3~v1.5.1，已撤回）的关键区别**：

| | 旧版（危险，已撤回） | v2.0 |
|---|---|---|
| 挂载源 | 模块目录（`/data/adb/modules/...` 直接暴露在 mount 表） | **tmpfs**（mount 表无 /data 特征，检测工具的关键指纹消失） |
| 触碰路径 | system + apex 双 bind + apex 无条件 shadow | **只 apex**（Android 14+ 的权威存储；system 仅在 config `SYNC_SYSTEM=1` 时处理） |
| 进程可见性 | 依赖重启让 zygote 继承 | **nsenter 注入 zygote 命名空间**（「执行」后立即生效） |
| 失败防御 | 无 | **fail-safe**：副本不完整绝不挂载；每步失败即回滚 |
| 解耦 | 诱导安装 meta-overlayfs（其镜像模型冲突，空目录 bind 曾致系统 bootloop） | **完全不依赖任何 metamodule** |

- **不修改真实分区**：挂载重启即消失、OTA 安全、卸载模块即完全恢复。
- **passive 模式**（`config`: `INJECT_MODE=passive`）：零挂载绝对安全档——证书只写入模块目录，交由框架挂载层呈现（无框架时不生效）。

## 安全模型与检测对抗（Hunter 等）

抓包场景与检测场景在时间上通常是分离的，v2.0 据此设计：

1. **默认 tmpfs 模式**：挂载条目为 `tmpfs`，`/proc/mounts` 中不出现 `/data` 或模块路径——Hunter 的 `ACTIVE_DATA_BACKED_SYSTEM_MOUNT` 类检测（基于"系统路径 backing 来自 /data"的特征）失去依据
2. **KernelSU 策略反转配置**（进一步隔离）：
   - KSU Manager → 设置 → **启用「默认卸载模块」**：未授权应用（Hunter、银行类）在纯净沙盒中启动，其命名空间内完全无挂载痕迹
   - **反向授权抓包工具**：为 AdGuard / 浏览器 / 抓包 App 单独开启「保留模块挂载」，只有它们能看到证书
   - 配合 LSPosed 的隐藏应用列表隐藏 root 管理类工具
3. **需要绝对零挂载时**：`config` 切 `passive` → 系统内不存在任何相关挂载条目（证书相应不生效，适合考试/验证等敏感时期）

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
- 输出与系统一致：PEM 证书块 + `openssl -text -fingerprint` 信息转储（与设备自带 `<hash>.N` 同布局；Android 只解析首个证书块，转储被忽略，PEM/DER 均能解析）
- **SELinux context 动态修复**：从真实信任库目录读取 context（`system_security_cacerts_file:s0`）套用——写错标签会导致证书对 App 完全不可见
- **tmpfs 挂载源**：mount 表无 /data 或模块路径特征（检测对抗）
- **nsenter 注入 zygote**：「执行」后立即生效，无需重启
- **只读锁定** + **fail-safe 防御**：副本不完整绝不挂载，失败自动回滚
- 清单驱动的自动清理：源文件删除后重启自动移除对应证书
- Android 7~16 自动适配（14+ 只触碰 apex 路径）
- 幂等：重复运行不会产生重复安装
- **零 metamodule 依赖**：不要求安装 meta-overlayfs 等框架挂载组件

## 常见问题

**证书没有注入 / 没有生效**

1. 确认注入脚本是否运行过：`logcat -d | grep AutoSystemCA`，或查看
   `cat /data/adb/modules/auto_system_ca/last-run.log`（文件日志，开机早期也可靠）。
   - 有 `installed 0f4ed297.0` → 注入成功
   - 有 `no openssl and no pre-converted files` → 设备无 openssl：点模块「执行」完成转换后重启（需要 openssl：Termux `pkg install openssl-tool`，或把静态 openssl 放入模块 `tools/`）
   - 什么都没有 → 模块未执行开机脚本（检查模块是否已启用、KSU 版本；曾因 customize.sh 缺少 `POSTFSDATA` / `LATESTARTSERVICE` 声明导致，v1.1 已修复）
2. root shell 检查证书是否已在系统层：`ls /apex/com.android.conscrypt/cacerts/`（低版本看 `ls /system/etc/security/cacerts/`）
   - **root 能看到但 App 不信任** → 查看 `mount | grep cacerts`：挂载在则检查 SELinux 标签（`ls -Z` 应为 `system_security_cacerts_file`）；也可能是目标应用被配置为「卸载模块」隐藏挂载
   - **root 也看不到 → 检查日志有无 `ABORT`**：fail-safe 中止（副本不完整）不会挂载任何东西
   - **证书对某些 App 生效、对另一些不生效** → 正常的策略隔离：为需要证书的应用开启「保留模块挂载」

**修改证书后想立即生效，不想重启**

KSU Manager → 模块 → AutoSystemCA → 「执行」——v2.0 的 nsenter 会注入运行中的 zygote，证书立即生效（无需重启）。

**证书仍然不生效（HyperOS / 个别 ROM）**

个别 ROM 的框架仍读取 `/system/etc/security/cacerts`（真实目录而非软链）。在 `config` 中设 `SYNC_SYSTEM=1` 后重启，模块会同时接管该路径。

## 依赖

- 转换需要 `openssl`（绝大多数 ROM 自带；若缺失，把静态 openssl 放到模块的 `tools/openssl` 即可，或用 Termux `pkg install openssl-tool`）
- **不依赖任何 KernelSU metamodule**（meta-overlayfs 等）；`nsenter`/`pgrep` 使用系统自带 toybox

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
├── config               # INJECT_MODE=tmpfs|passive、SYNC_SYSTEM=0|1
├── customize.sh         # 安装时执行
├── post-fs-data.sh      # 核心注入逻辑（tmpfs 挂载 + nsenter + 只读锁）
├── service.sh           # 开机完成后二次校验（幂等）
├── action.sh            # KSU Manager「执行」按钮：转换 + 即时注入
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
