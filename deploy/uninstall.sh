#!/bin/sh
# ---------------------------------------------------------------------------
# uninstall.sh - idempotent rollback of tc-webshare from AirPort Time Capsule.
#
#   ./deploy/uninstall.sh              # keep /Volumes/dk2/share/web data
#   ./deploy/uninstall.sh --purge-data # also remove user uploads (destructive)
#
# Guarantees:
#   * boot.sh: only the lines between the two marker lines are removed;
#     every other line is preserved byte-for-byte and sha256-verified.
#   * Only /Volumes/dk2/.tc_webshare is removed by default.
#   * tc-toolbox and Samba are never modified.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

ROOT_DIR=${TC_ROOT_DIR-/Volumes/dk2}
WEB_ROOT=${TC_WEB_ROOT-${ROOT_DIR}/.tc_webshare}
SHARE_DIR=${TC_SHARE_DIR-${ROOT_DIR}/share/web}
BOOT_SH=${TC_BOOT_SH-/mnt/Flash/boot.sh}
MANIFEST=${WEB_ROOT}/state/manifest
PIDFILE=${WEB_ROOT}/state/thttpd.pid

MARK_BEGIN='# >>> TC_WEBSHARE BEGIN >>>'
MARK_END='# <<< TC_WEBSHARE END <<<'
PURGE_DATA=0

PATH=${ROOT_DIR}/.tc_tools/bin:${PATH}
export PATH

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Unified destructive-path guard (V5.4), identical to deploy/install.sh.
# Reject empty, relative, /, HOME, protected system roots and shallow paths.
# /Volumes/* must be under /Volumes/dk2; absolute rehearsal overrides such
# as TC_SHARE_DIR=/tmp/stub/share/web remain valid.
guard_path() {
    guard_label=$1
    guard_target=$2
    case "${guard_target}" in
        '') die "${guard_label} is an empty path; refusing to continue" ;;
        /*) ;;
        *) die "${guard_label} must be an absolute path: ${guard_target}" ;;
    esac
    guard_norm=$(printf '%s\n' "${guard_target}" | sed 's|/*$||')
    [ -n "${guard_norm}" ] || die "${guard_label} resolves to an empty path"
    [ "${guard_norm}" != "/" ] || die "${guard_label} may not be /"
    if [ -n "${HOME:-}" ] && [ "${guard_norm}" = "${HOME}" ]; then
        die "${guard_label} may not be HOME (${HOME})"
    fi
    case "${guard_norm}" in
        /Volumes|/Volumes/|/tmp|/private/tmp|/etc|/usr|/bin|/sbin|/var|/Library|/System)
            die "${guard_label} is a protected system path: ${guard_norm}" ;;
    esac
    case "${guard_norm}" in
        /Volumes/*)
            case "${guard_norm}" in
                /Volumes/dk2|/Volumes/dk2/*) ;;
                *) die "${guard_label} must be under /Volumes/dk2: ${guard_norm}" ;;
            esac
            ;;
    esac
    guard_depth=$(printf '%s\n' "${guard_norm}" | tr -cd '/' | wc -c | tr -d ' ')
    [ "${guard_depth}" -ge 2 ] || die "${guard_label} is too shallow: ${guard_norm}"
    return 0
}

case "${1:-}" in
    "") ;;
    --purge-data) PURGE_DATA=1 ;;
    -h|--help)
        say "usage: $0 [--purge-data]"
        exit 0
        ;;
    *) die "unknown argument: $1 (usage: $0 [--purge-data])" ;;
esac

# Validate every path BEFORE any stop/delete action, including --purge-data.
guard_path ROOT_DIR "${ROOT_DIR}"
guard_path WEB_ROOT "${WEB_ROOT}"
guard_path SHARE_DIR "${SHARE_DIR}"
[ "${WEB_ROOT}" != "${ROOT_DIR}" ] || die "WEB_ROOT must differ from ROOT_DIR"
[ "${SHARE_DIR}" != "${ROOT_DIR}" ] || die "SHARE_DIR must differ from ROOT_DIR"
[ "${WEB_ROOT}" != "${SHARE_DIR}" ] || die "WEB_ROOT must differ from SHARE_DIR"
if [ "${PURGE_DATA}" -eq 1 ]; then
    guard_path "SHARE_DIR (--purge-data)" "${SHARE_DIR}"
fi

port_listening() {
    check_port=$1
    if command -v netstat >/dev/null 2>&1; then
        if netstat -an 2>/dev/null | awk -v p="${check_port}" '
                $0 ~ /LISTEN/ && $4 ~ ("[.]" p "$") { found = 1 }
                END { exit(found ? 0 : 1) }'; then
            return 0
        fi
    fi
    if command -v nc >/dev/null 2>&1; then
        if nc -z 127.0.0.1 "${check_port}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

sha_of_file() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

nonweb_sha() {
    awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0; next }
        !inside { print }
    ' "$1" | sha256sum | awk '{print $1}'
}

manifest_value() {
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${MANIFEST}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 0. Already clean?
# ---------------------------------------------------------------------------
HAS_MARK=0
if [ -f "${BOOT_SH}" ]; then
    if grep -F -q -- "${MARK_BEGIN}" "${BOOT_SH}" || grep -F -q -- "${MARK_END}" "${BOOT_SH}"; then
        HAS_MARK=1
    fi
fi
if [ ! -d "${WEB_ROOT}" ] && [ "${HAS_MARK}" -eq 0 ]; then
    say "already clean: no ${WEB_ROOT} and no tc-webshare marker in boot.sh"
    if port_listening 8080; then
        say "WARN: something is still listening on 8080 (not managed by this package)"
    fi
    say "ROLLBACK OK (no changes needed)"
    exit 0
fi

[ -f "${BOOT_SH}" ] || die "boot.sh missing: ${BOOT_SH}"
[ -d "${ROOT_DIR}" ] || die "${ROOT_DIR} missing"

command -v sha256sum >/dev/null 2>&1 || die "sha256sum not available in tc-toolbox"

EXPECTED_NONWEB=""
RECORDED_TOOL_COUNT=""
if [ -f "${MANIFEST}" ]; then
    EXPECTED_NONWEB=$(manifest_value boot_sha_nonweb_after)
    [ -n "${EXPECTED_NONWEB}" ] || EXPECTED_NONWEB=$(manifest_value boot_sha_nonweb_before)
    RECORDED_TOOL_COUNT=$(manifest_value toolbox_count)
fi

# ---------------------------------------------------------------------------
# 1. Stop the service
# ---------------------------------------------------------------------------
say "=== stopping thttpd ==="
if [ -f "${PIDFILE}" ]; then
    stored_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
    case "${stored_pid}" in
        ''|*[!0-9]*) say "WARN: pidfile contains no usable PID; skipping kill" ;;
        *)
            if kill -0 "${stored_pid}" 2>/dev/null; then
                kill "${stored_pid}" 2>/dev/null || true
                i=0
                while [ "${i}" -lt 10 ] && kill -0 "${stored_pid}" 2>/dev/null; do
                    i=$((i + 1))
                    sleep 1
                done
                if kill -0 "${stored_pid}" 2>/dev/null; then
                    die "PID ${stored_pid} did not stop; resolve manually"
                fi
                say "stopped PID ${stored_pid}"
            else
                say "stored PID ${stored_pid} is not running; nothing to kill"
            fi
            ;;
    esac
else
    say "no pidfile found; checking port 8080"
fi
if port_listening 8080; then
    die "port 8080 is still listening; identify and stop the process before rollback"
fi
say "port 8080 closed"

# ---------------------------------------------------------------------------
# 2. Remove only the managed block from boot.sh (sed -i "" = NetBSD syntax)
# ---------------------------------------------------------------------------
if [ "${HAS_MARK}" -eq 1 ]; then
    begin_count=$(grep -F -c -- "${MARK_BEGIN}" "${BOOT_SH}" || true)
    end_count=$(grep -F -c -- "${MARK_END}" "${BOOT_SH}" || true)
    if [ "${begin_count}" != "1" ] || [ "${end_count}" != "1" ]; then
        die "boot.sh must contain exactly one BEGIN and one END marker (got ${begin_count}/${end_count}); refusing to edit"
    fi

    TMP_BOOT=${WEB_ROOT}/state/boot.uninstall.$$
    mkdir -p "${WEB_ROOT}/state"
    cp -p "${BOOT_SH}" "${TMP_BOOT}" || die "cannot copy boot.sh"
    # Range delete is inclusive; markers contain no sed BRE metacharacters.
    sed -i "" "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "${TMP_BOOT}" || die "sed failed"
    chmod u+w "${BOOT_SH}" || die "chmod u+w ${BOOT_SH} failed"
    cat "${TMP_BOOT}" > "${BOOT_SH}" || die "failed to restore boot.sh"
    chmod u-w "${BOOT_SH}" || die "chmod u-w ${BOOT_SH} failed"
    rm -f "${TMP_BOOT}"
    say "managed block removed from boot.sh"
else
    say "no marker block in boot.sh; skipping edit"
fi

if grep -F -q -- "${MARK_BEGIN}" "${BOOT_SH}" || grep -F -q -- "${MARK_END}" "${BOOT_SH}"; then
    die "marker lines still present in boot.sh after cleanup"
fi

AFTER_NONWEB=$(nonweb_sha "${BOOT_SH}" || true)
[ -n "${AFTER_NONWEB}" ] || die "cannot compute boot.sh checksum after cleanup"
if [ -n "${EXPECTED_NONWEB}" ] && [ "${AFTER_NONWEB}" != "${EXPECTED_NONWEB}" ]; then
    die "boot.sh non-Web checksum mismatch: expected ${EXPECTED_NONWEB}, got ${AFTER_NONWEB}"
fi
say "boot.sh non-Web sha256: ${AFTER_NONWEB} (matches manifest or no manifest present)"

# ---------------------------------------------------------------------------
# 3. Remove managed files, keep user data unless explicitly purged
# ---------------------------------------------------------------------------
say "=== removing managed artifacts ==="
if [ -e "${SHARE_DIR}/.htpasswd" ] || [ -L "${SHARE_DIR}/.htpasswd" ]; then
    rm -f "${SHARE_DIR}/.htpasswd"
fi
if [ -f "${SHARE_DIR}/cgi-bin/.tc-webshare-link" ]; then
    rm -f "${SHARE_DIR}/cgi-bin/.tc-webshare-link"
    rm -f "${SHARE_DIR}/cgi-bin/upload.cgi"
    rmdir "${SHARE_DIR}/cgi-bin" 2>/dev/null || true
fi
rm -rf "${WEB_ROOT}"
say "removed ${WEB_ROOT}"

if [ "${PURGE_DATA}" -eq 1 ]; then
    say "WARNING: --purge-data supplied; deleting ${SHARE_DIR}"
    rm -rf "${SHARE_DIR}"
else
    say "user data preserved: ${SHARE_DIR}"
fi

# ---------------------------------------------------------------------------
# 4. Post-rollback verification
# ---------------------------------------------------------------------------
say "=== rollback verification ==="
if port_listening 8080; then
    die "verification failed: port 8080 is listening"
fi
say "OK: 8080 closed"
port_listening 139 || die "verification failed: Samba port 139 is not listening"
port_listening 445 || die "verification failed: Samba port 445 is not listening"
say "OK: Samba ports 139/445 still listening"

[ -d "${ROOT_DIR}/.tc_tools/bin" ] || die "verification failed: tc-toolbox is missing"
tool_count=$(find "${ROOT_DIR}/.tc_tools/bin" -type f | wc -l | tr -d ' ')
[ "${tool_count}" -ge 50 ] || die "verification failed: only ${tool_count} tc-toolbox files remain"
if [ -n "${RECORDED_TOOL_COUNT}" ] && [ "${RECORDED_TOOL_COUNT}" != "${tool_count}" ]; then
    say "WARN: toolbox file count changed from ${RECORDED_TOOL_COUNT} to ${tool_count} (not modified by this script)"
fi
say "OK: tc-toolbox present (${tool_count} files)"

[ -d "${ROOT_DIR}/.samba4" ] || die "verification failed: .samba4 directory is missing"
[ -r "${ROOT_DIR}" ] && [ -x "${ROOT_DIR}" ] || die "verification failed: Samba share root not accessible"
if command -v ls >/dev/null 2>&1; then
    ls "${ROOT_DIR}" >/dev/null 2>&1 || die "verification failed: cannot list ${ROOT_DIR}"
fi
say "OK: Samba share root accessible and .samba4 intact"

say "ROLLBACK OK"
