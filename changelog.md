# Changelog

## v1.5.1

- **修复 SELinux context（决定性）**：注入文件此前被标记为 `system_file:s0`，而真实信任库是 `system_security_cacerts_file:s0`——conscrypt 的 SELinux 策略拒绝读取，导致 root 可见但所有 App 与系统设置均不可见。现在改为从真实信任库目录动态读取 context 套用（staging 目录与文件、含旧版本升级残留一并重刷）
- **修复 mksh 参数展开 bug（决定性）**：Android mksh R59 把 `${var%|*}` / `${var#*|}` 中 pattern 的裸 `|` 当作 alternation，剥离静默失败——staging/real 路径全变成带 `|` 的怪路径。改用 `IFS='|'` + `set --` 分词（`pair_of` 函数，POSIX 精确）
- **apex 路径无条件 bind**：幂等检测改为查 `/proc/mounts` 是否已有本模块 staging 的 bind；不再因"路径已有任何挂载"而跳过——HyperOS 上 apex cacerts 存在原生挂载，Android 14+ framework 读 apex 路径，必须 shadow 原生挂载注入才生效（staging 已 merge stock，shadow 无损失）
- 验证：注入后「设置 → 信任的凭据 → 系统」可见自签 CA（真机实测通过）

## v1.5

- **框架挂载模式（默认）**：检测到 KernelSU 3.x metamodule（`/data/adb/metamodule`，如 meta-overlayfs）时不再自行 bind mount，模块 `system/` 树交由 root 框架挂载——挂载受内核按需卸载与「卸载模块」App Profile 管理，可对检测类应用隐藏（与 MoveCertificate 同思路：不自挂载）
- bind mount 保留为**无 metamodule 设备**的兜底（降级路径，不隐蔽但可用）

## v1.4.1

- **bind mount 后重挂载为只读**：原厂 `/system` 为只读分区，此前 rw 的 bind 挂载会使系统信任库目录变为可写（与原厂状态不符）。现在 bind 成功后执行 `mount -o remount,ro,bind` 恢复只读语义；后续注入仍写 staging 源目录（/data 分区 rw），通过 ro bind 视图即时可见，不受影响

## v1.4

- **转换输出与系统证书同布局**：遍历设备系统信任库（如 `7d453d8f.0`）确认自带证书为「PEM 证书块 + `openssl -text -fingerprint` 信息转储」，转换产物由 DER 改为与之完全一致的格式（Android 只解析首个证书块，转储被忽略；`subject_hash_old` 命名不变，旧 DER 转换文件依然有效）
- 注意：已存在的旧版 `converted/` 文件（无转储）与新产物字节不同，下次转换会写入下一个 `.N` 索引，二者并存无副作用

## v1.3

- **新增 bind mount 注入**：不依赖 KSU magic mount / metamodule（KernelSU 3.0+ 已移除内置挂载，未装 metamodule 时无任何模块挂载生效）。开机时先把真实信任库内容合并进模块目录（bind mount 是整目录替换，避免隐藏系统证书），再 `mount --bind` 到真实路径（system + apex 双目标）
- **自适应**：路径已被 metamodule（如 meta-overlayfs）挂载时自动跳过 bind，两者不冲突
- 挂载幂等：已挂载路径跳过；重启后自动重建，卸载模块后自动消失；真实 /system 永不修改

## v1.2.2

- **日志提示修正**：已转换文件存在且注入完成时，不再打印误导性的 `no openssl and no pre-converted files` 提示；仅当真的没有任何可注入内容时才提示（附 openssl 安装指引）

## v1.2.1

- **转换产物移入独立 `converted/` 目录**：`certs/` 里的原始证书保留不动
- **新增来源追踪 `converted/mapping.txt`**：记录 `hash.N|原始文件名`，日志同步输出 `installed 0f4ed297.0 <- adguard.pem`，可随时查证每个转换文件的来源
- **联动清理**：删除 `certs/` 原始文件并重启后，对应的转换文件与已注入证书会被自动移除

## v1.2

- **流程统一为单一 certs/ 目录**：放入证书 →（无 openssl 时点「执行」转换）→ 重启生效
- **新增 action.sh 转换**：「执行」按钮把 `certs/` 里的原始证书（DER/PEM）就地转换为最终格式 `<hash>.N` 并即时注入；openssl 支持从系统、Termux、模块 `tools/` 查找
- **新增预转换直通**：`certs/` 里的 `<hash>.N` 文件开机直接复制进系统信任库，设备端无需 openssl
- **移除用户存储回退方案**（原方式 B）：避免无筛选地提升所有用户证书
- 新增 KSU WebUI 使用说明页（`webroot/`）
- 修复依赖声明后（v1.1）确认开机脚本正常执行，本版解决无 openssl 设备的注入问题

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
