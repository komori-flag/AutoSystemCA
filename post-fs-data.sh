#!/system/bin/sh
# AutoSystemCA - boot-time system CA injector (KernelSU / Magisk / APatch)
#
# Single flow: drop certificates into $MODDIR/certs/ and reboot.
# At boot this script:
#   1. copies pre-converted files (named <subject_hash_old>.N, e.g.
#      0f4ed297.0 - converted with openssl on a PC or by the module
#      action) into the system overlay - no openssl needed
#   2. if openssl is available, additionally converts raw
#      .crt/.cer/.der/.pem files (DER/PEM auto-detect) and injects them
#
# Devices without openssl: run the module action once (KernelSU
# Manager -> module -> Execute) to convert certs/ files into <hash>.N,
# then reboot - the boot script then only copies them (step 1).
#
# Injection targets (module overlay, NOT /system): system/etc/security/
# cacerts and, on Android 14+, system/apex/com.android.conscrypt/cacerts.
# The real /system is never modified: OTA-safe and fully removed when
# the module is uninstalled.
#
# Debug: logcat | grep AutoSystemCA  /  cat $MODDIR/last-run.log

MODDIR=${0%/*}

LOG_TAG=AutoSystemCA
CERT_DIR="$MODDIR/certs"
LOG_FILE="$MODDIR/last-run.log"
MOD_SYSTEM="$MODDIR/system"
MANIFEST="$MODDIR/.installed.list"
TMP_DIR=/data/local/tmp/auto_system_ca

log_i() {
    if [ -x /system/bin/log ]; then
        log -t "$LOG_TAG" "$1"
    else
        echo "AutoSystemCA: $1"
    fi
    # 文件日志：即使开机早期 logd 未就绪，也能确认脚本是否运行过
    echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null
}

mkdir -p "$CERT_DIR" "$TMP_DIR"

log_i "post-fs-data.sh started"

# ------------------------------------------------------------------
# 1. openssl detection (only needed for the conversion path)
# ------------------------------------------------------------------
OPENSSL=$(command -v openssl 2>/dev/null)
[ -z "$OPENSSL" ] && [ -x /system/bin/openssl ] && OPENSSL=/system/bin/openssl
[ -z "$OPENSSL" ] && [ -x /system/xbin/openssl ] && OPENSSL=/system/xbin/openssl
if [ -z "$OPENSSL" ] && [ -x "$MODDIR/tools/openssl" ]; then
    OPENSSL="$MODDIR/tools/openssl"
fi

# ------------------------------------------------------------------
# 2. resolve trust-store targets (module overlay paths, NOT /system!)
#    Android 14+: /system/etc/security/cacerts is a symlink to the
#    apex store, so inject into the apex overlay instead.
# ------------------------------------------------------------------
TARGETS=""
if [ -d /apex/com.android.conscrypt/cacerts ]; then
    TARGETS="$MOD_SYSTEM/apex/com.android.conscrypt/cacerts"
    if [ ! -L /system/etc/security/cacerts ]; then
        TARGETS="$TARGETS $MOD_SYSTEM/etc/security/cacerts"
    fi
else
    TARGETS="$MOD_SYSTEM/etc/security/cacerts"
fi

# ------------------------------------------------------------------
# 3. cleanup: remove previously installed hashes whose source
#    certificate file has been deleted from certs/
# ------------------------------------------------------------------
if [ -f "$MANIFEST" ]; then
    while IFS='|' read -r installed_name src_name; do
        [ -n "$installed_name" ] || continue
        [ -f "$CERT_DIR/$src_name" ] && continue
        for t in $TARGETS; do
            [ -f "$t/$installed_name" ] && rm -f "$t/$installed_name"
        done
        log_i "removed stale $installed_name (source $src_name deleted)"
    done < "$MANIFEST"
fi

# 本次运行安装清单
: > "$MANIFEST.tmp"

# ------------------------------------------------------------------
# 4. pre-converted certificates (no openssl needed)
#    Files named <subject_hash_old>.N (e.g. 0f4ed297.0) are already in
#    the final trust-store format - converted with openssl on a PC or
#    by the module action. Just copy them into the overlay as-is.
# ------------------------------------------------------------------
for src in "$CERT_DIR"/*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    case "$name" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].[0-9]|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].[0-9][0-9]) ;;
        *) continue ;;
    esac
    for t in $TARGETS; do
        mkdir -p "$t"
        if [ -f "$t/$name" ]; then
            cmp -s "$src" "$t/$name" && continue
            log_i "skip $name (target occupied by a different cert)"
            continue
        fi
        cp "$src" "$t/$name"
        chmod 0644 "$t/$name"
        chown 0:0 "$t/$name"
        # fix SELinux context so the trust manager can read it
        if command -v chcon >/dev/null 2>&1; then
            chcon u:object_r:system_file:s0 "$t/$name" 2>/dev/null
        elif [ -x /system/bin/toybox ]; then
            /system/bin/toybox chcon u:object_r:system_file:s0 "$t/$name" 2>/dev/null
        fi
        log_i "installed $name"
    done
    echo "$name|$name" >> "$MANIFEST.tmp"
done

# ------------------------------------------------------------------
# 5. openssl conversion path (only when openssl is available)
# ------------------------------------------------------------------
if [ -n "$OPENSSL" ]; then
    for src in "$CERT_DIR"/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in
            *.crt|*.cer|*.der|*.pem|*.CRT|*.CER|*.DER|*.PEM) ;;
            *) log_i "skip $name (unsupported extension)"; continue ;;
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
        [ -f "$PEM" ] || { log_i "failed to read certificate: $name"; continue; }

        HASH=$("$OPENSSL" x509 -subject_hash_old -in "$PEM" -noout 2>/dev/null)
        [ -n "$HASH" ] || { log_i "not a valid certificate (no subject hash): $name"; continue; }

        # the system trust store requires DER content, not PEM
        "$OPENSSL" x509 -in "$PEM" -outform DER -out "$DER" 2>/dev/null
        [ -f "$DER" ] || { log_i "failed to convert to DER: $name"; continue; }

        log_i "processing $name (hash $HASH)"

        index=""
        for t in $TARGETS; do
            mkdir -p "$t"
            n=0
            while [ "$n" -lt 100 ]; do
                target="$t/$HASH.$n"
                if [ ! -f "$target" ]; then
                    cp "$DER" "$target"
                    chmod 0644 "$target"
                    chown 0:0 "$target"
                    # fix SELinux context so the trust manager can read it
                    if command -v chcon >/dev/null 2>&1; then
                        chcon u:object_r:system_file:s0 "$target" 2>/dev/null
                    elif [ -x /system/bin/toybox ]; then
                        /system/bin/toybox chcon u:object_r:system_file:s0 "$target" 2>/dev/null
                    fi
                    [ -z "$index" ] && index="$HASH.$n"
                    break
                elif cmp -s "$DER" "$target"; then
                    # identical certificate already installed at this index
                    [ -z "$index" ] && index="$HASH.$n"
                    break
                else
                    # hash collision -> next index (.0/.1/.2 ...)
                    n=$((n + 1))
                fi
            done
        done

        if [ -n "$index" ]; then
            echo "$index|$name" >> "$MANIFEST.tmp"
            log_i "installed $index <- $name"
        fi
    done
else
    log_i "no openssl and no pre-converted files - run the module action (Execute) once to convert certificates, then reboot"
fi

[ -f "$MANIFEST.tmp" ] && mv -f "$MANIFEST.tmp" "$MANIFEST"

log_i "finished"
