#!/bin/sh
# ---------------------------------------------------------------------------
# fetch_src.sh - download and unpack NetBSD 7.2 source sets into /wb-build.
#
# Idempotent: completed downloads and a completed extraction marker are kept.
# Run inside the build container (see ../Dockerfile and ../run.sh).
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/env.sh"

BASE_URL=${BASE_URL:-https://cdn.netbsd.org/pub/NetBSD/NetBSD-${NETBSD_RELEASE}/source/sets}
SETS=${SETS:-src.tgz gnusrc.tgz sharesrc.tgz}
# NetBSD source sets contain paths like ./usr/src/..., so they are extracted
# one level above DIST_DIR to produce the SRC_ROOT declared in env.sh.
EXTRACT_DIR=${EXTRACT_DIR:-/wb-build}
MARKER=${DIST_DIR}/.tc-webshare-netbsd-${NETBSD_RELEASE}-unpacked

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

if [ -f "${MARKER}" ]; then
    say "source tree already unpacked (${MARKER}); skipping extraction"
else
    say "unpacking source sets into ${EXTRACT_DIR}"
    for set_name in ${SETS}; do
        tar -xzf "${DIST_DIR}/${set_name}" -C "${EXTRACT_DIR}"
    done
    [ -d "${SRC_ROOT}" ] || die "expected source directory ${SRC_ROOT} was not created"
    : > "${MARKER}"
    say "unpack complete: ${SRC_ROOT}"
fi

say "fetch_src.sh done; source root = ${SRC_ROOT}"
