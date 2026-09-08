#!/system/bin/sh
# AutoSystemCA - boot-time system CA injector (KernelSU / Magisk / APatch)
#
# Single flow: drop certificates into $MODDIR/certs/ and reboot.
# Directory layout:
#   certs/      raw certificates, kept as-is
#   converted/  <subject_hash_old>.N files - produced by the module
#               action (Execute) or converted with openssl on a PC
#
# At boot this script:
#   1. merges the real trust store into the module staging dirs so the
#      overlay never hides the original system certificates
#   2. copies converted files from converted/ (and pre-converted
#      <hash>.N files dropped into certs/) into the staging dirs
#   3. if openssl is available, converts raw .crt/.cer/.der/.pem files
#      (DER/PEM auto-detect, normalized to PEM + trailing text dump,
#      matching the stock store layout) and injects them too
#   4. bind-mounts the merged staging dirs over the real trust-store
#      paths (system + apex). bind mount does NOT depend on KSU magic
#      mount, which is unreliable on HyperOS/MIUI and some KSU builds.
#
# Devices without openssl: run the module action once (KernelSU
# Manager -> module -> Execute) to convert certs/ files into <hash>.N,
# then reboot - the boot script then only copies them (step 2).
#
# The real /system is never modified: bind mounts vanish on reboot,
# module uninstall removes the staging dirs - OTA-safe.
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

# SELinux context of the real trust store. Conscrypt only trusts files
# labeled with the store's own type (system_security_cacerts_file:s0 on
# stock); writing files as system_file:s0 made them invisible to every
# app (root shell could still read them - v1.5.1 fix). Value refined
# after PAIRS is resolved below.
TRUST_CTX="u:object_r:system_security_cacerts_file:s0"

# fix SELinux context so the trust manager can read the file
fix_ctx() {
    if command -v chcon >/dev/null 2>&1; then
        chcon "$TRUST_CTX" "$1" 2>/dev/null
    elif [ -x /system/bin/toybox ]; then
        /system/bin/toybox chcon "$TRUST_CTX" "$1" 2>/dev/null
    fi
}

# split a "staging|real" pair string into $staging and $real.
# NOTE: ${var%|*} / ${var#*|} MUST NOT be used here - Android's mksh
# (R59) treats a bare | inside a parameter-expansion pattern as an
# alternation operator, so the strip silently fails and both halves
# come back as the whole pair. IFS word-splitting is POSIX-exact.
pair_of() {  # $1 = pair; sets global $staging and $real
    local _ifs
    _ifs=$IFS
    IFS='|'
    set -- $1
    staging=$1
    real=$2
    IFS=$_ifs
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
# 2. resolve trust-store pairs "staging|real"
#    Android 14+: /system/etc/security/cacerts may be a symlink to the
#    apex store - then only the apex pair is used.
# ------------------------------------------------------------------
PAIRS=""
if [ -d /apex/com.android.conscrypt/cacerts ]; then
    PAIRS="$MOD_SYSTEM/apex/com.android.conscrypt/cacerts|/apex/com.android.conscrypt/cacerts"
    if [ ! -L /system/etc/security/cacerts ]; then
        PAIRS="$PAIRS $MOD_SYSTEM/etc/security/cacerts|/system/etc/security/cacerts"
    fi
else
    PAIRS="$MOD_SYSTEM/etc/security/cacerts|/system/etc/security/cacerts"
fi

# staging dirs only (used by cleanup / pass-through / conversion)
TARGETS=""
for p in $PAIRS; do
    pair_of "$p"
    TARGETS="$TARGETS $staging"
done

# refine the trust-store SELinux context from the real store (some ROMs
# use a different type; fall back to the stock default above)
for p in $PAIRS; do
    pair_of "$p"
    [ -d "$real" ] || continue
    CTX=$(ls -Zd "$real" 2>/dev/null | awk '{print $1}')
    [ -n "$CTX" ] && TRUST_CTX="$CTX" && break
done

# ------------------------------------------------------------------
# 3. merge: copy stock certificates from the real store into the
#    staging dirs, so the overlay/bind never hides the originals
# ------------------------------------------------------------------
for p in $PAIRS; do
    pair_of "$p"
    mkdir -p "$staging"
    # the staging dir itself must carry the store's context too
    fix_ctx "$staging"
    [ -d "$real" ] || continue
    for f in "$real"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        if [ ! -f "$staging/$name" ]; then
            cp "$f" "$staging/$name"
            chmod 0644 "$staging/$name"
            chown 0:0 "$staging/$name"
        fi
        # refresh the label even for pre-existing files (upgrades from
        # versions that wrote system_file:s0 must be re-labeled)
        fix_ctx "$staging/$name"
    done
done

# ------------------------------------------------------------------
# 4. prune converted/: remove converted files whose original
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
# 5. cleanup: remove previously installed hashes whose source
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
# 6. converted certificates (no openssl needed)
#    Files named <subject_hash_old>.N (e.g. 0f4ed297.0) are already in
#    the final trust-store format - produced by the module action into
#    converted/, or converted with openssl on a PC and dropped into
#    converted/ or certs/. Just copy them into the staging dirs.
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
            fix_ctx "$t/$name"
            log_i "installed $name <- $src_name"
        done
        echo "$name|$src_name" >> "$MANIFEST.tmp"
    done
done

# ------------------------------------------------------------------
# 7. openssl conversion path (only when openssl is available)
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
        rm -f "$PEM"

        # auto-detect DER vs PEM encoding, normalize to PEM - the stock
        # trust store ships PEM (e.g. /system/etc/security/cacerts/*.0)
        # and Android parses both, so match the device's own format
        if grep -q "BEGIN CERTIFICATE" "$src" 2>/dev/null; then
            cp "$src" "$PEM"
        else
            "$OPENSSL" x509 -inform DER -in "$src" -outform PEM -out "$PEM" 2>/dev/null
        fi
        [ -f "$PEM" ] || { log_i "failed to read certificate: $name"; continue; }

        HASH=$("$OPENSSL" x509 -subject_hash_old -in "$PEM" -noout 2>/dev/null)
        [ -n "$HASH" ] || { log_i "not a valid certificate (no subject hash): $name"; continue; }

        # append an openssl -text -fingerprint dump after the PEM block,
        # same layout as the stock system certificate files (Android
        # ignores everything after the first certificate block)
        "$OPENSSL" x509 -in "$PEM" -text -fingerprint -noout >> "$PEM" 2>/dev/null

        log_i "processing $name (hash $HASH)"

        index=""
        for t in $TARGETS; do
            mkdir -p "$t"
            n=0
            while [ "$n" -lt 100 ]; do
                target="$t/$HASH.$n"
                if [ ! -f "$target" ]; then
                    cp "$PEM" "$target"
                    chmod 0644 "$target"
                    chown 0:0 "$target"
                    fix_ctx "$target"
                    [ -z "$index" ] && index="$HASH.$n"
                    break
                elif cmp -s "$PEM" "$target"; then
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

# ------------------------------------------------------------------
# 8. mount the merged staging dirs over the real trust-store paths.
#
#    Preferred: let the root framework serve the module's system/ tree
#    (KernelSU 3.x metamodule like meta-overlayfs). Framework mounts
#    can be hidden per-app (unmount-on-demand / "unmount modules"
#    profiles) - our own mounts would bypass that and stay visible to
#    every process (this is how MoveCertificate behaves: no self-mount).
#
#    Per-path decision: if a path (or any ancestor, e.g. an overlay on
#    /system) already has a mount, the framework is serving it - skip.
#    Otherwise bind-mount as a fallback and remount read-only to match
#    the stock ro /system. The fallback also covers a metamodule that
#    is installed but not actually mounting anything.
#
#    Later injections write the staging source dir (rw, on /data) and
#    are visible through any active mount immediately.
# ------------------------------------------------------------------
# Idempotency check: has OUR staging dir already been bound to a real
# path? (/proc/mounts shows the bind source for bind mounts.) Do NOT
# skip on any pre-existing mount at the target - HyperOS mounts the
# apex cacerts store natively (f2fs/dm-*) and Android 14+ conscrypt
# reads the apex path, so that native mount must be shadowed by our
# bind or the certificates never reach the framework. Our staging dirs
# already merged the stock certs, so shadowing loses nothing.
already_bound() {  # $1 = staging dir
    grep -q " $1 " /proc/mounts 2>/dev/null
}

for p in $PAIRS; do
    pair_of "$p"
    [ -d "$staging" ] || continue
    [ -d "$real" ] || continue
    if already_bound "$staging"; then
        log_i "already bind-mounted: $real"
        continue
    fi
    if mount --bind "$staging" "$real" 2>/dev/null; then
        log_i "bind-mounted $staging -> $real"
        if mount -o remount,ro,bind "$real" 2>/dev/null; then
            log_i "remounted read-only: $real"
        else
            log_i "warning: could not remount $real read-only"
        fi
    else
        log_i "bind mount failed: $real"
    fi
done

log_i "finished"
