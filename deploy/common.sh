#!/bin/sh
# ---------------------------------------------------------------------------
# common.sh - shared, dependency-light helpers for the on-device deploy scripts.
#
# The Time Capsule has a VERY small userland: confirmed present are
# /bin/sh, /bin/ls, /usr/bin/sed, /bin/df, /usr/bin/netstat, /usr/bin/tail and
# a partial /usr/bin/find.  Confirmed ABSENT: grep, head, mount, disklabel,
# file.  tc-toolbox is NOT installed.  Therefore this file deliberately uses
# only POSIX shell builtins plus ls/df/sed/netstat, and a handful of ordinary
# coreutils (mkdir/cp/rm/chmod/sleep/kill/ln) whose presence is checked once
# by require_cmds before anything destructive happens.
#
# Callers must set these variables BEFORE sourcing (or just use defaults):
#   ROOT_DIR      managed binary/config root (default /mnt/Flash/.tc_webshare)
#   MARK_BEGIN / MARK_END  boot.sh marker strings
# When run from the installed package, source ${BIN_DIR}/tc_paths.sh first.
#
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------

# The interactive SSH PATH on this firmware lacks /sbin and /usr/sbin.
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

ROOT_DIR=${ROOT_DIR:-/mnt/Flash/.tc_webshare}

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

MARK_BEGIN=${MARK_BEGIN:-'# >>> TC_WEBSHARE BEGIN >>>'}
MARK_END=${MARK_END:-'# <<< TC_WEBSHARE END <<<'}

# Commands we truly depend on.  Missing ones abort before any path is
# touched.  Deliberately NOT in the list: grep/awk/head/tr/wc/mount/sha256sum/
# ps/find/nc/wget/curl/htpasswd/openssl/od.
REQUIRED_CMDS=${REQUIRED_CMDS:-mkdir cp rm chmod sleep ls df sed netstat cat}

require_cmds() {
    missing=''
    for cmd_name in ${REQUIRED_CMDS}; do
        command -v "${cmd_name}" >/dev/null 2>&1 || missing="${missing} ${cmd_name}"
    done
    [ -z "${missing}" ] || die "missing device commands:${missing} (install tc-toolbox or set REQUIRED_CMDS)"
}

# Reject empty, relative, protected and too-shallow paths.  Absolute paths
# under /Volumes, /mnt/Flash and /mnt/Memory are allowed; rehearsal overrides
# under /tmp are allowed only when TC_ALLOW_REHEARSAL=1.
guard_path() {
    guard_label=$1
    guard_target=$2
    case "${guard_target}" in
        '') die "${guard_label} is an empty path; refusing to continue" ;;
        /*) ;;
        *) die "${guard_label} must be an absolute path: ${guard_target}" ;;
    esac
    guard_norm=${guard_target%/}
    [ -n "${guard_norm}" ] || die "${guard_label} resolves to /"
    [ "${guard_norm}" != "/" ] || die "${guard_label} may not be /"
    if [ -n "${HOME:-}" ] && [ "${guard_norm}" = "${HOME}" ]; then
        die "${guard_label} may not be HOME (${HOME})"
    fi
    case "${guard_norm}" in
        /etc|/usr|/bin|/sbin|/var|/Library|/System|/dev|/proc|/Volumes|/tmp|/private/tmp)
            die "${guard_label} is a protected system path: ${guard_norm}" ;;
    esac
    case "${guard_norm}" in
        /Volumes/*|/mnt/Flash/*|/mnt/Memory/*) ;;
        /tmp/*)
            [ "${TC_ALLOW_REHEARSAL:-0}" = "1" ] || die "${guard_label} may not be under /tmp unless TC_ALLOW_REHEARSAL=1" ;;
        *) die "${guard_label} must be under /Volumes, /mnt/Flash or /mnt/Memory: ${guard_norm}" ;;
    esac
    guard_depth=0
    guard_rest=${guard_norm#/}
    while [ -n "${guard_rest}" ]; do
        guard_depth=$((guard_depth + 1))
        case "${guard_rest}" in
            */*) guard_rest=${guard_rest#*/} ;;
            *) guard_rest='' ;;
        esac
    done
    [ "${guard_depth}" -ge 2 ] || die "${guard_label} is too shallow: ${guard_norm}"
    return 0
}

# Second field of `df -k <path>` (available KiB), empty on failure.
df_avail_kb() {
    _df_line=$(df -k "$1" 2>/dev/null | sed -n '2p') || return 1
    set -- ${_df_line}
    [ "$#" -ge 4 ] || return 1
    case "$4" in
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s\n' "$4" ;;
    esac
}

# First field of `df <path>` (filesystem device name).
df_fs() {
    _line=$(df "$1" 2>/dev/null | sed -n '2p') || return 1
    set -- ${_line}
    [ "$#" -ge 1 ] || return 1
    printf '%s\n' "$1"
}

# Print the first /Volumes/dkN that is really mounted (different filesystem
# from /Volumes itself) and writable.  Uses ls only (no find).  dkN numbering
# changes at every boot, so the number must NEVER be baked into a script.
detect_data_root() {
    base_fs=$(df_fs /Volumes 2>/dev/null || true)
    [ -n "${base_fs}" ] || return 1
    listing=$(ls /Volumes 2>/dev/null || true)
    for name in ${listing}; do
        case "${name}" in
            dk[0-9]*) ;;
            *) continue ;;
        esac
        vol="/Volumes/${name}"
        [ -d "${vol}" ] || continue
        [ -w "${vol}" ] || continue
        vol_fs=$(df_fs "${vol}" 2>/dev/null || true)
        [ -n "${vol_fs}" ] || continue
        [ "${vol_fs}" != "${base_fs}" ] || continue
        printf '%s\n' "${vol}"
        return 0
    done
    return 1
}

# User-data root.  Explicit TC_SHARE_DIR always wins; otherwise a currently
# mounted disk is used (Apple mounts it on demand and unmounts on idle, so we
# never trigger a mount ourselves).  Fallback is a small data directory on
# Flash; README documents the capacity limit.  Binaries never live on dkN.
resolve_share_dir() {
    if [ -n "${TC_SHARE_DIR:-}" ]; then
        printf '%s\n' "${TC_SHARE_DIR}"
        return 0
    fi
    if vol=$(detect_data_root); then
        printf '%s\n' "${vol}/share/web"
    else
        printf '%s\n' "${ROOT_DIR}/data"
    fi
}

# True when a TCP port appears in `netstat -an` as LISTEN.  No grep/awk: the
# whole output is scanned line by line with shell builtins.
port_listening() {
    check_port=$1
    netstat -an 2>/dev/null | ( found=1
        while IFS= read -r line; do
            case "${line}" in
                *LISTEN*)
                    case "${line} " in
                        *".${check_port} "*) found=0 ;;
                    esac
                    ;;
            esac
        done
        return "${found}"
    )
}

# Copy boot.sh to OUT with the managed marker block removed.  Used both for
# "non-Web content" verification and for uninstall.
nonweb_file() {
    src_file=$1
    out_file=$2
    inside=0
    : > "${out_file}"
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            "${MARK_BEGIN}") inside=1; continue ;;
            "${MARK_END}")   inside=0; continue ;;
        esac
        [ "${inside}" -eq 1 ] || printf '%s\n' "${line}" >> "${out_file}"
    done < "${src_file}"
}

# Line-exact comparison of two TEXT files using only shell builtins.  This
# replaces sha256sum, which is not installed on this firmware.
text_files_equal() {
    left_file=$1
    right_file=$2
    exec 3< "${left_file}" 4< "${right_file}"
    cmp_result=0
    while :; do
        IFS= read -r left_line <&3; left_rc=$?
        IFS= read -r right_line <&4; right_rc=$?
        if [ "${left_rc}" -ne 0 ] && [ "${right_rc}" -ne 0 ]; then
            break
        fi
        if [ "${left_rc}" -ne 0 ] || [ "${right_rc}" -ne 0 ] ||
           [ "${left_line}" != "${right_line}" ]; then
            cmp_result=1
            break
        fi
    done
    exec 3<&- 4<&-
    return "${cmp_result}"
}

marker_count() {
    count=0
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            "${MARK_BEGIN}"|"${MARK_END}") count=$((count + 1)) ;;
        esac
    done < "$1"
    printf '%s\n' "${count}"
}

# Insert BLOCK before the last guard in TimeCapsuleSMB's boot.sh.  QA found
# that boot.sh runs with `set -eu` and ends with
# `echo 'boot: starting native manager'` followed by
# `exec /mnt/Flash/service manager`; anything after exec is dead code.  We
# insert before the echo (all `|| exit 1` guards have already passed there).
insert_marker_block() {
    boot_file=$1
    block_file=$2
    out_file=$3
    inserted=0
    : > "${out_file}"
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            *"starting native manager"*|*exec*"/mnt/Flash/service manager"*)
                if [ "${inserted}" -eq 0 ]; then
                    while IFS= read -r block_line || [ -n "${block_line}" ]; do
                        printf '%s\n' "${block_line}" >> "${out_file}"
                    done < "${block_file}"
                    inserted=1
                fi
                ;;
        esac
        printf '%s\n' "${line}" >> "${out_file}"
    done < "${boot_file}"
    if [ "${inserted}" -eq 0 ]; then
        warn "no native-manager marker line found in ${boot_file}; appending block at end"
        while IFS= read -r block_line || [ -n "${block_line}" ]; do
            printf '%s\n' "${block_line}" >> "${out_file}"
        done < "${block_file}"
    fi
    return 0
}

# Place an .htpasswd link (or a copy if ln is unavailable) in DIR.  bozohttpd
# resolves .htpasswd relative to the served directory and does not recurse,
# so both the web root and its cgi-bin/ subdirectory need one.
link_htpasswd() {
    dir_path=$1
    htpasswd_file=$2
    [ -d "${dir_path}" ] || return 1
    if [ -L "${dir_path}/.htpasswd" ] || [ -e "${dir_path}/.htpasswd" ]; then
        rm -f "${dir_path}/.htpasswd" || return 1
    fi
    if command -v ln >/dev/null 2>&1 && ln -s "${htpasswd_file}" "${dir_path}/.htpasswd" 2>/dev/null; then
        return 0
    fi
    cp "${htpasswd_file}" "${dir_path}/.htpasswd" || return 1
    return 0
}
