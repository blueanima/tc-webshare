#!/bin/sh
# ---------------------------------------------------------------------------
# boot_hook.sh - idempotent bozohttpd starter invoked from /mnt/Flash/boot.sh.
#
# bozohttpd (NetBSD base httpd) is started in standalone daemon mode:
#   -b                 daemonise (mandatory; boot.sh backgrounds us too, and
#                      without -b bozohttpd expects inetd stdin)
#   -I 8080            listening port (-p is public_html, -d is debug)
#   -i 0.0.0.0         bind all LAN interfaces (daemon mode only)
#   -C .cgi <shim>     suffix .cgi -> absolute Flash-resident dispatcher;
#                      every .cgi URL is checked against DOCROOT/.htpasswd
#   -X                 directory index support (off by default)
#   -H                 hide dotfiles (.htpasswd, homepage) in the index
#   -x <name>          hidden management homepage served at "/"
#   -P <pidfile>       write the daemon PID (only valid with -b)
#   <slashdir>         document root, positional (bozohttpd chdir(2)s here)
#
# Uses absolute paths only and the small command set checked by install.sh.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -u
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# The device has no dirname/awk.  Pure POSIX shell dirname via ${0%/*}.
case "$0" in
    */*) tc_script_dir=${0%/*}; [ -n "${tc_script_dir}" ] || tc_script_dir=/ ;;
    *)   tc_script_dir=. ;;
esac
SCRIPT_DIR=$(CDPATH= cd -- "${tc_script_dir}" && pwd)
. "${SCRIPT_DIR}/tc_paths.sh"
. "${SCRIPT_DIR}/tc_common.sh"

HTTPD=${BIN_DIR}/httpd
CGI_SHIM=${BIN_DIR}/cgi_dispatch.sh
PIDFILE=${STATE_DIR}/bozohttpd.pid
HTPASSWD=${ETC_DIR}/htpasswd
INDEX_MASTER=${ETC_DIR}/index.html
INDEX_FILE_NAME=${INDEX_FILE_NAME:-.tc-webshare-index.html}

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
[ -x "${CGI_SHIM}" ] || exit 1
mkdir -p "${STATE_DIR}" || exit 1

# After a reboot the SATA disk is unmounted.  Ask Apple's diskd to mount it
# again (typed "path:s:" argument), then re-resolve the data root.  The whole
# thing is best-effort so a failed mount cannot break the Samba boot chain.
DATA_VOLUME_OVERRIDE=$(mount_data_volume 2>/dev/null || true)
SHARE_DIR_NOW=$(resolve_share_dir)
mkdir -p "${SHARE_DIR_NOW}" 2>/dev/null || true
if [ -f "${HTPASSWD}" ]; then
    link_htpasswd "${SHARE_DIR_NOW}" "${HTPASSWD}" || true
fi
# The docroot may have been remounted (or be a fresh tmpfs fallback), so
# republish the hidden management homepage from its managed Flash master.
if [ -f "${INDEX_MASTER}" ]; then
    dd if="${INDEX_MASTER}" of="${SHARE_DIR_NOW}/${INDEX_FILE_NAME}" bs=64k 2>/dev/null || true
    chmod 0644 "${SHARE_DIR_NOW}/${INDEX_FILE_NAME}" 2>/dev/null || true
fi

# -b detaches and -P makes bozohttpd write the real server PID itself, so
# there is no need to background it from the shell.
"${HTTPD}" -b -I 8080 -i 0.0.0.0 -C .cgi "${CGI_SHIM}" -X -H \
    -x "${INDEX_FILE_NAME}" -P "${PIDFILE}" "${SHARE_DIR_NOW}" >/dev/null 2>&1 || exit 1

i=0
while [ "${i}" -lt 10 ]; do
    if port_listening 8080; then
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done

exit 1
