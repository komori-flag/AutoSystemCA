#!/system/bin/sh
# AutoSystemCA - on-demand convert + inject (KernelSU Manager -> Execute)
#
# 1. converts raw certificates in certs/ (.crt/.cer/.der/.pem, DER/PEM)
#    into the final trust-store files <subject_hash_old>.N in
#    converted/ - the originals are KEPT
# 2. rebuilds converted/mapping.txt ("hash.N|original-name") so the
#    origin of every converted file stays traceable
# 3. re-runs the injection (post-fs-data.sh) - in tmpfs mode this also
#    uses nsenter to place the mount into running zygote namespaces, so
#    no reboot is needed for the certificates to become effective
#
# openssl is looked up in: PATH, /system/bin, /system/xbin, module
# tools/ and Termux (/data/data/com.termux/files/usr/bin) - install it
# with e.g. "pkg install openssl-tool" if missing.

MODDIR=$(cd "$(dirname "$0")" && pwd)
CERT_DIR="$MODDIR/certs"
CONVERTED_DIR="$MODDIR/converted"
LOG_FILE="$MODDIR/last-run.log"
TMP_DIR=/data/local/tmp/auto_system_ca

log_i() {
    echo "AutoSystemCA: $1"
    echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null
}

mkdir -p "$CERT_DIR" "$CONVERTED_DIR" "$TMP_DIR"

log_i "action: started"

# locate openssl (Termux path is usable here, after user unlock)
OPENSSL=$(command -v openssl 2>/dev/null)
[ -z "$OPENSSL" ] && [ -x /system/bin/openssl ] && OPENSSL=/system/bin/openssl
[ -z "$OPENSSL" ] && [ -x /system/xbin/openssl ] && OPENSSL=/system/xbin/openssl
[ -z "$OPENSSL" ] && [ -x "$MODDIR/tools/openssl" ] && OPENSSL="$MODDIR/tools/openssl"
[ -z "$OPENSSL" ] && [ -x /data/data/com.termux/files/usr/bin/openssl ] && OPENSSL=/data/data/com.termux/files/usr/bin/openssl

if [ -z "$OPENSSL" ]; then
    log_i "action: openssl not found - install it (Termux: pkg install openssl-tool), or drop pre-converted <hash>.0 files into converted/"
else
    : > "$CONVERTED_DIR/mapping.txt.tmp"
    for src in "$CERT_DIR"/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in
            *.crt|*.cer|*.der|*.pem|*.CRT|*.CER|*.DER|*.PEM) ;;
            *) continue ;;
        esac

        PEM="$TMP_DIR/$name.pem"
        rm -f "$PEM"

        # auto-detect DER vs PEM encoding, normalize to PEM - the stock
        # trust store ships PEM (e.g. /system/etc/security/cacerts/*.0)
        # and Android parses both, so match the device's own format
        if grep -q "BEGIN CERTIFICATE" "$src" 2>/dev/null; then
            cp "$src" "$PEM"
        else
            "$OPENSSL" x509 -inform DER -in "$src" -outform PEM -out "$PEM" 2>/dev/null
        fi
        [ -f "$PEM" ] || { log_i "action: cannot read $name"; continue; }

        HASH=$("$OPENSSL" x509 -subject_hash_old -in "$PEM" -noout 2>/dev/null)
        [ -n "$HASH" ] || { log_i "action: $name is not a valid certificate"; continue; }

        # append an openssl -text -fingerprint dump after the PEM block,
        # same layout as the stock system certificate files (Android
        # ignores everything after the first certificate block)
        "$OPENSSL" x509 -in "$PEM" -text -fingerprint -noout >> "$PEM" 2>/dev/null

        # write converted/<hash>.N as PEM, keep the original in certs/
        idx=0
        while [ -f "$CONVERTED_DIR/$HASH.$idx" ]; do
            cmp -s "$PEM" "$CONVERTED_DIR/$HASH.$idx" && break
            idx=$((idx + 1))
        done
        if ! cmp -s "$PEM" "$CONVERTED_DIR/$HASH.$idx" 2>/dev/null; then
            cp "$PEM" "$CONVERTED_DIR/$HASH.$idx"
            log_i "action: converted $name -> converted/$HASH.$idx"
        else
            log_i "action: $name already converted (converted/$HASH.$idx)"
        fi
        echo "$HASH.$idx|$name" >> "$CONVERTED_DIR/mapping.txt.tmp"
    done
    [ -f "$CONVERTED_DIR/mapping.txt.tmp" ] && mv -f "$CONVERTED_DIR/mapping.txt.tmp" "$CONVERTED_DIR/mapping.txt"
fi

# inject now (tmpfs mode: nsenter makes it effective immediately)
[ -f "$MODDIR/post-fs-data.sh" ] && sh "$MODDIR/post-fs-data.sh"

log_i "action: done"
