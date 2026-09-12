#!/system/bin/sh
# AutoSystemCA v2.0 - boot-time system CA injector (KernelSU / Magisk / APatch)
#
# Flow: drop certificates into $MODDIR/certs/ and reboot.
# Directory layout:
#   certs/      raw certificates, kept as-is
#   converted/  <subject_hash_old>.N files - produced by the module
#               action (Execute) or converted with openssl on a PC
#   config      INJECT_MODE=tmpfs|passive (see below)
#
# Inject modes (config):
#   tmpfs   (default) - the merged store is copied into a tmpfs, disguised
#           with the stock apex attributes, bind-mounted over the real
#           apex cacerts paths (plus zygote mount namespaces via nsenter)
#           and locked read-only. The mount source is tmpfs - there is no
#           /data-backed mount showing the module path in /proc/mounts,
#           which is the fingerprint detector apps look for.
#   passive - zero mounts: certificates are only staged inside the module
#           directory (with correct SELinux labels) and left for a
#           framework mount layer to serve. Nothing is ever mounted, so
#           nothing can be detected - but nothing takes effect either
#           unless the root framework mounts the module's system/ tree.
#
# Fail-safe: nothing is bind-mounted unless the tmpfs copy is verified to
# contain at least as many files as the real store. A missing or short
# copy aborts the mount instead of shadowing the store with an empty dir.
#
# The real partitions are never modified: mounts vanish on reboot, module
# uninstall removes the staging dirs - OTA-safe.
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
SRC_MNT=/mnt/.autoca_system_ca

# ------------------------------------------------------------------
# configuration (config file, defaults below)
#   INJECT_MODE=tmpfs|passive
#   SYNC_SYSTEM=0|1 - also serve /system/etc/security/cacerts when it is
#     a real directory (not a symlink to apex). Default 0: on Android 14+
#     conscrypt reads the apex path, which is the only one we touch.
# ------------------------------------------------------------------
INJECT_MODE=tmpfs
SYNC_SYSTEM=0
CONFIG_FILE="$MODDIR/config"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE" 2>/dev/null
fi
case "$INJECT_MODE" in
    tmpfs|passive) ;;
    *) INJECT_MODE=tmpfs ;;
esac

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
    # Android's mksh (POSIX mode) does support 'local'
    # shellcheck disable=SC3043
    local _ifs
    _ifs=$IFS
    IFS='|'
    set -- $1
    staging=$1
    real=$2
    IFS=$_ifs
}

mkdir -p "$CERT_DIR" "$CONVERTED_DIR" "$TMP_DIR"

log_i "post-fs-data.sh started (mode=$INJECT_MODE)"

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
#    Android 14+ (conscrypt apex present): the apex store is authoritative;
#    tap it through both the symlink path and the versioned directory, as
#    different processes resolve the path differently. The system path is
#    only added when SYNC_SYSTEM=1 and it is a real directory.
#    Android <= 13: the system path is the store.
# ------------------------------------------------------------------
PAIRS=""
if [ -d /apex/com.android.conscrypt/cacerts ]; then
    PAIRS="$MOD_SYSTEM/apex/com.android.conscrypt/cacerts|/apex/com.android.conscrypt/cacerts"
    APEX_VER_DIR=$(find /apex -maxdepth 1 -type d -name 'com.android.conscrypt@*' 2>/dev/null | head -n1)
    if [ -n "$APEX_VER_DIR" ]; then
        PAIRS="$PAIRS $MOD_SYSTEM/apex/com.android.conscrypt/cacerts|$APEX_VER_DIR/cacerts"
    fi
    if [ "$SYNC_SYSTEM" = "1" ] && [ -d /system/etc/security/cacerts ] && [ ! -L /system/etc/security/cacerts ]; then
        PAIRS="$PAIRS $MOD_SYSTEM/etc/security/cacerts|/system/etc/security/cacerts"
    fi
else
    PAIRS="$MOD_SYSTEM/etc/security/cacerts|/system/etc/security/cacerts"
fi

# staging dirs only (used by cleanup / pass-through / conversion)
TARGETS=""
for p in $PAIRS; do
    pair_of "$p"
    case " $TARGETS " in
        *" $staging "*) ;;                       # dedupe (apex pair twice)
        *) TARGETS="$TARGETS $staging" ;;
    esac
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
#    staging dirs, so the merged store never hides the originals
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
# 8. mount stage
#    tmpfs mode: copy the merged staging store into a tmpfs, disguise it
#    with the stock apex file attributes, then bind it over every real
#    target and into the zygote mount namespaces, and lock it read-only.
#    The mount source is tmpfs - /proc/mounts shows no /data-backed path
#    (the module directory never appears there), which is what mount
#    scanners flag as a root artifact.
# ------------------------------------------------------------------
if [ "$INJECT_MODE" = "passive" ]; then
    log_i "passive mode: certificates staged in $MODDIR (no mounts); framework mount layer or config change required to take effect"
    log_i "finished"
    exit 0
fi

# --- 8a. clean up our own leftovers from a previous run -------------
# Identification is by a marker file inside the served store: a mount
# whose visible content carries /$MARKER is ours. This does NOT rely on
# mount output formatting - tmpfs mounts list their source as "tmpfs",
# not as the mount point path, so source-grepping fails and layers would
# pile up on every run. Device ROMs ship a native mount on the apex
# cacerts path too; only mounts that expose our marker are ever
# unmounted, never the native one.
MARKER=.autoca_marker
for p in $PAIRS; do
    pair_of "$p"
    [ -d "$real" ] || continue
    n=0
    while [ -f "$real/$MARKER" ] && [ "$n" -lt 5 ]; do
        umount "$real" 2>/dev/null || break
        n=$((n + 1))
    done
done
umount "$SRC_MNT" 2>/dev/null
mkdir -p "$SRC_MNT"

# --- 8b. mount a fresh tmpfs as the store source ----------------------
if ! mount -t tmpfs -o mode=755,noatime tmpfs "$SRC_MNT" 2>/dev/null; then
    log_i "ABORT: could not mount tmpfs at $SRC_MNT - no changes made"
    log_i "finished"
    exit 0
fi
log_i "tmpfs mounted at $SRC_MNT"

# --- 8c. fill it from the merged staging store ------------------------
SRC_OK=0
for t in $TARGETS; do
    [ -d "$t" ] || continue
    cp -f "$t"/* "$SRC_MNT"/ 2>/dev/null
    SRC_OK=1
    break   # all staging dirs carry the same merged content
done
if [ "$SRC_OK" -ne 1 ]; then
    umount "$SRC_MNT" 2>/dev/null
    log_i "ABORT: no staging content to serve - no changes made"
    log_i "finished"
    exit 0
fi
# ownership marker: lets future runs (and no one else) identify this mount
touch "$SRC_MNT/$MARKER" 2>/dev/null

# --- 8d. fail-safe: the copy must be at least as complete as the real
#     store, or we would shadow it with an incomplete directory --------
for p in $PAIRS; do
    pair_of "$p"
    [ -d "$real" ] || continue
    real_count=$(ls -1 "$real" 2>/dev/null | wc -l)
    src_count=$(ls -1 "$SRC_MNT" 2>/dev/null | wc -l)
    if [ "$real_count" -gt 0 ] && [ "$src_count" -lt "$real_count" ]; then
        umount "$SRC_MNT" 2>/dev/null
        log_i "ABORT: tmpfs copy too small ($src_count < $real_count for $real) - no changes made"
        log_i "finished"
        exit 0
    fi
    break
done

# --- 8e. disguise with the stock apex attributes ----------------------
chown -R system:system "$SRC_MNT" 2>/dev/null
chmod -R 644 "$SRC_MNT"/* 2>/dev/null
chmod 755 "$SRC_MNT" 2>/dev/null
# stock apex certs are stamped 1970; matching hides a freshly-written look
touch -t 197001010800 "$SRC_MNT"/* "$SRC_MNT" 2>/dev/null
fix_ctx "$SRC_MNT"
for f in "$SRC_MNT"/*; do
    [ -f "$f" ] && fix_ctx "$f"
done
log_i "tmpfs store prepared: $(ls -1 "$SRC_MNT" | wc -l) files"

# --- 8f. bind over every real target ----------------------------------
# Shadowing a pre-existing native mount (HyperOS mounts the apex store
# natively - as tmpfs, as observed) is intentional: the staging store
# already merged the stock certs, so the shadow loses nothing. "Already
# done" is judged by our marker showing through the mount, not by mount
# output formatting.
BIND_OK=0
for p in $PAIRS; do
    pair_of "$p"
    [ -d "$real" ] || continue
    if [ -f "$real/$MARKER" ]; then
        log_i "already bind-mounted (our tmpfs): $real"
        BIND_OK=1
        continue
    fi
    if mount -o bind "$SRC_MNT" "$real" 2>/dev/null; then
        log_i "bind-mounted tmpfs -> $real"
        BIND_OK=1
    else
        log_i "bind mount failed: $real"
    fi
done
if [ "$BIND_OK" -ne 1 ]; then
    umount "$SRC_MNT" 2>/dev/null
    log_i "ABORT: no target could be mounted - cleaned up"
    log_i "finished"
    exit 0
fi

# --- 8g. propagate into the zygote mount namespaces -------------------
# Processes started before this script (existing zygotes) have their own
# frozen mount namespaces; without nsenter they would keep seeing the
# old store until reboot.
if command -v nsenter >/dev/null 2>&1; then
    for pid in 1 $(pgrep zygote 2>/dev/null) $(pgrep zygote64 2>/dev/null); do
        [ -d "/proc/$pid/ns/mnt" ] || continue
        for p in $PAIRS; do
            pair_of "$p"
            [ -d "$real" ] || continue
            nsenter --mount="/proc/$pid/ns/mnt" -- mount -o bind "$SRC_MNT" "$real" 2>/dev/null
        done
    done
    log_i "bind propagated to zygote namespaces"
else
    log_i "note: nsenter unavailable - running processes may need a restart"
fi

# --- 8h. lock read-only (stock semantic) ------------------------------
for p in $PAIRS; do
    pair_of "$p"
    [ -d "$real" ] || continue
    if mount -o remount,ro,bind "$real" 2>/dev/null; then
        log_i "remounted read-only: $real"
    else
        log_i "warning: could not remount $real read-only"
    fi
done

log_i "finished"
