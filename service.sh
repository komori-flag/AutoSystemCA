#!/system/bin/sh
# AutoSystemCA - late-boot re-verification pass
#
# post-fs-data.sh already injected the certificates early. This second
# pass runs after the system has settled and re-applies the injection,
# guarding against races with APEX / trust-store initialization on some
# devices. The script is idempotent (existing identical mounts and
# certificates are skipped), so re-running it is safe.

MODDIR=${0%/*}

# let the boot sequence settle before re-checking
sleep 10

[ -f "$MODDIR/post-fs-data.sh" ] || exit 0
sh "$MODDIR/post-fs-data.sh"
