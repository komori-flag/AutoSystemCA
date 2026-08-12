#!/system/bin/sh
# AutoSystemCA - module installer (runs once when the module is installed)

ui_print "*******************************"
ui_print "   AutoSystemCA v1.0"
ui_print "*******************************"
ui_print "- Setting up module files..."

mkdir -p "$MODPATH/certs"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755

ui_print "- Done!"
ui_print "- Drop your certificates into:"
ui_print "  /data/adb/modules/auto_system_ca/certs/"
ui_print "- Then reboot to inject them."
