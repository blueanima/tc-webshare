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
#
# v1.0.1 adaptation: the toolchain in the tc_wb Docker volume lives at
# /wb-build/tc-earmv4-netbsd7/tools/bin and its sysroot at
# /wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm; the original SDK_DIR
# layout (/opt/netbsd-sdk/toolchain/bin + /opt/netbsd-sdk/sysroot) is still
# supported.  TOOLCHAIN_DIR / SYSROOT / SRC_ROOT may be set explicitly.
# ---------------------------------------------------------------------------

NETBSD_VERSION=${NETBSD_VERSION:-7.2_STABLE}
NETBSD_RELEASE=${NETBSD_RELEASE:-7.2}
MACHINE=${MACHINE:-evbarm}
MACHINE_ARCH=${MACHINE_ARCH:-earmv4}
CROSS_TRIPLET=${CROSS_TRIPLET:-armv4--netbsdelf-eabi}

NETBSD_SDK_ROOT=${NETBSD_SDK_ROOT:-/opt/netbsd-sdk}

# --- TOOLCHAIN_DIR -------------------------------------------------------
# Precedence: explicit TOOLCHAIN_DIR > original SDK layout > tc_wb volume.
if [ -z "${TOOLCHAIN_DIR:-}" ]; then
    if [ -d "${NETBSD_SDK_ROOT}/toolchain/bin" ]; then
        TOOLCHAIN_DIR="${NETBSD_SDK_ROOT}/toolchain/bin"
    elif [ -d "/wb-build/tc-earmv4-netbsd7/tools/bin" ]; then
        TOOLCHAIN_DIR="/wb-build/tc-earmv4-netbsd7/tools/bin"
    else
        TOOLCHAIN_DIR="${NETBSD_SDK_ROOT}/toolchain/bin"
    fi
fi

CROSS_PREFIX=${CROSS_PREFIX:-${TOOLCHAIN_DIR}/${CROSS_TRIPLET}-}

# --- SYSROOT -------------------------------------------------------------
# --sysroot is MANDATORY with this toolchain: without it gcc picks up the
# host's headers/libs and produces a binary that cannot run on the device.
# Search order: explicit SYSROOT > original SDK sysroot > SDK obj/destdir >
# obj/destdir next to TOOLCHAIN_DIR (the tc_wb volume layout).
if [ -z "${SYSROOT:-}" ]; then
    _tc_parent=${TOOLCHAIN_DIR%/*}          # .../tools
    _tc_grandparent=${_tc_parent%/*}        # .../tc-earmv4-netbsd7
    # NB: the obj destdir is named after MACHINE (evbarm), not MACHINE_ARCH
    # (earmv4).  Both spellings are probed for compatibility.
    for _candidate in \
        "${NETBSD_SDK_ROOT}/sysroot" \
        "${NETBSD_SDK_ROOT}/obj/destdir.${MACHINE}" \
        "${NETBSD_SDK_ROOT}/obj/destdir.${MACHINE_ARCH}" \
        "${_tc_grandparent}/obj/destdir.${MACHINE}" \
        "${_tc_grandparent}/obj/destdir.${MACHINE_ARCH}" \
        "${_tc_parent}/obj/destdir.${MACHINE}"
    do
        if [ -d "${_candidate}" ]; then
            SYSROOT=${_candidate}
            break
        fi
    done
    [ -n "${SYSROOT:-}" ] || SYSROOT="${NETBSD_SDK_ROOT}/sysroot"
    unset _candidate _tc_parent _tc_grandparent
fi

SYSROOT_CFLAGS=${SYSROOT_CFLAGS:---sysroot=${SYSROOT}}

AR=${AR:-${CROSS_PREFIX}ar}
RANLIB=${RANLIB:-${CROSS_PREFIX}ranlib}
OBJDUMP=${OBJDUMP:-${CROSS_PREFIX}objdump}
STRIP=${STRIP:-${CROSS_PREFIX}strip}
READELF=${READELF:-${CROSS_PREFIX}readelf}
# nbfile is installed next to the cross tools; it is a Linux-native helper.
NBFILE=${NBFILE:-${TOOLCHAIN_DIR}/nbfile}

# CC intentionally contains TWO words ("gcc --sysroot=...").  Build scripts
# MUST expand it unquoted (${CC}); use CC_BIN when testing executability.
CC=${CC:-${CROSS_PREFIX}gcc ${SYSROOT_CFLAGS}}
CC_BIN=${CC%% *}
CXX=${CXX:-${CROSS_PREFIX}g++ ${SYSROOT_CFLAGS}}

# --- SRC_ROOT ------------------------------------------------------------
# NetBSD source sets expand to ./usr/src/... under /wb-build (SRC_ROOT
# /wb-build/usr/src).  The pre-bootstrapped tc_wb volume instead ships a
# ready tree at /wb-build/src.  Both are valid; prefer the classic path.
if [ -z "${SRC_ROOT:-}" ]; then
    if [ -d "/wb-build/usr/src/libexec/httpd" ]; then
        SRC_ROOT=/wb-build/usr/src
    elif [ -d "/wb-build/src/libexec/httpd" ]; then
        SRC_ROOT=/wb-build/src
    else
        SRC_ROOT=/wb-build/usr/src
    fi
fi

# Build scratch and output paths (case-sensitive volumes only).
DIST_DIR=${DIST_DIR:-/wb-build/dist}
BUILD_DIR=${BUILD_DIR:-/wb-build/obj/tc-webshare}
STAGE_DIR=${STAGE_DIR:-/buildroot/stage}
STAGE_BIN_DIR=${STAGE_BIN_DIR:-${STAGE_DIR}/bin}

# LFS is mandatory: a 32-bit off_t overflows at 2 GiB on this 32-bit target.
LFS_CFLAGS=${LFS_CFLAGS:--D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE}
BASE_CFLAGS=${BASE_CFLAGS:--O2 -g0 -static -fno-pic -fno-PIE ${LFS_CFLAGS}}
BASE_LDFLAGS=${BASE_LDFLAGS:--static}

export NETBSD_VERSION NETBSD_RELEASE MACHINE MACHINE_ARCH CROSS_TRIPLET
export NETBSD_SDK_ROOT TOOLCHAIN_DIR CROSS_PREFIX SYSROOT SYSROOT_CFLAGS
export CC CC_BIN CXX AR RANLIB OBJDUMP STRIP READELF NBFILE
export DIST_DIR SRC_ROOT BUILD_DIR STAGE_DIR STAGE_BIN_DIR
export LFS_CFLAGS BASE_CFLAGS BASE_LDFLAGS

# Print a short summary when sourced from an interactive shell.
if [ "${TC_ENV_QUIET:-0}" != "1" ]; then
    printf 'tc-webshare cross env: %s / %s / %s\n' \
        "${NETBSD_VERSION}" "${MACHINE_ARCH}" "${CROSS_TRIPLET}" >&2
    printf '  SDK=%s  SYSROOT=%s\n' "${NETBSD_SDK_ROOT}" "${SYSROOT}" >&2
    printf '  TOOLCHAIN=%s  SRC=%s  STAGE=%s\n' \
        "${TOOLCHAIN_DIR}" "${SRC_ROOT}" "${STAGE_BIN_DIR}" >&2
fi
