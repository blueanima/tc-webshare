# tc-webshare reproducible cross-build environment.
#
# Build context: the tc-webshare package directory.
#   docker build -t tc-webshare-build:latest <package-dir>
#
# Runtime mounts (see run.sh):
#   /work            -> package dir, READ-ONLY (build scripts + upload.c)
#   /wb-build        -> named Docker volume, case-sensitive (NetBSD sources)
#   /opt/netbsd-sdk  -> host NetBSD 7.2 evbarm/earmv4 cross toolchain, READ-ONLY
#                       (optional: TOOLCHAIN_DIR/SYSROOT may point into /wb-build)
#   /buildroot/stage -> optional host bind mount for collected binaries
#
# NOTE: on macOS hosts, do not bind-mount a case-insensitive APFS directory
# at /wb-build. Use a Docker named volume (the default in run.sh).
FROM debian:bookworm

LABEL org.opencontainers.image.title="tc-webshare cross build" \
      org.opencontainers.image.description="Static bozohttpd/upload.cgi for NetBSD 6.0 evbarm earmv4" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV DEBIAN_FRONTEND=noninteractive \
    NETBSD_SDK_ROOT=/opt/netbsd-sdk \
    CROSS_TRIPLET=armv4--netbsdelf-eabi \
    DIST_DIR=/wb-build/dist \
    BUILD_DIR=/wb-build/obj/tc-webshare \
    STAGE_DIR=/buildroot/stage \
    STAGE_BIN_DIR=/buildroot/stage/bin \
    TC_ENV_QUIET=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      binutils \
      file \
      make \
      coreutils \
      sed \
      mawk \
 && rm -rf /var/lib/apt/lists/*

# /wb-build must be a case-sensitive volume; see run.sh.
RUN mkdir -p /wb-build /buildroot/stage/bin /work /opt/netbsd-sdk
VOLUME ["/wb-build"]

WORKDIR /work

# Default build: fetch sources (idempotent) then compile and verify binaries.
# build_thttpd.sh is a historical filename; since v1.0.1 it builds bozohttpd.
CMD ["/bin/sh", "-c", "/bin/sh /work/build/fetch_src.sh && /bin/sh /work/build/build_thttpd.sh"]
