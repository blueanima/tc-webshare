#!/bin/sh
# ---------------------------------------------------------------------------
# run.sh - build tc-webshare static binaries in Docker.
#
# Usage (either SDK_DIR or TOOLCHAIN_DIR+SYSROOT is required):
#   SDK_DIR=/path/to/netbsd-7.2-evbarm-sdk ./run.sh
#   VOLUME=tc_wb TOOLCHAIN_DIR=/wb-build/tc-earmv4-netbsd7/tools/bin \
#     SYSROOT=/wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm \
#     SRC_ROOT=/wb-build/src NO_FETCH=1 ./run.sh
#
# Optional environment:
#   IMAGE       docker image tag           (default tc-webshare-build:latest)
#   VOLUME      case-sensitive build volume (default tc-webshare-wb-build)
#   BUILD_OUT   host dir to receive stage/ (default: unset, stays in container)
#   NO_CACHE    set to 1 to pass --no-cache to docker build
#   NO_FETCH    set to 1 to skip fetch_src.sh (offline, cached/bootstrapped tree)
#   EXTRA       extra text inserted into docker run before the image name,
#               e.g. "-e TC_ENV_QUIET=0 -e CROSS_PREFIX=/custom/bin/armv4--netbsdelf-eabi-"
#
# This script never touches the target device and never reads credentials.
# Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
# ---------------------------------------------------------------------------
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMAGE=${IMAGE:-tc-webshare-build:latest}
VOLUME=${VOLUME:-tc-webshare-wb-build}
SDK_DIR=${SDK_DIR:-}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-}
SYSROOT=${SYSROOT:-}
SRC_ROOT=${SRC_ROOT:-}
BUILD_OUT=${BUILD_OUT:-}
NO_CACHE=${NO_CACHE:-0}
NO_FETCH=${NO_FETCH:-0}
EXTRA=${EXTRA:-}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"

if [ -z "${SDK_DIR}" ] && [ -z "${TOOLCHAIN_DIR}" ] && [ -z "${SYSROOT}" ]; then
    die "set SDK_DIR (original layout) or TOOLCHAIN_DIR/SYSROOT (tc_wb volume layout)"
fi
[ -z "${SDK_DIR}" ] || [ -d "${SDK_DIR}" ] || die "SDK_DIR is not a directory: ${SDK_DIR}"

BUILD_ARGS=""
if [ "${NO_CACHE}" = "1" ]; then
    BUILD_ARGS="--no-cache"
fi

say "building image ${IMAGE} from ${ROOT}"
# shellcheck disable=SC2086
docker build ${BUILD_ARGS} -t "${IMAGE}" "${ROOT}"

if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
    say "creating case-sensitive build volume ${VOLUME}"
    docker volume create "${VOLUME}" >/dev/null
fi

MOUNTS="-v ${VOLUME}:/wb-build -v ${ROOT}:/work:ro"
if [ -n "${SDK_DIR}" ]; then
    MOUNTS="${MOUNTS} -v ${SDK_DIR}:/opt/netbsd-sdk:ro"
fi
if [ -n "${BUILD_OUT}" ]; then
    mkdir -p "${BUILD_OUT}"
    MOUNTS="${MOUNTS} -v ${BUILD_OUT}:/buildroot/stage"
fi

# The build script (historical filename) compiles bozohttpd + upload.cgi.
if [ "${NO_FETCH}" = "1" ]; then
    BUILD_CMD="/work/build/build_thttpd.sh"
else
    BUILD_CMD="/work/build/fetch_src.sh && /work/build/build_thttpd.sh"
fi

# Forward explicit toolchain/sysroot/source overrides into the container.
ENV_ARGS="-e STAGE_DIR=/buildroot/stage -e STAGE_BIN_DIR=/buildroot/stage/bin"
[ -z "${TOOLCHAIN_DIR}" ] || ENV_ARGS="${ENV_ARGS} -e TOOLCHAIN_DIR=${TOOLCHAIN_DIR}"
[ -z "${SYSROOT}" ] || ENV_ARGS="${ENV_ARGS} -e SYSROOT=${SYSROOT}"
[ -z "${SRC_ROOT}" ] || ENV_ARGS="${ENV_ARGS} -e SRC_ROOT=${SRC_ROOT}"
[ -z "${SDK_DIR}" ] || ENV_ARGS="${ENV_ARGS} -e NETBSD_SDK_ROOT=/opt/netbsd-sdk"

say "running cross build (VOLUME=${VOLUME})"
# shellcheck disable=SC2086
docker run --rm -i \
    ${MOUNTS} \
    ${ENV_ARGS} \
    ${EXTRA} \
    "${IMAGE}" /bin/sh -c "${BUILD_CMD}"

say "build finished; binaries are at ${BUILD_OUT:-/buildroot/stage}/bin (httpd, upload.cgi)"
