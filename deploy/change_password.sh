#!/bin/sh
# tc-webshare — change the Web-share Basic-auth password ON THE DEVICE.
# ---------------------------------------------------------------------------
# Run this on the AirPort Time Capsule itself (the device already has openssl
# and stty).  It regenerates the crypt(3) hash in the managed htpasswd file.
# bozohttpd reads .htpasswd on every request, so the new password takes effect
# IMMEDIATELY — no service restart, no reboot, no re-run of install.sh.
#
# Usage (ssh to the device, from anywhere):
#   sh /mnt/Flash/.tc_webshare/bin/change_password.sh
#   sh <this-script> -u admin          # override username
#
# Non-interactive (e.g. from a trusted build machine over ssh), feed the new
# password on stdin — it is read via `openssl passwd -1 -stdin`, never placed
# in argv, so it does not leak into shell history or the process list:
#   printf '%s\n' 'NEW_PASSWORD' | sh change_password.sh -u admin
#
# Layout assumptions (all created by install.sh):
#   ETC_DIR  = <ROOT_DIR>/etc            default /mnt/Flash/.tc_webshare/etc
#   htpasswd = <ETC_DIR>/htpasswd        mode 0600, user:hash per line
# The docroot .htpasswd is a symlink to this file, so one edit updates both.
#
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ROOT_DIR=${TC_ROOT_DIR:-/mnt/Flash/.tc_webshare}
ETC_DIR=${TC_ETC_DIR:-${ROOT_DIR}/etc}
HTPASSWD=${TC_HTPASSWD:-${ETC_DIR}/htpasswd}
USER_NAME=${TC_WEB_USER:-admin}

# Optional -u <user> override.
if [ "${1:-}" = '-u' ]; then
    [ -n "${2:-}" ] || die "-u needs a username"
    USER_NAME=$2
    shift 2
fi
[ "$#" -eq 0 ] || die "usage: sh $0 [-u username]"

command -v openssl >/dev/null 2>&1 || die "openssl not found (needed to compute the crypt(3) hash)"
[ -d "${ETC_DIR}" ] || die "managed etc dir not found: ${ETC_DIR} (is tc-webshare installed?)"

# Read the new password without echoing it.  Prefer a TTY (stty -echo); when
# stdin is a pipe, just read the first line.  The password is held only in a
# shell variable and piped straight into openssl — never in argv or a file.
if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
    printf 'New password for %s: ' "${USER_NAME}" >&2
    oldtty=$(stty -g 2>/dev/null || true)
    stty -echo 2>/dev/null || true
    IFS= read -r PASS1 || true
    stty "${oldtty}" 2>/dev/null || true
    printf '\nConfirm password: ' >&2
    stty -echo 2>/dev/null || true
    IFS= read -r PASS2 || true
    stty "${oldtty}" 2>/dev/null || true
    printf '\n' >&2
    [ -n "${PASS1}" ] || die "empty password rejected"
    [ "${PASS1}" = "${PASS2}" ] || die "passwords do not match"
else
    IFS= read -r PASS1 || true
    [ -n "${PASS1}" ] || die "empty password rejected (feed it on stdin)"
    PASS2=${PASS1}
fi

# Generate an MD5-crypt (crypt(3) "$1$") hash, same format install.sh uses.
HASH=$(printf '%s\n' "${PASS1}" | openssl passwd -1 -stdin 2>/dev/null) \
    || die "openssl passwd failed"
case "${HASH}" in
    \$1\$*) : ;;
    *) die "unexpected hash format from openssl: ${HASH%%\$*}" ;;
esac

# Rebuild htpasswd atomically: preserve any OTHER users, replace/append ours.
TMP="${ETC_DIR}/.htpasswd.new.$$"
: > "${TMP}"
if [ -f "${HTPASSWD}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            "${USER_NAME}":*) : ;;                 # skip old entry for this user
            ''|'#'*) printf '%s\n' "${line}" >> "${TMP}" ;;
            *) printf '%s\n' "${line}" >> "${TMP}" ;;
        esac
    done < "${HTPASSWD}"
fi
printf '%s:%s\n' "${USER_NAME}" "${HASH}" >> "${TMP}"
chmod 0600 "${TMP}"
mv -f "${TMP}" "${HTPASSWD}" || die "failed to install new htpasswd"
chmod 0600 "${HTPASSWD}"

# Never leave the plaintext around in the environment.
PASS1=''; PASS2=''; HASH=''
unset PASS1 PASS2 HASH 2>/dev/null || true

say "OK: password updated for user '${USER_NAME}'."
say "File: ${HTPASSWD} (mode 0600)."
say "The change is live immediately — no restart needed (bozohttpd re-reads .htpasswd per request)."
