#!/bin/sh
# ---------------------------------------------------------------------------
# run.sh - build tc-webshare static binaries in Docker.
#
# Usage:
#   SDK_DIR=/path/to/netbsd-7.2-evbarm-sdk ./run.sh
#
# Optional environment:
#   IMAGE       docker image tag           (default tc-webshare-build:latest)
#   VOLUME      case-sensitive build volume (default tc-webshare-wb-build)
#   BUILD_OUT   host dir to receive stage/ (default: unset, stays in container)
#   NO_CACHE    set to 1 to pass --no-cache to docker build
#   NO_FETCH    set to 1 to skip fetch_src.sh (offline, cached sources)
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
BUILD_OUT=${BUILD_OUT:-}
NO_CACHE=${NO_CACHE:-0}
NO_FETCH=${NO_FETCH:-0}
EXTRA=${EXTRA:-}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"

if [ -z "${SDK_DIR}" ] || [ ! -d "${SDK_DIR}" ]; then
    die "set SDK_DIR to a NetBSD 7.2 evbarm/earmv4 cross SDK directory"
fi

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

MOUNTS="-v ${VOLUME}:/wb-build -v ${ROOT}:/work:ro -v ${SDK_DIR}:/opt/netbsd-sdk:ro"
if [ -n "${BUILD_OUT}" ]; then
    mkdir -p "${BUILD_OUT}"
    MOUNTS="${MOUNTS} -v ${BUILD_OUT}:/buildroot/stage"
fi

if [ "${NO_FETCH}" = "1" ]; then
    BUILD_CMD="/work/build/build_thttpd.sh"
else
    BUILD_CMD="/work/build/fetch_src.sh && /work/build/build_thttpd.sh"
fi

say "running cross build (SDK=${SDK_DIR})"
# shellcheck disable=SC2086
docker run --rm -i \
    ${MOUNTS} \
    -e NETBSD_SDK_ROOT=/opt/netbsd-sdk \
    -e STAGE_DIR=/buildroot/stage \
    -e STAGE_BIN_DIR=/buildroot/stage/bin \
    ${EXTRA} \
    "${IMAGE}" /bin/sh -c "${BUILD_CMD}"

say "build finished; binaries are at ${BUILD_OUT:-/buildroot/stage}/bin"
