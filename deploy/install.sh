#!/bin/sh
# ---------------------------------------------------------------------------
# install.sh - idempotent deployment of tc-webshare (bozohttpd) onto an
# AirPort Time Capsule, firmware 7.9.1 / NetBSD 6.0 evbarm earmv4.
#
# v1.0.1 device facts honoured here:
#   * /mnt/Flash (2.7 MB) holds our binaries/config; it is the only small,
#     persistent filesystem we may EXECUTE from.
#   * the SATA disk is mounted on demand as /Volumes/dkN (N CHANGES per boot),
#     unmounts when idle, and binaries may NOT be run from it.  We only put
#     user DATA there when it is currently mounted; otherwise data falls
#     back to <managed root>/data on Flash (small, documented in README).
#   /mnt/Flash/boot.sh belongs to TimeCapsuleSMB.  We insert exactly one
#   marker block before its final `exec /mnt/Flash/service manager` line and
#   never rewrite any non-Web line.  Samba may be stopped: warn, do not abort.
#
# Usage (on the device, from the copied package):
#   TC_WEB_PASS_HASH='<crypt(3) hash>' ./deploy/install.sh
#   TC_ROOT_DIR=/mnt/Flash/.my_share TC_SHARE_DIR=/mnt/Flash/.my_share/data ./deploy/install.sh
#
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

PKG_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${PKG_ROOT}/deploy/common.sh"

# --- configurable paths ---------------------------------------------------
ROOT_DIR=${TC_ROOT_DIR:-/mnt/Flash/.tc_webshare}
WEB_ROOT=${ROOT_DIR}
BIN_DIR=${WEB_ROOT}/bin
ETC_DIR=${WEB_ROOT}/etc
STATE_DIR=${WEB_ROOT}/state
BOOT_SH=${TC_BOOT_SH:-/mnt/Flash/boot.sh}

BIN_SRC=${TC_BIN_SRC:-${PKG_ROOT}/build_out/stage/bin}
EXAMPLE_SRC=${TC_EXAMPLE_SRC:-${PKG_ROOT}/deploy/htpasswd.example}

PIDFILE=${STATE_DIR}/bozohttpd.pid
HTPASSWD=${ETC_DIR}/htpasswd
MANIFEST=${STATE_DIR}/manifest
NONWEB_SNAPSHOT=${STATE_DIR}/boot.nonweb

HTTPD=${BIN_DIR}/httpd
UPLOAD_BIN=${BIN_DIR}/upload.bin
UPLOAD_SHIM=${BIN_DIR}/upload_shim
BOOT_HOOK=${BIN_DIR}/boot_hook.sh

require_cmds

say "=== tc-webshare install: preflight ==="
guard_path ROOT_DIR "${ROOT_DIR}"
[ -f "${BOOT_SH}" ] || die "boot hook ${BOOT_SH} not found"
[ -f "${BIN_SRC}/httpd" ] || die "missing static binary ${BIN_SRC}/httpd"
[ -f "${BIN_SRC}/upload.cgi" ] || die "missing static binary ${BIN_SRC}/upload.cgi"
[ -f "${PKG_ROOT}/deploy/boot_hook.sh" ] || die "missing boot hook source"
[ -f "${PKG_ROOT}/deploy/common.sh" ] || die "missing common helper source"

# Flash is tight (2.7 MB total).  Abort early if there is not enough room
# for httpd + upload.cgi + config instead of failing halfway through.
if [ -d /mnt/Flash ]; then
    flash_avail=$(df_avail_kb /mnt/Flash 2>/dev/null || true)
    if [ -n "${flash_avail}" ]; then
        [ "${flash_avail}" -ge 1024 ] || die "only ${flash_avail} KiB free on /mnt/Flash; need >= 1024 KiB for the static binaries"
        say "/mnt/Flash free: ${flash_avail} KiB"
    else
        warn "cannot determine /mnt/Flash free space (df -k unavailable?)"
    fi
fi

# Actively ask Apple's diskd to mount the internal disk (never format it).
DATA_VOLUME_OVERRIDE=$(mount_data_volume 2>/dev/null || true)
if [ -n "${DATA_VOLUME_OVERRIDE}" ]; then
    say "data volume:  ${DATA_VOLUME_OVERRIDE} (mounted, persistent)"
else
    warn "could not mount ${DATA_VOLUMES}; data dir will be volatile tmpfs"
fi

SHARE_DIR=$(resolve_share_dir)
guard_path SHARE_DIR "${SHARE_DIR}"
[ "${SHARE_DIR}" != "${WEB_ROOT}" ] || die "SHARE_DIR must differ from WEB_ROOT"
say "managed root: ${WEB_ROOT}"
say "data dir:     ${SHARE_DIR}"

# Credentials: the device has neither htpasswd nor openssl.  Require a
# pre-computed crypt(3) hash; never generate or read a plaintext password.
if port_listening 8080; then
    if [ ! -d "${WEB_ROOT}" ]; then
        die "port 8080 is already in use; refusing to deploy"
    fi
    say "WARN: port 8080 is already listening while ${WEB_ROOT} exists; checking update mode"
fi

MARKER_PRESENT=0
if [ "$(marker_count "${BOOT_SH}")" -ne 0 ]; then
    MARKER_PRESENT=1
fi
if [ "${MARKER_PRESENT}" -eq 1 ] && [ ! -d "${WEB_ROOT}" ]; then
    die "boot.sh marker exists but ${WEB_ROOT} is missing; repair manually before retrying"
fi
if [ "${MARKER_PRESENT}" -eq 1 ]; then
    UPDATE_MODE=1
    say "state: already installed -> update mode (boot.sh will not be rewritten)"
else
    UPDATE_MODE=0
    say "state: fresh install"
fi

if [ -n "${TC_WEB_PASS_HASH:-}" ]; then
    WEB_PASS_HASH=${TC_WEB_PASS_HASH}
elif [ -f "${HTPASSWD}" ]; then
    say "reusing existing htpasswd (set TC_WEB_PASS_HASH to rotate it)"
    WEB_PASS_HASH=''
else
    die "TC_WEB_PASS_HASH is required (crypt(3) hash); the device has no htpasswd/openssl"
fi
WEB_USER=${TC_WEB_USER:-admin}

# Samba is owned by TimeCapsuleSMB and is often stopped on this firmware.
if port_listening 139 || port_listening 445; then
    say "Samba: at least one SMB port is listening (left untouched)"
else
    warn "Samba ports 139/445 are not listening; TimeCapsuleSMB appears inactive. Deploying anyway."
fi

# --- 1. stop our own service for in-place updates ------------------------
if [ "${UPDATE_MODE}" -eq 1 ] && [ -f "${PIDFILE}" ]; then
    stored_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
    case "${stored_pid}" in
        ''|*[!0-9]*) die "pidfile ${PIDFILE} has no valid PID; refusing to kill an unknown process" ;;
    esac
    if kill -0 "${stored_pid}" 2>/dev/null; then
        verified_ours=0
        if command -v ps >/dev/null 2>&1; then
            proc_args=$(ps -p "${stored_pid}" -o args= 2>/dev/null || true)
            case "${proc_args}" in
                *"${HTTPD}"*) verified_ours=1 ;;
            esac
        fi
        if [ "${verified_ours}" -eq 0 ]; then
            warn "cannot verify PID ${stored_pid} ownership (no ps / no match); NOT killing it"
            die "stop PID ${stored_pid} manually, then re-run install to overwrite binaries"
        fi
        kill "${stored_pid}" || die "cannot stop our httpd (PID ${stored_pid})"
        i=0
        while [ "${i}" -lt 10 ] && kill -0 "${stored_pid}" 2>/dev/null; do
            i=$((i + 1))
            sleep 1
        done
        if kill -0 "${stored_pid}" 2>/dev/null; then
            die "our httpd (PID ${stored_pid}) did not stop; refusing to overwrite binaries"
        fi
        say "update mode: stopped our httpd (PID ${stored_pid})"
    else
        say "update mode: stored PID ${stored_pid} is not running"
    fi
fi

# --- 2. snapshot non-Web boot.sh lines BEFORE any change ------------------
TMP_NONWEB=${STATE_DIR}/boot.nonweb.new.$$
TMP_BLOCK=${STATE_DIR}/boot.block.$$
TMP_BOOT=${STATE_DIR}/boot.new.$$
mkdir -p "${STATE_DIR}"

nonweb_file "${BOOT_SH}" "${TMP_NONWEB}"
[ -s "${TMP_NONWEB}" ] || die "cannot compute non-Web boot.sh content"

# --- 3. install artifacts -------------------------------------------------
say "=== installing artifacts ==="
mkdir -p "${BIN_DIR}" "${ETC_DIR}" "${STATE_DIR}" "${SHARE_DIR}"

cp -f "${BIN_SRC}/httpd" "${HTTPD}" || die "cannot install ${HTTPD}"
cp -f "${BIN_SRC}/upload.cgi" "${UPLOAD_BIN}" || die "cannot install ${UPLOAD_BIN}"
chmod 0755 "${HTTPD}" "${UPLOAD_BIN}"

cp -f "${PKG_ROOT}/deploy/boot_hook.sh" "${BOOT_HOOK}" || die "cannot install boot hook"
cp -f "${PKG_ROOT}/deploy/common.sh" "${BIN_DIR}/tc_common.sh" || die "cannot install common helpers"
chmod 0755 "${BOOT_HOOK}"
chmod 0644 "${BIN_DIR}/tc_common.sh"

# Paths file: source this before tc_common.sh.  Values are absolute and
# deliberately baked in; the DATA dir is still resolved dynamically.
{
    printf "# generated by tc-webshare install.sh - do not edit by hand\n"
    printf "ROOT_DIR='%s'\n" "${WEB_ROOT}"
    printf "BIN_DIR='%s'\n" "${BIN_DIR}"
    printf "ETC_DIR='%s'\n" "${ETC_DIR}"
    printf "STATE_DIR='%s'\n" "${STATE_DIR}"
    if [ -n "${TC_SHARE_DIR:-}" ]; then
        printf "TC_SHARE_DIR='%s'\n" "${TC_SHARE_DIR}"
    fi
} > "${BIN_DIR}/tc_paths.sh"
chmod 0644 "${BIN_DIR}/tc_paths.sh"

# bozohttpd rebuilds the CGI environment from scratch and drops custom
# variables.  It is started with "-C .cgi <this shim>", so the URL
# /upload.cgi maps here and the shim re-supplies TC_SHARE_DIR / TC_STATE_DIR
# before exec'ing the static upload.bin.  Keeping the handler in managed
# BIN_DIR (Flash) means the unmountable disk never has to execute anything.
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# tc-webshare generated CGI shim (bozohttpd clears the environment).'
    printf ". '%s'\n" "${BIN_DIR}/tc_paths.sh"
    printf ". '%s'\n" "${BIN_DIR}/tc_common.sh"
    printf "TC_SHARE_DIR=\$(resolve_share_dir) TC_STATE_DIR='%s' exec '%s'\n" \
        "${STATE_DIR}" "${UPLOAD_BIN}"
} > "${UPLOAD_SHIM}"
chmod 0755 "${UPLOAD_SHIM}"

# Credentials and Basic auth.  With "-C .cgi" the request /upload.cgi is
# checked against the DOCROOT's .htpasswd (same directory, no recursion
# issue), so exactly one link is needed.
if [ -n "${WEB_PASS_HASH}" ]; then
    printf '%s:%s\n' "${WEB_USER}" "${WEB_PASS_HASH}" > "${HTPASSWD}"
elif [ ! -f "${HTPASSWD}" ]; then
    [ -f "${EXAMPLE_SRC}" ] || die "missing credential template ${EXAMPLE_SRC}"
    cp -f "${EXAMPLE_SRC}" "${HTPASSWD}"
fi
chmod 0600 "${HTPASSWD}"

# Single Basic-auth link in the document root protects both GET / and
# POST /upload.cgi (the -C mapped handler).
link_htpasswd "${SHARE_DIR}" "${HTPASSWD}" || die "cannot link .htpasswd into ${SHARE_DIR}"

# --- 4. boot.sh marker block (before the native-manager exec) -------------
if [ "${MARKER_PRESENT}" -eq 0 ]; then
    say "=== inserting managed marker block into ${BOOT_SH} ==="
    # boot.sh runs with `set -eu`; the whole block must be `|| true` wrapped
    # or a non-zero from our hook would prevent Samba manager from starting.
    {
        printf '%s\n' "${MARK_BEGIN}"
        printf '%s\n' '# tc-webshare: LAN-only HTTP share; managed block, do not edit by hand.'
        printf '%s\n' '# Must stay BEFORE "boot: starting native manager" / the final exec.'
        printf '%s\n' '{'
        printf 'if [ -x %s ]; then\n' "${BOOT_HOOK}"
        printf '    %s >/dev/null 2>&1 || true\n' "${BOOT_HOOK}"
        printf '%s\n' 'fi'
        printf '%s\n' '} || true'
        printf '%s\n' "${MARK_END}"
    } > "${TMP_BLOCK}"

    insert_marker_block "${BOOT_SH}" "${TMP_BLOCK}" "${TMP_BOOT}"
    chmod u+w "${BOOT_SH}" || die "chmod u+w ${BOOT_SH} failed"
    cp "${TMP_BOOT}" "${BOOT_SH}" || die "failed to write ${BOOT_SH}"
    chmod u-w "${BOOT_SH}" || die "chmod u-w ${BOOT_SH} failed"

    [ "$(marker_count "${BOOT_SH}")" -eq 2 ] || die "marker insertion failed (expected exactly two marker lines)"
fi

# The non-Web portion must be byte-for-byte (line-for-line) unchanged.
nonweb_file "${BOOT_SH}" "${TMP_NONWEB}.after"
text_files_equal "${TMP_NONWEB}" "${TMP_NONWEB}.after" || die "boot.sh non-Web content changed; aborting"
say "boot.sh non-Web lines unchanged"

cp "${TMP_NONWEB}" "${NONWEB_SNAPSHOT}"
chmod 0644 "${NONWEB_SNAPSHOT}"
rm -f "${TMP_NONWEB}" "${TMP_NONWEB}.after" "${TMP_BLOCK}" "${TMP_BOOT}"

# --- 5. manifest ----------------------------------------------------------
say "=== writing manifest ==="
{
    printf '# tc-webshare manifest (generated by install.sh)\n'
    printf 'server=bozohttpd\n'
    printf 'marker_begin=%s\n' "${MARK_BEGIN}"
    printf 'marker_end=%s\n' "${MARK_END}"
    printf 'root_dir=%s\n' "${WEB_ROOT}"
    printf 'share_dir_resolved=%s\n' "${SHARE_DIR}"
    printf 'boot_sh=%s\n' "${BOOT_SH}"
    printf 'install_time=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
    printf 'boot_nonweb_snapshot=%s\n' "${NONWEB_SNAPSHOT}"
} > "${MANIFEST}"
chmod 0644 "${MANIFEST}"

# --- 6. start and verify --------------------------------------------------
say "=== starting bozohttpd (boot hook runs only at boot time) ==="
"${BOOT_HOOK}" || die "boot_hook.sh failed to start bozohttpd"

verified=0
i=0
while [ "${i}" -lt 10 ]; do
    if port_listening 8080; then verified=1; break; fi
    i=$((i + 1))
    sleep 1
done
[ "${verified}" -eq 1 ] || die "port 8080 did not open after start"

if command -v wget >/dev/null 2>&1; then
    say "HTTP client present; run: wget -S -O /dev/null http://127.0.0.1:8080/ (expect 401)"
elif command -v curl >/dev/null 2>&1; then
    say "HTTP client present; run: curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ (expect 401)"
else
    warn "no HTTP client on device; GET probe skipped (port 8080 is listening)"
fi

say "=== install report ==="
say "installed: ${WEB_ROOT}"
say "data dir:  ${SHARE_DIR}"
say "manifest:  ${MANIFEST}"
say "server:    ${HTTPD} (bozohttpd)"
say "upload:    ${UPLOAD_SHIM} -> /upload.cgi (-C .cgi) -> ${UPLOAD_BIN}"
say "ports:     8080=LISTEN (Samba untouched)"
if [ "${UPDATE_MODE}" -eq 1 ]; then
    say "already installed: updated in place"
else
    say "INSTALL OK"
fi
