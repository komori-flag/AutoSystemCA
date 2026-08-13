#!/system/bin/sh
# AutoSystemCA - on-demand convert + inject (KernelSU Manager -> Execute)
#
# 1. converts raw certificates in certs/ (.crt/.cer/.der/.pem, DER/PEM)
#    into the final trust-store files <subject_hash_old>.N (in place,
#    the originals are replaced by the converted files)
# 2. injects them into the system trust store immediately
#
# After converting, reboot (or force-stop the target app) for the
# certificates to become effective.
#
# openssl is looked up in: PATH, /system/bin, /system/xbin, module
# tools/ and Termux (/data/data/com.termux/files/usr/bin) - install it
# with e.g. "pkg install openssl-tool" if missing.

MODDIR=$(cd "$(dirname "$0")" && pwd)
CERT_DIR="$MODDIR/certs"
LOG_FILE="$MODDIR/last-run.log"
TMP_DIR=/data/local/tmp/auto_system_ca

log_i() {
    echo "AutoSystemCA: $1"
    echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null
}

mkdir -p "$CERT_DIR" "$TMP_DIR"

log_i "action: started"

# locate openssl (Termux path is usable here, after user unlock)
OPENSSL=$(command -v openssl 2>/dev/null)
[ -z "$OPENSSL" ] && [ -x /system/bin/openssl ] && OPENSSL=/system/bin/openssl
[ -z "$OPENSSL" ] && [ -x /system/xbin/openssl ] && OPENSSL=/system/xbin/openssl
[ -z "$OPENSSL" ] && [ -x "$MODDIR/tools/openssl" ] && OPENSSL="$MODDIR/tools/openssl"
[ -z "$OPENSSL" ] && [ -x /data/data/com.termux/files/usr/bin/openssl ] && OPENSSL=/data/data/com.termux/files/usr/bin/openssl

if [ -n "$OPENSSL" ]; then
    for src in "$CERT_DIR"/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in
            *.crt|*.cer|*.der|*.pem|*.CRT|*.CER|*.DER|*.PEM) ;;
            *) continue ;;
        esac

        PEM="$TMP_DIR/$name.pem"
        DER="$TMP_DIR/$name.der"
        rm -f "$PEM" "$DER"

        # auto-detect DER vs PEM encoding
        if grep -q "BEGIN CERTIFICATE" "$src" 2>/dev/null; then
            cp "$src" "$PEM"
        else
            "$OPENSSL" x509 -inform DER -in "$src" -outform PEM -out "$PEM" 2>/dev/null
        fi
        [ -f "$PEM" ] || { log_i "action: cannot read $name"; continue; }

        HASH=$("$OPENSSL" x509 -subject_hash_old -in "$PEM" -noout 2>/dev/null)
        [ -n "$HASH" ] || { log_i "action: $name is not a valid certificate"; continue; }

        "$OPENSSL" x509 -in "$PEM" -outform DER -out "$DER" 2>/dev/null
        [ -f "$DER" ] || { log_i "action: failed to convert $name"; continue; }

        # convert in place: raw file -> <hash>.N, skipping identical ones
        idx=0
        while [ -f "$CERT_DIR/$HASH.$idx" ]; do
            cmp -s "$DER" "$CERT_DIR/$HASH.$idx" && break
            idx=$((idx + 1))
        done
        if ! cmp -s "$DER" "$CERT_DIR/$HASH.$idx" 2>/dev/null; then
            cp "$DER" "$CERT_DIR/$HASH.$idx"
            log_i "action: converted $name -> $HASH.$idx"
        fi
        rm -f "$src"
    done
else
    log_i "action: openssl not found - install it (Termux: pkg install openssl-tool), or drop pre-converted <hash>.0 files into certs/"
fi

# inject now (pre-converted pass-through; needs no openssl)
[ -f "$MODDIR/post-fs-data.sh" ] && sh "$MODDIR/post-fs-data.sh"

log_i "action: done - reboot (or force-stop the target app) for the certificates to take effect"
