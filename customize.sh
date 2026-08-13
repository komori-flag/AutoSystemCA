#!/system/bin/sh
# AutoSystemCA - module installer (runs once when the module is installed)

# 模块管理器约定：customize.sh 存在时必须显式声明这些标志位，
# 否则不会执行模块的 post-fs-data.sh / service.sh（v1.1 修复项）
SKIPMOUNT=false          # 不禁用 magic mount
PROPFILE=false           # 不修改 system props
POSTFSDATA=true          # 执行 post-fs-data.sh（开机早期注入证书）
LATESTARTSERVICE=true    # 执行 service.sh（开机完成后二次校验）

ui_print "*******************************"
ui_print "   AutoSystemCA v1.2"
ui_print "*******************************"
ui_print "- Setting up module files..."

mkdir -p "$MODPATH/certs"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

ui_print "- Done!"
ui_print "- Put certificates into:"
ui_print "  /data/adb/modules/auto_system_ca/certs/"
ui_print "- Then reboot to apply."
ui_print "- No openssl on the device? Press the"
ui_print "  module's 'Execute' button once to"
ui_print "  convert, then reboot."
