#!/bin/sh
# ---------------------------------------------------------------------------
# build_thttpd.sh - HISTORICAL FILENAME, BUILDING bozohttpd SINCE v1.0.1.
#
# The old package compiled thttpd, which is not in NetBSD base and needed an
# external tarball.  bozohttpd is the NetBSD base httpd: its source ships in
# the NetBSD source tree, the exact compile flags are documented upstream,
# and it provides the same features we need (CGI, directory index, Basic
# auth).  The filename is kept so run.sh / Dockerfile / CI keep working.
#
# Outputs (pure static ELF for NetBSD 6.0 evbarm/earmv4):
#   ${STAGE_BIN_DIR}/httpd       <- bozohttpd (NOT thttpd)
#   ${STAGE_BIN_DIR}/upload.cgi  <- src/upload.c
#
# Every artifact is rejected unless BOTH nbfile reports "statically linked"
# and objdump -p shows no INTERP / DYNAMIC section.  The device has no
# dynamic linker for these binaries.
#
# Mandatory flags: --sysroot, -static, -fno-pic, -fno-PIE,
#                  -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
TC_ENV_QUIET=1
. "${SCRIPT_DIR}/env.sh"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "${CC_BIN}" ] || die "cross compiler not found: ${CC_BIN} (set TOOLCHAIN_DIR / CROSS_PREFIX / CC)"
[ -x "${OBJDUMP}" ] || die "objdump not found: ${OBJDUMP}"
[ -x "${NBFILE}" ] || die "nbfile not found: ${NBFILE} (set NBFILE if it lives elsewhere)"
[ -d "${SYSROOT}" ] || die "sysroot missing: ${SYSROOT} (set SYSROOT explicitly; --sysroot is mandatory)"

HTTPD_SRC=${SRC_ROOT}/libexec/httpd
[ -d "${HTTPD_SRC}" ] || die "bozohttpd source missing: ${HTTPD_SRC} (run fetch_src.sh or set SRC_ROOT)"

OBJ_DIR=${BUILD_DIR}/bozohttpd-obj
mkdir -p "${OBJ_DIR}" "${STAGE_BIN_DIR}"

# Upstream Makefile (src/libexec/httpd/Makefile) source list and feature
# switches.  NO_SSL_SUPPORT / NO_LUA_SUPPORT avoid libssl/liblua linkage;
# DO_HTPASSWD keeps Basic auth; CGI + directory index stay enabled.
BOZO_CFLAGS="-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT -I${HTTPD_SRC} -I${SRC_ROOT}/include"
CFLAGS="${BASE_CFLAGS} ${BOZO_CFLAGS}"

BOZO_SRCS="bozohttpd.c ssl-bozo.c auth-bozo.c cgi-bozo.c daemon-bozo.c \
tilde-luzah-bozo.c dir-index-bozo.c content-bozo.c lua-bozo.c main.c"

say "CC=${CC}"
say "SYSROOT=${SYSROOT}"
say "SRC=${HTTPD_SRC}"
say "CFLAGS=${CFLAGS}"

# Compile each unit into a private object directory (no source-tree writes).
obj_list=""
for src_name in ${BOZO_SRCS}; do
    src_file=${HTTPD_SRC}/${src_name}
    [ -f "${src_file}" ] || die "missing bozohttpd source file: ${src_file}"
    obj_file=${OBJ_DIR}/${src_name%.c}.o
    say "CC ${src_name}"
    # ${CC} expands to "gcc --sysroot=..." and must stay unquoted.
    # shellcheck disable=SC2086
    ${CC} ${CFLAGS} -c "${src_file}" -o "${obj_file}"
    obj_list="${obj_list} ${obj_file}"
done

say "LD ${STAGE_BIN_DIR}/httpd (bozohttpd)"
# shellcheck disable=SC2086
${CC} ${BASE_LDFLAGS} -o "${STAGE_BIN_DIR}/httpd" ${obj_list} -lcrypt -lm

say "CC ${PKG_ROOT}/src/upload.c"
# shellcheck disable=SC2086
${CC} ${CFLAGS} -o "${STAGE_BIN_DIR}/upload.cgi" "${PKG_ROOT}/src/upload.c"

# Strip if available; failure to strip is non-fatal.
if [ -x "${STRIP}" ]; then
    "${STRIP}" "${STAGE_BIN_DIR}/httpd" "${STAGE_BIN_DIR}/upload.cgi" || true
fi

verify_static() {
    verify_path=$1
    [ -f "${verify_path}" ] || die "missing output: ${verify_path}"

    file_desc=$("${NBFILE}" "${verify_path}" 2>&1 || true)
    case "${file_desc}" in
        *"statically linked"*) : ;;
        *) die "nbfile says not statically linked: ${verify_path} -> ${file_desc}" ;;
    esac
    case "${file_desc}" in
        *ARM*) : ;;
        *) die "nbfile says not ARM: ${verify_path} -> ${file_desc}" ;;
    esac
    say "nbfile:  ${file_desc}"

    if "${OBJDUMP}" -p "${verify_path}" 2>/dev/null | grep -Eq '[[:space:]](INTERP|DYNAMIC)[[:space:]]'; then
        die "dynamic section found in ${verify_path}; target has no dynamic linker"
    fi
    say "objdump: static OK (no INTERP/DYNAMIC): ${verify_path}"
}

verify_static "${STAGE_BIN_DIR}/httpd"
verify_static "${STAGE_BIN_DIR}/upload.cgi"

{
    printf 'built=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'server=bozohttpd\n'
    printf 'triplet=%s\n' "${CROSS_TRIPLET}"
    printf 'sysroot=%s\n' "${SYSROOT}"
    printf 'src_root=%s\n' "${SRC_ROOT}"
    printf 'cflags=%s\n' "${BASE_CFLAGS}"
    printf 'httpd_sha256=%s\n' "$(sha256sum "${STAGE_BIN_DIR}/httpd" | awk '{print $1}')"
    printf 'upload_cgi_sha256=%s\n' "$(sha256sum "${STAGE_BIN_DIR}/upload.cgi" | awk '{print $1}')"
} > "${STAGE_DIR}/build-info"

say "build complete; static binaries in ${STAGE_BIN_DIR} (httpd, upload.cgi)"
