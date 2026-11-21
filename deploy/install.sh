#!/bin/sh
# ---------------------------------------------------------------------------
# install.sh - idempotent deployment of tc-webshare onto AirPort Time Capsule.
#
# Target: NetBSD 6.0 / evbarm / earmv4, firmware 7.9.1.
# Rules:
#   * Never touch /Volumes/dk2/.tc_tools or .samba4.
#   * boot.sh gets exactly one marker block; non-Web lines are preserved.
#   * All managed artifacts live under /Volumes/dk2/.tc_webshare.
#   * User data lives under /Volumes/dk2/share/web and is never deleted here.
#
# Usage (on the device, from the copied package):
#   TC_WEB_USER=admin TC_WEB_PASSWORD='...' ./deploy/install.sh
#   TC_WEB_PASS_HASH='<crypt(3) hash>' ./deploy/install.sh   # preferred
#
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

PKG_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

ROOT_DIR=${TC_ROOT_DIR-/Volumes/dk2}
WEB_ROOT=${TC_WEB_ROOT-${ROOT_DIR}/.tc_webshare}
SHARE_DIR=${TC_SHARE_DIR-${ROOT_DIR}/share/web}
BOOT_SH=${TC_BOOT_SH-/mnt/Flash/boot.sh}
BIN_SRC=${TC_BIN_SRC-${PKG_ROOT}/build_out/bin}
CONFIG_SRC=${TC_CONFIG_SRC-${PKG_ROOT}/deploy/thttpd.conf}
HOOK_SRC=${TC_HOOK_SRC-${PKG_ROOT}/deploy/boot_hook.sh}
EXAMPLE_SRC=${TC_EXAMPLE_SRC-${PKG_ROOT}/deploy/htpasswd.example}

BIN_DIR=${WEB_ROOT}/bin
ETC_DIR=${WEB_ROOT}/etc
STATE_DIR=${WEB_ROOT}/state
PIDFILE=${STATE_DIR}/thttpd.pid
HTPASSWD=${ETC_DIR}/htpasswd
MANIFEST=${STATE_DIR}/manifest

MARK_BEGIN='# >>> TC_WEBSHARE BEGIN >>>'
MARK_END='# <<< TC_WEBSHARE END <<<'

PATH=${ROOT_DIR}/.tc_tools/bin:${PATH}
export PATH

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

# SHA-256 of boot.sh with the managed Web block filtered out.
nonweb_sha() {
    awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0; next }
        !inside { print }
    ' "$1" | sha256sum | awk '{print $1}'
}

# Unified destructive-path guard (V5.4). Reject empty, relative, /, HOME,
# protected system roots and too-shallow paths. Anything under /Volumes must
# be under /Volumes/dk2. Absolute rehearsal paths such as
# TC_SHARE_DIR=/tmp/stub/share/web remain valid when overridden.
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

# Only our own thttpd may be stopped during an in-place update.
own_pid_is_thttpd() {
    check_pid=$1
    kill -0 "${check_pid}" 2>/dev/null || return 1
    command -v ps >/dev/null 2>&1 || return 1
    proc_args=$(ps -p "${check_pid}" -o args= 2>/dev/null || true)
    [ -n "${proc_args}" ] || return 1
    case "${proc_args}" in
        *"${BIN_DIR}/thttpd"*) return 0 ;;
        *"${ETC_DIR}/thttpd.conf"*) return 0 ;;
        *".tc_webshare/bin/thttpd"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_own_service_for_update() {
    if [ -f "${PIDFILE}" ]; then
        stored_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
        case "${stored_pid}" in
            ''|*[!0-9]*) die "pidfile ${PIDFILE} has no valid PID; refusing to kill an unknown process" ;;
        esac
        if kill -0 "${stored_pid}" 2>/dev/null; then
            if ! own_pid_is_thttpd "${stored_pid}"; then
                die "PID ${stored_pid} in pidfile is not our thttpd; refusing to kill it"
            fi
            kill "${stored_pid}" 2>/dev/null || die "cannot stop our thttpd (PID ${stored_pid})"
            i=0
            while [ "${i}" -lt 10 ] && kill -0 "${stored_pid}" 2>/dev/null; do
                i=$((i + 1))
                sleep 1
            done
            if kill -0 "${stored_pid}" 2>/dev/null; then
                die "our thttpd (PID ${stored_pid}) did not stop; refusing to overwrite binaries"
            fi
            say "update mode: stopped our thttpd (PID ${stored_pid})"
        else
            say "update mode: stored PID ${stored_pid} is not running"
        fi
    fi
    if port_listening 8080; then
        die "port 8080 is still in use; refusing to overwrite binaries or start a duplicate"
    fi
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
say "=== tc-webshare install: preflight ==="
guard_path ROOT_DIR "${ROOT_DIR}"
guard_path WEB_ROOT "${WEB_ROOT}"
guard_path SHARE_DIR "${SHARE_DIR}"
[ "${WEB_ROOT}" != "${ROOT_DIR}" ] || die "WEB_ROOT must differ from ROOT_DIR"
[ "${SHARE_DIR}" != "${ROOT_DIR}" ] || die "SHARE_DIR must differ from ROOT_DIR"
[ "${WEB_ROOT}" != "${SHARE_DIR}" ] || die "WEB_ROOT must differ from SHARE_DIR"

if [ "$(uname -s)" != "NetBSD" ] && [ "${TC_ALLOW_NON_NETBSD:-0}" != "1" ]; then
    die "target must be NetBSD (got $(uname -s)); TC_ALLOW_NON_NETBSD=1 is for dry-run tests only"
fi
[ -d "${ROOT_DIR}" ] || die "${ROOT_DIR} does not exist"
mount 2>/dev/null | awk -v r="${ROOT_DIR}" '$3 == r { found = 1 } END { exit(found ? 0 : 1) }' \
    || die "${ROOT_DIR} is not mounted"
[ -d "${ROOT_DIR}/.tc_tools/bin" ] || die "tc-toolbox missing; refusing to deploy"
[ -d "${ROOT_DIR}/.samba4" ] || die "Samba state dir .samba4 missing; refusing to deploy"
port_listening 139 || die "Samba port 139 is not listening; refusing to deploy"
port_listening 445 || die "Samba port 445 is not listening; refusing to deploy"
[ -f "${BOOT_SH}" ] || die "boot hook ${BOOT_SH} not found"
[ -f "${BIN_SRC}/thttpd" ] || die "missing static binary ${BIN_SRC}/thttpd"
[ -f "${BIN_SRC}/upload.cgi" ] || die "missing static binary ${BIN_SRC}/upload.cgi"
[ -f "${CONFIG_SRC}" ] || die "missing config ${CONFIG_SRC}"
[ -f "${HOOK_SRC}" ] || die "missing boot hook ${HOOK_SRC}"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not available in tc-toolbox"

# Installed-state detection MUST precede the 8080 check: a second run finds
# our own listener and must switch to in-place update mode, not abort.
MARKER_PRESENT=0
if grep -F -q -- "${MARK_BEGIN}" "${BOOT_SH}" || grep -F -q -- "${MARK_END}" "${BOOT_SH}"; then
    MARKER_PRESENT=1
fi
if [ "${MARKER_PRESENT}" -eq 1 ] && [ ! -d "${WEB_ROOT}" ]; then
    die "boot.sh marker exists but ${WEB_ROOT} is missing; repair manually before retrying"
fi
if [ "${MARKER_PRESENT}" -eq 1 ]; then
    UPDATE_MODE=1
    say "already installed: marker block present -> update mode (boot.sh will not be rewritten)"
    stop_own_service_for_update
else
    UPDATE_MODE=0
    say "state: fresh install"
    if port_listening 8080; then
        die "port 8080 is already in use; refusing to deploy"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Install artifacts
# ---------------------------------------------------------------------------
say "=== installing artifacts ==="
mkdir -p "${BIN_DIR}" "${ETC_DIR}" "${STATE_DIR}" "${SHARE_DIR}"

cp -f "${BIN_SRC}/thttpd" "${BIN_DIR}/thttpd"
cp -f "${BIN_SRC}/upload.cgi" "${BIN_DIR}/upload.cgi"
cp -f "${HOOK_SRC}" "${BIN_DIR}/boot_hook.sh"
chmod 0755 "${BIN_DIR}/thttpd" "${BIN_DIR}/upload.cgi" "${BIN_DIR}/boot_hook.sh"

cp -f "${CONFIG_SRC}" "${ETC_DIR}/thttpd.conf"
chmod 0644 "${ETC_DIR}/thttpd.conf"

# CGI endpoint: /cgi-bin/upload.cgi maps into the managed bin directory.
mkdir -p "${SHARE_DIR}/cgi-bin"
if [ -L "${SHARE_DIR}/cgi-bin" ]; then
    die "${SHARE_DIR}/cgi-bin is an unexpected symlink; resolve manually before installing"
fi
cp -f "${BIN_DIR}/upload.cgi" "${SHARE_DIR}/cgi-bin/upload.cgi"
: > "${SHARE_DIR}/cgi-bin/.tc-webshare-link"
chmod 0755 "${SHARE_DIR}/cgi-bin/upload.cgi"

# Basic auth: thttpd reads .htpasswd from the served directory.
if [ ! -f "${HTPASSWD}" ]; then
    if [ -f "${EXAMPLE_SRC}" ]; then
        cp -f "${EXAMPLE_SRC}" "${HTPASSWD}"
    else
        die "missing example credential template ${EXAMPLE_SRC}"
    fi
fi
WEB_USER=${TC_WEB_USER:-admin}
WEB_PASS_HASH=${TC_WEB_PASS_HASH:-}
WEB_PASSWORD=${TC_WEB_PASSWORD:-}
if [ -n "${WEB_PASS_HASH}" ]; then
    printf '%s:%s\n' "${WEB_USER}" "${WEB_PASS_HASH}" > "${HTPASSWD}"
elif [ -n "${WEB_PASSWORD}" ]; then
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -b -c "${HTPASSWD}" "${WEB_USER}" "${WEB_PASSWORD}"
    elif command -v openssl >/dev/null 2>&1; then
        generated_hash=$(openssl passwd -1 "${WEB_PASSWORD}")
        printf '%s:%s\n' "${WEB_USER}" "${generated_hash}" > "${HTPASSWD}"
    else
        die "no htpasswd/openssl available; use TC_WEB_PASS_HASH instead"
    fi
else
    # Generate a one-time password locally on the device and print it once.
    if command -v openssl >/dev/null 2>&1; then
        WEB_PASSWORD=$(openssl rand -hex 12)
    elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        WEB_PASSWORD=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
    else
        die "cannot generate a password; set TC_WEB_PASS_HASH explicitly"
    fi
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -b -c "${HTPASSWD}" "${WEB_USER}" "${WEB_PASSWORD}"
    elif command -v openssl >/dev/null 2>&1; then
        generated_hash=$(openssl passwd -1 "${WEB_PASSWORD}")
        printf '%s:%s\n' "${WEB_USER}" "${generated_hash}" > "${HTPASSWD}"
    else
        die "no htpasswd/openssl available; use TC_WEB_PASS_HASH instead"
    fi
    say "ONE-TIME generated password for '${WEB_USER}': ${WEB_PASSWORD}"
    say "Save it now; it is not stored anywhere else by this script."
fi
chmod 0600 "${HTPASSWD}"

if [ -L "${SHARE_DIR}/.htpasswd" ]; then
    rm -f "${SHARE_DIR}/.htpasswd"
fi
if [ ! -e "${SHARE_DIR}/.htpasswd" ]; then
    ln -s "${HTPASSWD}" "${SHARE_DIR}/.htpasswd"
fi

# ---------------------------------------------------------------------------
# 3. boot.sh marker block (only when absent)
# ---------------------------------------------------------------------------
BOOT_SHA_BEFORE_FULL=$(sha_of_file "${BOOT_SH}" || true)
BOOT_SHA_NONWEB_BEFORE=$(nonweb_sha "${BOOT_SH}" || true)
[ -n "${BOOT_SHA_NONWEB_BEFORE}" ] || die "cannot compute boot.sh non-Web checksum"

if [ "${MARKER_PRESENT}" -eq 0 ]; then
    say "=== inserting managed marker block into ${BOOT_SH} ==="
    TMP_BLOCK=${STATE_DIR}/boot.block.$$
    TMP_BOOT=${STATE_DIR}/boot.new.$$
    {
        printf '%s\n' "${MARK_BEGIN}"
        printf '%s\n' '# tc-webshare: LAN-only HTTP share; managed block, do not edit by hand.'
        printf '%s\n' 'if [ -x /Volumes/dk2/.tc_webshare/bin/boot_hook.sh ]; then'
        printf '%s\n' '    /Volumes/dk2/.tc_webshare/bin/boot_hook.sh >/dev/null 2>&1'
        printf '%s\n' 'fi'
        printf '%s\n' "${MARK_END}"
    } > "${TMP_BLOCK}"

    awk -v block_file="${TMP_BLOCK}" '
        { print }
        END {
            while ((getline line < block_file) > 0) print line
            close(block_file)
        }
    ' "${BOOT_SH}" > "${TMP_BOOT}"

    chmod u+w "${BOOT_SH}" || die "chmod u+w ${BOOT_SH} failed"
    cat "${TMP_BOOT}" > "${BOOT_SH}" || die "failed to write ${BOOT_SH}"
    chmod u-w "${BOOT_SH}" || die "chmod u-w ${BOOT_SH} failed"
    rm -f "${TMP_BOOT}" "${TMP_BLOCK}"

    grep -F -q -- "${MARK_BEGIN}" "${BOOT_SH}" || die "marker insertion failed"
    grep -F -q -- "${MARK_END}" "${BOOT_SH}" || die "marker insertion failed"
else
    say "=== marker block already present: boot.sh untouched ==="
fi

BOOT_SHA_NONWEB_AFTER=$(nonweb_sha "${BOOT_SH}" || true)
if [ "${BOOT_SHA_NONWEB_AFTER}" != "${BOOT_SHA_NONWEB_BEFORE}" ]; then
    die "boot.sh non-Web content changed (${BOOT_SHA_NONWEB_BEFORE} != ${BOOT_SHA_NONWEB_AFTER})"
fi
say "boot.sh non-Web SHA-256 unchanged: ${BOOT_SHA_NONWEB_AFTER}"

# ---------------------------------------------------------------------------
# 4. Manifest
# ---------------------------------------------------------------------------
say "=== writing manifest ==="
{
    printf '# tc-webshare manifest (generated by install.sh)\n'
    printf 'marker_begin=%s\n' "${MARK_BEGIN}"
    printf 'marker_end=%s\n' "${MARK_END}"
    printf 'install_time=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'boot_sha_full_before=%s\n' "${BOOT_SHA_BEFORE_FULL}"
    printf 'boot_sha_nonweb_before=%s\n' "${BOOT_SHA_NONWEB_BEFORE}"
    printf 'boot_sha_nonweb_after=%s\n' "${BOOT_SHA_NONWEB_AFTER}"
    printf 'toolbox_count=%s\n' "$(find "${ROOT_DIR}/.tc_tools/bin" -type f | wc -l | tr -d ' ')"
    printf 'samba_state=%s\n' "${ROOT_DIR}/.samba4"
    for managed in "${BIN_DIR}/thttpd" "${BIN_DIR}/upload.cgi" "${BIN_DIR}/boot_hook.sh" \
                   "${ETC_DIR}/thttpd.conf" "${HTPASSWD}" "${SHARE_DIR}/cgi-bin/upload.cgi"; do
        printf '%s  %s\n' "$(sha_of_file "${managed}")" "${managed}"
    done
} > "${MANIFEST}"
chmod 0644 "${MANIFEST}"

# ---------------------------------------------------------------------------
# 5. Start and verify
# ---------------------------------------------------------------------------
say "=== starting thttpd (boot hook runs only at boot time) ==="
"${BIN_DIR}/boot_hook.sh" || die "boot_hook.sh failed to start thttpd"

verified=0
i=0
while [ "${i}" -lt 20 ]; do
    if port_listening 8080; then verified=1; break; fi
    i=$((i + 1))
    sleep 1
done
[ "${verified}" -eq 1 ] || die "port 8080 did not open after start"

if command -v wget >/dev/null 2>&1; then
    probe_code=$(wget -S -O /dev/null "http://127.0.0.1:8080/" 2>&1 \
        | awk '/^[[:space:]]*HTTP\// { print $2; exit }')
elif command -v curl >/dev/null 2>&1; then
    probe_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/" 2>/dev/null || true)
else
    probe_code="SKIPPED"
fi
if [ "${probe_code}" = "SKIPPED" ]; then
    say "WARN: no HTTP client on device; GET probe skipped (port 8080 is listening)"
elif [ "${probe_code}" = "401" ]; then
    say "GET probe: 401 Unauthorized (Basic auth is enforced) - expected"
else
    die "GET probe returned '${probe_code}', expected 401; check thttpd.conf and .htpasswd"
fi

say "=== install report ==="
say "installed: ${WEB_ROOT}"
say "data dir:  ${SHARE_DIR}"
say "manifest:  ${MANIFEST}"
say "boot.sh non-Web sha256: ${BOOT_SHA_NONWEB_AFTER}"
say "thttpd:    ${BIN_DIR}/thttpd"
say "upload:    ${BIN_DIR}/upload.cgi -> /cgi-bin/upload.cgi"
say "ports:     8080=LISTEN, 139/445 still LISTEN"
if [ "${UPDATE_MODE}" -eq 1 ]; then
    say "already installed: updated in place"
else
    say "INSTALL OK"
fi
