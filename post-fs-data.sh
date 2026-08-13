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
CONVERTED_DIR="$MODDIR/converted"
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

mkdir -p "$CERT_DIR" "$CONVERTED_DIR" "$TMP_DIR"

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
# 3. prune converted/: remove converted files whose original
#    certificate has been deleted from certs/ (per mapping.txt)
# ------------------------------------------------------------------
if [ -f "$CONVERTED_DIR/mapping.txt" ]; then
    while IFS='|' read -r map_hash map_raw; do
        [ -n "$map_hash" ] || continue
        [ -f "$CERT_DIR/$map_raw" ] && continue
        if [ -f "$CONVERTED_DIR/$map_hash" ]; then
            rm -f "$CONVERTED_DIR/$map_hash"
            log_i "pruned converted/$map_hash (source $map_raw deleted)"
        fi
    done < "$CONVERTED_DIR/mapping.txt"
fi

# ------------------------------------------------------------------
# 4. cleanup: remove previously installed hashes whose source
#    certificate file has been deleted from certs/ or converted/
# ------------------------------------------------------------------
if [ -f "$MANIFEST" ]; then
    while IFS='|' read -r installed_name src_name; do
        [ -n "$installed_name" ] || continue
        { [ -f "$CERT_DIR/$src_name" ] || [ -f "$CONVERTED_DIR/$src_name" ]; } && continue
        for t in $TARGETS; do
            [ -f "$t/$installed_name" ] && rm -f "$t/$installed_name"
        done
        log_i "removed stale $installed_name (source $src_name deleted)"
    done < "$MANIFEST"
fi

# 本次运行安装清单
: > "$MANIFEST.tmp"

# 标记本节是否处理到已转换文件（用于末尾的提示信息）
FOUND_CONVERTED=0

# ------------------------------------------------------------------
# 5. converted certificates (no openssl needed)
#    Files named <subject_hash_old>.N (e.g. 0f4ed297.0) are already in
#    the final trust-store format - produced by the module action into
#    converted/, or converted with openssl on a PC and dropped into
#    converted/ or certs/. Just copy them into the overlay as-is.
#    Traceability: converted/mapping.txt records "hash.N|original",
#    and every install is logged as "installed <hash.N> <- <original>".
# ------------------------------------------------------------------
for dir in "$CONVERTED_DIR" "$CERT_DIR"; do
    [ -d "$dir" ] || continue
    for src in "$dir"/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].[0-9]|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].[0-9][0-9]) ;;
            *) continue ;;
        esac
        FOUND_CONVERTED=1

        # look up the original source file in converted/mapping.txt
        src_name="$name"
        if [ -f "$CONVERTED_DIR/mapping.txt" ]; then
            while IFS='|' read -r map_hash map_raw; do
                [ "$map_hash" = "$name" ] && src_name="$map_raw"
            done < "$CONVERTED_DIR/mapping.txt"
        fi

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
            log_i "installed $name <- $src_name"
        done
        echo "$name|$src_name" >> "$MANIFEST.tmp"
    done
done

# ------------------------------------------------------------------
# 6. openssl conversion path (only when openssl is available)
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
elif [ "$FOUND_CONVERTED" -eq 0 ]; then
    log_i "no openssl and no converted files - install openssl (Termux: pkg install openssl-tool), press the module 'Execute' button to convert, then reboot"
fi

[ -f "$MANIFEST.tmp" ] && mv -f "$MANIFEST.tmp" "$MANIFEST"

log_i "finished"
