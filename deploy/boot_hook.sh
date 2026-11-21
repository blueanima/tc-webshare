#!/bin/sh
# ---------------------------------------------------------------------------
# boot_hook.sh - idempotent thttpd starter invoked from /mnt/Flash/boot.sh.
#
# Runs with absolute paths only; uses tools shipped in tc-toolbox where
# possible and never assumes bash, flock, or a dynamic linker.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -u

ROOT_DIR=${TC_ROOT_DIR:-/Volumes/dk2}
WEB_ROOT=${TC_WEB_ROOT:-${ROOT_DIR}/.tc_webshare}
BIN_DIR=${WEB_ROOT}/bin
ETC_DIR=${WEB_ROOT}/etc
STATE_DIR=${WEB_ROOT}/state
PIDFILE=${STATE_DIR}/thttpd.pid
THTTPD=${BIN_DIR}/thttpd
CONF=${ETC_DIR}/thttpd.conf

PATH=${ROOT_DIR}/.tc_tools/bin:${PATH}
export PATH

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

# Already serving: do nothing (boot hook may fire more than once).
if port_listening 8080; then
    exit 0
fi

# Live PID recorded by a previous start: do not spawn a duplicate.
if [ -f "${PIDFILE}" ]; then
    stored_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
    case "${stored_pid}" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "${stored_pid}" 2>/dev/null; then
                exit 0
            fi
            ;;
    esac
fi

[ -x "${THTTPD}" ] || exit 1
[ -f "${CONF}" ] || exit 1
mkdir -p "${STATE_DIR}" || exit 1

# -D keeps thttpd in the foreground so $! is the real server PID.
"${THTTPD}" -C "${CONF}" -D >/dev/null 2>&1 &
server_pid=$!
printf '%s\n' "${server_pid}" > "${PIDFILE}"

i=0
while [ "${i}" -lt 20 ]; do
    if port_listening 8080; then
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done

exit 1
