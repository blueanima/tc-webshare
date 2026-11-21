#!/bin/sh
# ---------------------------------------------------------------------------
# run_upload_response_test.sh - empirical proof of the v1.0.5 upload hang fix.
#
# Compiles the KNOWN-BUGGY upload.c (from the pre-fix commit) and the CURRENT
# working-tree upload.c as native CGIs, then runs each through a harness that
# reproduces bozohttpd's socketpair CGI topology.  Expectation:
#
#   buggy CGI  -> BUG_REPRODUCED (blocked, no response, lock left behind)
#   fixed CGI  -> PASS           (immediate 200, clean exit, lock released)
#
# Set BUGGY_COMMIT to change the pre-fix reference (default: 4d93087).
# This script never touches the device, credentials, or the network.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUGGY_COMMIT=${BUGGY_COMMIT:-4d93087}
CC=${CC:-cc}
TMP=${TMPDIR:-/tmp}/tc-webshare-repro.$$

cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "${TMP}"
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

command -v "${CC}" >/dev/null 2>&1 || die "C compiler not found: ${CC}"
[ -f "${ROOT}/tests/cgi_response_repro.c" ] || die "harness source missing"
git -C "${ROOT}" cat-file -e "${BUGGY_COMMIT}:src/upload.c" 2>/dev/null \
    || die "buggy commit ${BUGGY_COMMIT} not found in this clone"

CFLAGS="-O0 -g -Wall -Wextra -D_ISOC99_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE"

say "compiling repro harness..."
# shellcheck disable=SC2086
${CC} ${CFLAGS} -o "${TMP}/repro" "${ROOT}/tests/cgi_response_repro.c"

say "compiling pre-fix upload.cgi from ${BUGGY_COMMIT}..."
git -C "${ROOT}" show "${BUGGY_COMMIT}:src/upload.c" > "${TMP}/upload_buggy.c"
# shellcheck disable=SC2086
${CC} ${CFLAGS} -o "${TMP}/cgi_buggy" "${TMP}/upload_buggy.c"

say "compiling current upload.cgi..."
# shellcheck disable=SC2086
${CC} ${CFLAGS} -o "${TMP}/cgi_fixed" "${ROOT}/src/upload.c"

say ""
say "===== A. pre-fix CGI (expected: BUG_REPRODUCED) ====="
set +e
"${TMP}/repro" "${TMP}/cgi_buggy"
buggy_rc=$?
set -e
say "pre-fix exit code: ${buggy_rc}"
if [ "${buggy_rc}" -eq 0 ]; then
    die "pre-fix CGI unexpectedly PASSED - harness does not reproduce the hang"
fi

say ""
say "===== B. current CGI (expected: PASS) ====="
"${TMP}/repro" "${TMP}/cgi_fixed"
fixed_rc=$?
say "current exit code: ${fixed_rc}"
if [ "${fixed_rc}" -ne 0 ]; then
    die "current CGI FAILED - the fix is not effective"
fi

say ""
say "OK: hang reproduced on ${BUGGY_COMMIT} and fixed in the working tree."
