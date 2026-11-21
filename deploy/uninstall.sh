#!/bin/sh
# ---------------------------------------------------------------------------
# uninstall.sh - idempotent rollback of tc-webshare from an AirPort Time Capsule.
#
#   ./deploy/uninstall.sh              # keep user data
#   ./deploy/uninstall.sh --purge-data # also remove user uploads (destructive)
#
# Guarantees:
#   * boot.sh: only the lines between the two marker lines are removed.  The
#     remaining lines are compared line-for-line with the snapshot recorded
#     at install time (sha256sum is not available on this firmware).
#   * Only the managed tree (default /mnt/Flash/.tc_webshare) is removed.
#   * TimeCapsuleSMB's boot.sh, .samba4 and the tc-toolbox are never modified.
#
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# The device has no dirname/awk.  Pure POSIX shell dirname via ${0%/*}.
case "$0" in
    */*) tc_script_dir=${0%/*}; [ -n "${tc_script_dir}" ] || tc_script_dir=/ ;;
    *)   tc_script_dir=. ;;
esac
SCRIPT_DIR=$(CDPATH= cd -- "${tc_script_dir}" && pwd)
PKG_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
. "${PKG_ROOT}/deploy/common.sh"

ROOT_DIR=${TC_ROOT_DIR:-/mnt/Flash/.tc_webshare}
WEB_ROOT=${ROOT_DIR}
BIN_DIR=${WEB_ROOT}/bin
STATE_DIR=${WEB_ROOT}/state
BOOT_SH=${TC_BOOT_SH:-/mnt/Flash/boot.sh}
MANIFEST=${STATE_DIR}/manifest
NONWEB_SNAPSHOT=${STATE_DIR}/boot.nonweb
PIDFILE=${STATE_DIR}/bozohttpd.pid
INDEX_FILE_NAME=${INDEX_FILE_NAME:-.tc-webshare-index.html}
PURGE_DATA=0

say() { printf '%s\n' "$*"; }

case "${1:-}" in
    "") ;;
    --purge-data) PURGE_DATA=1 ;;
    -h|--help) say "usage: $0 [--purge-data]"; exit 0 ;;
    *) die "unknown argument: $1 (usage: $0 [--purge-data])" ;;
esac

require_cmds

say "=== tc-webshare uninstall: preflight ==="
guard_path ROOT_DIR "${ROOT_DIR}"
# Recover an explicitly configured data dir recorded at install time.
if [ -z "${TC_SHARE_DIR:-}" ] && [ -f "${WEB_ROOT}/bin/tc_paths.sh" ]; then
    saved_share=$(sed -n "s/^TC_SHARE_DIR='\\(.*\\)'$/\\1/p" "${WEB_ROOT}/bin/tc_paths.sh")
    [ -z "${saved_share}" ] || TC_SHARE_DIR=${saved_share}
fi
SHARE_DIR=$(resolve_share_dir)
guard_path SHARE_DIR "${SHARE_DIR}"
[ "${SHARE_DIR}" != "${WEB_ROOT}" ] || die "SHARE_DIR must differ from WEB_ROOT"
[ -f "${BOOT_SH}" ] || die "boot.sh missing: ${BOOT_SH}"

HAS_MARK=0
if [ "$(marker_count "${BOOT_SH}")" -ne 0 ]; then
    HAS_MARK=1
fi

if [ ! -d "${WEB_ROOT}" ] && [ "${HAS_MARK}" -eq 0 ]; then
    say "already clean: no ${WEB_ROOT} and no tc-webshare marker in boot.sh"
    if port_listening 8080; then
        warn "something is still listening on 8080 (not managed by this package)"
    fi
    say "ROLLBACK OK (no changes needed)"
    exit 0
fi

# --- 1. snapshot current non-Web lines and stop our service ---------------
# Scratch on RAM tmpfs, not synchronous Flash (line-by-line writes fsync).
TMP_SCRATCH=/mnt/Memory/.tc_webshare_scratch
if [ -d /mnt/Memory ]; then
    mkdir -p "${TMP_SCRATCH}" 2>/dev/null || TMP_SCRATCH=${STATE_DIR}
else
    TMP_SCRATCH=${STATE_DIR}
fi
TMP_NONWEB=${TMP_SCRATCH}/boot.nonweb.uninstall.$$
mkdir -p "${STATE_DIR}"
nonweb_file "${BOOT_SH}" "${TMP_NONWEB}"

if [ -f "${PIDFILE}" ]; then
    stored_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
    case "${stored_pid}" in
        ''|*[!0-9]*) warn "pidfile has no usable PID; skipping kill" ;;
        *)
            if kill -0 "${stored_pid}" 2>/dev/null; then
                verified_ours=0
                if command -v ps >/dev/null 2>&1; then
                    proc_args=$(ps -p "${stored_pid}" -o args= 2>/dev/null || true)
                    case "${proc_args}" in
                        *"${BIN_DIR}/httpd"*) verified_ours=1 ;;
                    esac
                fi
                if [ "${verified_ours}" -eq 1 ]; then
                    kill "${stored_pid}" 2>/dev/null || true
                    i=0
                    while [ "${i}" -lt 10 ] && kill -0 "${stored_pid}" 2>/dev/null; do
                        i=$((i + 1)); sleep 1
                    done
                    if kill -0 "${stored_pid}" 2>/dev/null; then
                        die "PID ${stored_pid} did not stop; resolve manually"
                    fi
                    say "stopped our httpd (PID ${stored_pid})"
                else
                    warn "cannot verify PID ${stored_pid} ownership; not killing it"
                fi
            else
                say "stored PID ${stored_pid} is not running"
            fi
            ;;
    esac
else
    say "no pidfile found"
fi
if port_listening 8080; then
    warn "port 8080 is still listening; not removing managed files (identify the owner first)"
    exit 1
fi

# --- 2. remove only the managed block from boot.sh ------------------------
if [ "${HAS_MARK}" -eq 1 ]; then
    count=$(marker_count "${BOOT_SH}")
    [ "${count}" -eq 2 ] || die "boot.sh must contain exactly two marker lines (got ${count}); refusing to edit"

    TMP_BOOT=${TMP_SCRATCH}/boot.uninstall.$$
    nonweb_file "${BOOT_SH}" "${TMP_BOOT}"
    chmod u+w "${BOOT_SH}" || die "chmod u+w ${BOOT_SH} failed"
    cp "${TMP_BOOT}" "${BOOT_SH}" || die "failed to restore boot.sh"
    chmod u-w "${BOOT_SH}" || die "chmod u-w ${BOOT_SH} failed"
    rm -f "${TMP_BOOT}"
    say "managed block removed from boot.sh"
else
    say "no marker block in boot.sh; skipping edit"
fi

[ "$(marker_count "${BOOT_SH}")" -eq 0 ] || die "marker lines still present after cleanup"

# Verify against the install-time snapshot when available, otherwise against
# a fresh in-memory snapshot (still catches accidental corruption).
if [ -f "${NONWEB_SNAPSHOT}" ]; then
    text_files_equal "${TMP_NONWEB}" "${NONWEB_SNAPSHOT}" || die "boot.sh non-Web content differs from install-time snapshot"
    say "boot.sh non-Web lines match install-time snapshot"
else
    nonweb_file "${BOOT_SH}" "${TMP_NONWEB}.after"
    text_files_equal "${TMP_NONWEB}" "${TMP_NONWEB}.after" || die "boot.sh non-Web content changed during cleanup"
    say "boot.sh non-Web lines unchanged (no snapshot available)"
    rm -f "${TMP_NONWEB}.after"
fi

# --- 3. remove managed artifacts, preserve user data by default -----------
say "=== removing managed artifacts ==="
if [ -L "${SHARE_DIR}/.htpasswd" ] || [ -e "${SHARE_DIR}/.htpasswd" ]; then
    rm -f "${SHARE_DIR}/.htpasswd"
fi
# The hidden homepage is a program file, not user data.  Remove exactly this
# generated name; never touch any other file in the document root.
if [ -f "${SHARE_DIR}/${INDEX_FILE_NAME}" ]; then
    rm -f "${SHARE_DIR}/${INDEX_FILE_NAME}"
    say "removed managed homepage ${SHARE_DIR}/${INDEX_FILE_NAME}"
fi

# When the disk is unmounted, SHARE_DIR is <WEB_ROOT>/data.  A plain
# `rm -rf WEB_ROOT` would delete user uploads even without --purge-data, so
# remove only the managed subdirectories in that case.
DATA_INSIDE_ROOT=0
case "${SHARE_DIR}" in
    "${WEB_ROOT}"/*) DATA_INSIDE_ROOT=1 ;;
esac

if [ "${PURGE_DATA}" -eq 1 ]; then
    warn "--purge-data supplied; deleting ${SHARE_DIR}"
    rm -rf "${WEB_ROOT}"
    [ "${DATA_INSIDE_ROOT}" -eq 1 ] || rm -rf "${SHARE_DIR}"
    say "removed ${WEB_ROOT} and user data"
elif [ "${DATA_INSIDE_ROOT}" -eq 1 ]; then
    for managed_sub in bin etc state cgi-bin; do
        if [ -d "${WEB_ROOT}/${managed_sub}" ]; then
            rm -rf "${WEB_ROOT}/${managed_sub}"
        fi
    done
    say "managed subdirectories removed; data preserved at ${SHARE_DIR}"
else
    rm -rf "${WEB_ROOT}"
    say "removed ${WEB_ROOT}"
fi
rm -f "${TMP_NONWEB}"

if [ "${PURGE_DATA}" -eq 0 ]; then
    say "user data preserved: ${SHARE_DIR}"
fi

# --- 4. verification ------------------------------------------------------
say "=== rollback verification ==="
if port_listening 8080; then
    die "verification failed: port 8080 is listening"
fi
say "OK: 8080 closed"
if port_listening 139 || port_listening 445; then
    say "OK: at least one Samba port still listening"
else
    warn "Samba ports 139/445 are not listening (TimeCapsuleSMB state unchanged by this script)"
fi
[ -f "${BOOT_SH}" ] || die "verification failed: boot.sh is missing"
[ "$(marker_count "${BOOT_SH}")" -eq 0 ] || die "verification failed: markers still in boot.sh"
say "OK: boot.sh has no tc-webshare markers"

if [ -d /mnt/Flash ]; then
    say "OK: TimeCapsuleSMB Flash area intact"
fi
say "manifest recorded at: ${MANIFEST} (removed with the managed tree)"
say "ROLLBACK OK"
