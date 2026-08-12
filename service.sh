#!/system/bin/sh
# AutoSystemCA - late-boot re-verification pass
#
# post-fs-data.sh already injected the certificates early (before zygote
# starts). This second pass runs after the system has fully settled and
# re-installs anything that went missing, guarding against races with
# APEX / trust-store initialization on some devices. The injection
# logic in post-fs-data.sh is idempotent (identical certs are skipped),
# so re-running it is safe.

MODDIR=${0%/*}

# let the boot sequence settle before re-checking
sleep 10

[ -f "$MODDIR/post-fs-data.sh" ] || exit 0
sh "$MODDIR/post-fs-data.sh"
