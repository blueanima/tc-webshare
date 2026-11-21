#!/bin/sh
# ---------------------------------------------------------------------------
# fetch_src.sh - download and unpack NetBSD 7.2 source sets into /wb-build.
#
# NetBSD's source sets are still needed: bozohttpd lives in
# ${SRC_ROOT}/libexec/httpd (see env.sh).  Idempotent: completed downloads
# and a completed extraction marker are kept.  A tree that is already
# bootstrapped in the tc_wb volume (/wb-build/src, or /wb-build/usr/src) is
# detected and reused without any network access.
# Run inside the build container (see ../Dockerfile and ../run.sh).
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TC_ENV_QUIET=1
. "${SCRIPT_DIR}/env.sh"

BASE_URL=${BASE_URL:-https://cdn.netbsd.org/pub/NetBSD/NetBSD-${NETBSD_RELEASE}/source/sets}
SETS=${SETS:-src.tgz gnusrc.tgz sharesrc.tgz}
# NetBSD source sets contain paths like ./usr/src/..., so they are extracted
# one level above the "usr" component.  EXTRACT_DIR=/wb-build therefore
# produces SRC_ROOT=/wb-build/usr/src, matching env.sh's preferred default.
EXTRACT_DIR=${EXTRACT_DIR:-/wb-build}
MARKER=${DIST_DIR}/.tc-webshare-netbsd-${NETBSD_RELEASE}-unpacked

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# v1.0.1: the tc_wb volume ships a ready tree at /wb-build/src while the
# original default is /wb-build/usr/src.  env.sh selects whichever exists;
# if that tree already has bozohttpd there is nothing to download.
if [ -d "${SRC_ROOT}/libexec/httpd" ]; then
    say "source tree already present at ${SRC_ROOT}; skipping fetch and extraction"
    say "fetch_src.sh done; source root = ${SRC_ROOT}"
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required inside the build container"
command -v tar  >/dev/null 2>&1 || die "tar is required inside the build container"

mkdir -p "${DIST_DIR}" "${STAGE_DIR}"

for set_name in ${SETS}; do
    archive="${DIST_DIR}/${set_name}"
    if [ -f "${archive}" ]; then
        say "cached: ${archive}"
        continue
    fi
    say "fetching: ${BASE_URL}/${set_name}"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
        -o "${archive}.part" "${BASE_URL}/${set_name}"
    mv "${archive}.part" "${archive}"
done

if [ -f "${MARKER}" ] && [ -d "${SRC_ROOT}" ]; then
    say "source tree already unpacked (${MARKER}); skipping extraction"
else
    say "unpacking source sets into ${EXTRACT_DIR}"
    for set_name in ${SETS}; do
        tar -xzf "${DIST_DIR}/${set_name}" -C "${EXTRACT_DIR}"
    done
    : > "${MARKER}"
fi

# Guard against the SRC_ROOT / EXTRACT_DIR mismatch that QA flagged earlier.
[ -d "${SRC_ROOT}/libexec/httpd" ] || die "extraction did not produce ${SRC_ROOT}/libexec/httpd; set SRC_ROOT and EXTRACT_DIR consistently"
[ -d "${SRC_ROOT}/include" ] || die "missing ${SRC_ROOT}/include; set SRC_ROOT/EXTRACT_DIR consistently"

say "fetch_src.sh done; source root = ${SRC_ROOT}"
