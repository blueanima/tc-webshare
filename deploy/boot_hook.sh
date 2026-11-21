#!/bin/sh
# ---------------------------------------------------------------------------
# boot_hook.sh - idempotent bozohttpd starter invoked from /mnt/Flash/boot.sh.
#
# bozohttpd (NetBSD base httpd) is started in standalone daemon mode:
#   -b            daemonise (mandatory: without it bozohttpd expects inetd stdin)
#   -I 8080       listening port (NOT -p: that is public_html in this version)
#   -i 0.0.0.0    bind all LAN interfaces (daemon mode only)
#   -c <cgibin>   filesystem dir behind /cgi-bin/<scriptname> URLs
#   -X            directory index support
#   -H            hide dotfiles (.htpasswd) in the index
#   -P <pidfile>  write the daemon PID (daemon mode only)
#   <slashdir>    document root; bozohttpd chdir(2)s here
#
# Uses absolute paths only and the small command set checked by install.sh.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/tc_paths.sh"
. "${SCRIPT_DIR}/tc_common.sh"

HTTPD=${BIN_DIR}/httpd
PIDFILE=${STATE_DIR}/httpd.pid
HTPASSWD=${ETC_DIR}/htpasswd

# Already serving: the hook may fire more than once.
if port_listening 8080; then
    exit 0
fi

# A live PID recorded by a previous start means do not spawn a duplicate.
if [ -f "${PIDFILE}" ]; then
    stored_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
    case "${stored_pid}" in
        ''|*[!0-9]*) ;;
        *) if kill -0 "${stored_pid}" 2>/dev/null; then exit 0; fi ;;
    esac
fi

[ -x "${HTTPD}" ] || exit 1
mkdir -p "${CGI_DIR}" "${STATE_DIR}" || exit 1

# The SATA volume may have been mounted/unmounted since install.  Recreate
# the per-directory auth links so Basic auth keeps protecting every path.
SHARE_DIR_NOW=$(resolve_share_dir)
mkdir -p "${SHARE_DIR_NOW}" "${SHARE_DIR_NOW}/cgi-bin" 2>/dev/null || true
: > "${SHARE_DIR_NOW}/cgi-bin/.tc-webshare-link" 2>/dev/null || true
if [ -f "${HTPASSWD}" ]; then
    link_htpasswd "${SHARE_DIR_NOW}" "${HTPASSWD}" || true
    link_htpasswd "${SHARE_DIR_NOW}/cgi-bin" "${HTPASSWD}" || true
    link_htpasswd "${CGI_DIR}" "${HTPASSWD}" || true
fi

# -b detaches and -P makes bozohttpd write the real server PID itself, so
# there is no need to background it from the shell.
"${HTTPD}" -b -I 8080 -i 0.0.0.0 -c "${CGI_DIR}" -X -H -P "${PIDFILE}" \
    "${SHARE_DIR_NOW}" >/dev/null 2>&1 || exit 1

i=0
while [ "${i}" -lt 10 ]; do
    if port_listening 8080; then
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done

exit 1
