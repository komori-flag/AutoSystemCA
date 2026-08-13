#!/system/bin/sh
# AutoSystemCA - on-demand injection (KernelSU Manager -> module -> Execute)
#
# Re-runs the injection immediately without rebooting, e.g. after adding
# a new certificate. After running, force-stop the app that should trust
# the CA (or reboot) so it re-reads the trust store.

MODDIR=$(cd "$(dirname "$0")" && pwd)

[ -f "$MODDIR/post-fs-data.sh" ] || exit 0
sh "$MODDIR/post-fs-data.sh"
