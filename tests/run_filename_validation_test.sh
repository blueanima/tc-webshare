#!/bin/sh
# run_filename_validation_test.sh - host-side policy test for upload filenames.
# Compiles the real src/upload.c (main renamed) and checks that v1.0.6 accepts
# Chinese/emoji names while every security barrier from v1.0.5 still holds.
# No network, no device, no credentials.
set -eu

ROOT=$(CDPATH= cd -- "${0%/*}/.." && pwd)
CC=${CC:-cc}
BIN=${TMPDIR:-/tmp}/tcwebshare_filename_validation_$$

trap 'rm -f "$BIN"' EXIT HUP INT TERM

"$CC" -Wall -Wextra -O0 -o "$BIN" "${ROOT}/tests/filename_validation_test.c"
"$BIN"
