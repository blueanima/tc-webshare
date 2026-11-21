#!/bin/sh
# ---------------------------------------------------------------------------
# env.sh - NetBSD 7.2_STABLE cross-build environment for evbarm / earmv4
#
# SOURCE: copied from the TimeCapsuleSMB project's cross-build environment
#         (build/env.sh). The upstream copyright and licence notice are
#         preserved verbatim below. Do not remove them when re-syncing.
#
# Copyright (C) 2023-2026 TimeCapsuleSMB contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Usage: . ./env.sh    (source it; every value uses a :- default so callers
#                       and CI can override any single variable).
# ---------------------------------------------------------------------------

NETBSD_VERSION=${NETBSD_VERSION:-7.2_STABLE}
NETBSD_RELEASE=${NETBSD_RELEASE:-7.2}
MACHINE=${MACHINE:-evbarm}
MACHINE_ARCH=${MACHINE_ARCH:-earmv4}
CROSS_TRIPLET=${CROSS_TRIPLET:-armv4--netbsdelf-eabi}

NETBSD_SDK_ROOT=${NETBSD_SDK_ROOT:-/opt/netbsd-sdk}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-${NETBSD_SDK_ROOT}/toolchain/bin}
CROSS_PREFIX=${CROSS_PREFIX:-${TOOLCHAIN_DIR}/${CROSS_TRIPLET}-}

CC=${CC:-${CROSS_PREFIX}gcc}
CXX=${CXX:-${CROSS_PREFIX}g++}
AR=${AR:-${CROSS_PREFIX}ar}
RANLIB=${RANLIB:-${CROSS_PREFIX}ranlib}
OBJDUMP=${OBJDUMP:-${CROSS_PREFIX}objdump}
STRIP=${STRIP:-${CROSS_PREFIX}strip}
READELF=${READELF:-${CROSS_PREFIX}readelf}

SYSROOT=${SYSROOT:-${NETBSD_SDK_ROOT}/sysroot}

# Build scratch and output paths (case-sensitive volumes only).
DIST_DIR=${DIST_DIR:-/wb-build/dist}
SRC_ROOT=${SRC_ROOT:-/wb-build/usr/src}
BUILD_DIR=${BUILD_DIR:-/wb-build/obj/tc-webshare}
STAGE_DIR=${STAGE_DIR:-/buildroot/stage}
STAGE_BIN_DIR=${STAGE_BIN_DIR:-${STAGE_DIR}/bin}

# LFS is mandatory: a 32-bit off_t overflows at 2 GiB on this 32-bit target.
LFS_CFLAGS=${LFS_CFLAGS:--D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE}
BASE_CFLAGS=${BASE_CFLAGS:--O2 -g0 -static -fno-pic -fno-PIE ${LFS_CFLAGS}}
BASE_LDFLAGS=${BASE_LDFLAGS:--static}

export NETBSD_VERSION NETBSD_RELEASE MACHINE MACHINE_ARCH CROSS_TRIPLET
export NETBSD_SDK_ROOT TOOLCHAIN_DIR CROSS_PREFIX
export CC CXX AR RANLIB OBJDUMP STRIP READELF SYSROOT
export DIST_DIR SRC_ROOT BUILD_DIR STAGE_DIR STAGE_BIN_DIR
export LFS_CFLAGS BASE_CFLAGS BASE_LDFLAGS

# Print a short summary when sourced from an interactive shell.
if [ "${TC_ENV_QUIET:-0}" != "1" ]; then
    printf 'tc-webshare cross env: %s / %s / %s\n' \
        "${NETBSD_VERSION}" "${MACHINE_ARCH}" "${CROSS_TRIPLET}" >&2
    printf '  SDK=%s  STAGE=%s\n' "${NETBSD_SDK_ROOT}" "${STAGE_BIN_DIR}" >&2
fi
