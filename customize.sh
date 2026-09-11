#!/system/bin/sh
# AutoSystemCA - module installer (runs once when the module is installed)

# 模块管理器约定：customize.sh 存在时必须显式声明这些标志位，
# 否则不会执行模块的 post-fs-data.sh / service.sh（v1.1 修复项）
# 这些变量由 Magisk/KernelSU/APatch 管理器在 source 本脚本后读取，
# 本脚本内不使用 —— ShellCheck 报 SC2034 是预期的，故屏蔽。
# shellcheck disable=SC2034
SKIPMOUNT=false          # 不禁用 magic mount
PROPFILE=false           # 不修改 system props
POSTFSDATA=true          # 执行 post-fs-data.sh（开机早期注入证书）
LATESTARTSERVICE=true    # 执行 service.sh（开机完成后二次校验）

ui_print "*******************************"
ui_print "   AutoSystemCA v2.0"
ui_print "*******************************"
ui_print "- Setting up module files..."

mkdir -p "$MODPATH/certs" "$MODPATH/converted"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

ui_print "- Done!"
ui_print "- Put certificates into:"
ui_print "  /data/adb/modules/auto_system_ca/certs/"
ui_print "- Press 'Execute' to convert them into"
ui_print "  converted/ (originals are kept)."
ui_print "- Then reboot to apply."
ui_print "- SAFE MODE: default inject mode is 'tmpfs'"
ui_print "  (confined apex mount, no /data fingerprint)."
ui_print "  config file: INJECT_MODE=tmpfs|passive"
