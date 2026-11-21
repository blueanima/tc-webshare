#!/bin/sh
# ---------------------------------------------------------------------------
# build_thttpd.sh - cross-compile thttpd + upload.cgi as pure static ELF for
# AirPort Time Capsule (NetBSD 6.0/evbarm/earmv4, no dynamic linker).
#
# Mandatory flags: -static -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE.
# Every produced binary is rejected unless objdump shows no INTERP/DYNAMIC.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
TC_ENV_QUIET=1
. "${SCRIPT_DIR}/env.sh"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "${CC}" ] || die "cross compiler not found: ${CC} (set CROSS_PREFIX or CC)"
[ -x "${OBJDUMP}" ] || die "objdump not found: ${OBJDUMP}"
[ -d "${SRC_ROOT}" ] || die "source tree missing: ${SRC_ROOT} (run fetch_src.sh first)"
mkdir -p "${BUILD_DIR}/thttpd" "${STAGE_BIN_DIR}"

THTTPD_ROOT=$(find "${SRC_ROOT}" -type d -name thttpd 2>/dev/null | head -n 1 || true)
[ -n "${THTTPD_ROOT}" ] || die "thttpd source directory not found under ${SRC_ROOT}"
say "thttpd source: ${THTTPD_ROOT}"

INCLUDE_FLAGS=$(find "${THTTPD_ROOT}" -type f -name '*.h' -exec dirname '{}' \; 2>/dev/null \
    | sort -u | sed 's|^|-I|' | tr '\n' ' ')
[ -n "${INCLUDE_FLAGS}" ] || INCLUDE_FLAGS="-I${THTTPD_ROOT}"

CFLAGS="${BASE_CFLAGS} ${INCLUDE_FLAGS}"
LDFLAGS="${BASE_LDFLAGS}"

# Compile each thttpd C file into an independent object directory.
obj_count=0
for src_file in $(find "${THTTPD_ROOT}" -type f -name '*.c' | sort); do
    base_name=$(basename "${src_file}" .c)
    say "CC ${src_file}"
    # shellcheck disable=SC2086
    "${CC}" ${CFLAGS} -c "${src_file}" -o "${BUILD_DIR}/thttpd/${base_name}.o"
    obj_count=$((obj_count + 1))
done
[ "${obj_count}" -gt 0 ] || die "no .c files found under ${THTTPD_ROOT}"

# shellcheck disable=SC2086
"${CC}" ${LDFLAGS} -o "${STAGE_BIN_DIR}/thttpd" "${BUILD_DIR}/thttpd/"*.o

# upload.cgi is built with the exact same static/LFS flags.
say "CC ${PKG_ROOT}/src/upload.c"
# shellcheck disable=SC2086
"${CC}" ${CFLAGS} -o "${STAGE_BIN_DIR}/upload.cgi" "${PKG_ROOT}/src/upload.c"

# Strip if available; failure to strip is non-fatal.
if [ -x "${STRIP}" ]; then
    "${STRIP}" "${STAGE_BIN_DIR}/thttpd" "${STAGE_BIN_DIR}/upload.cgi" || true
fi

verify_static() {
    verify_path=$1
    [ -f "${verify_path}" ] || die "missing output: ${verify_path}"
    if "${OBJDUMP}" -p "${verify_path}" 2>/dev/null | grep -Eq '[[:space:]](INTERP|DYNAMIC)[[:space:]]'; then
        die "dynamic section found in ${verify_path}; target has no dynamic linker"
    fi
    say "static OK: ${verify_path} (no INTERP/DYNAMIC)"
}

verify_static "${STAGE_BIN_DIR}/thttpd"
verify_static "${STAGE_BIN_DIR}/upload.cgi"

{
    printf 'built=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'triplet=%s\n' "${CROSS_TRIPLET}"
    printf 'cflags=%s\n' "${BASE_CFLAGS}"
    printf 'thttpd_sha256=%s\n' "$(sha256sum "${STAGE_BIN_DIR}/thttpd" | awk '{print $1}')"
    printf 'upload_cgi_sha256=%s\n' "$(sha256sum "${STAGE_BIN_DIR}/upload.cgi" | awk '{print $1}')"
} > "${STAGE_DIR}/build-info"

say "build complete; binaries in ${STAGE_BIN_DIR}"
