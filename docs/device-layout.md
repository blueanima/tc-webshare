# Target device layout and file ownership

AirPort Time Capsule, firmware 7.9.1, NetBSD 6.0 / evbarm / earmv4.
All paths below are on the device. Nothing in this document is executed on
the build machine or by this repository's scripts.

## Filesystem facts that drive this layout (lead's on-device probe, authoritative)

| Mount | Size | Notes |
| --- | --- | --- |
| `/` (md0a) | 15 MB | reset at boot; never store state here |
| `/mnt/Flash` (flash2a) | 2.7 MB | persistent; **our binaries live here** |
| `/mnt/Memory` (tmpfs) | 16 MB | present, but not used by tc-webshare |
| `/Volumes/dkN` | SATA disk | mounted on demand by Apple, unmounts when idle, **N changes every boot**, binaries cannot run from it |

`/etc/fstab` contains only the first three entries. `/Volumes/` was empty at
probe time even though `/dev/dk2` and `/sbin/mount_hfs` exist; Apple mounts
the HDD on demand when a Samba client touches the share and unmounts it on
idle. TimeCapsuleSMB's own README says the disk appears under `/Volumes/dk2`
**or** `/Volumes/dk3` and must never be used to execute a binary. Therefore
the deployment keeps binaries and configuration on Flash and only places user
DATA on a disk that is **currently** mounted; otherwise data goes to
`<WEB_ROOT>/data` on Flash (small — see README). We never try to force a mount.

QA also confirmed Samba **is** running (139/445/548/22 LISTEN); the process is
named `service`, which is why an earlier `ps` grep missed it.

## Ownership summary

| Path | Ownership | Action on rollback |
| --- | --- | --- |
| `/mnt/Flash/boot.sh` | TimeCapsuleSMB (read-only except the managed write window) | Only the managed marker block is removed; every other line is compared line-for-line with the install-time snapshot |
| TimeCapsuleSMB's `/mnt/Flash/service`, `tcapsulesmb.conf`, `seed_profile.sh`, `diskd`/`wcifsnd` guards | **DO NOT TOUCH** | never read-modify-written; Samba may be stopped, that is only warned about |
| `/mnt/Flash/.tc_webshare/` | **tc-webshare managed (rollback boundary)** | removed completely by `uninstall.sh` |
| mounted `/Volumes/dkN/share/web/` or `/mnt/Flash/.tc_webshare/data/` | User upload data | preserved by default; deleted only with `--purge-data` |
| data root `cgi-bin/.tc-webshare-link` | CGI directory ownership marker | removed on rollback; no binary is stored there |

## Managed tree (default ROOT_DIR=/mnt/Flash/.tc_webshare)

```
/mnt/Flash/.tc_webshare/                <- deletion boundary
├── bin/
│   ├── httpd                           static bozohttpd ELF, no INTERP/DYNAMIC
│   ├── upload.bin                      static upload.cgi ELF, LFS enabled
│   ├── boot_hook.sh                    POSIX sh, absolute paths only
│   ├── common.sh -> tc_common.sh       shared on-device helpers
│   ├── tc_common.sh                    dependency-light helper library
│   └── tc_paths.sh                     generated absolute-path constants
├── upload_shim                         generated /bin/sh CGI handler: re-supplies
│                                       TC_SHARE_DIR / TC_STATE_DIR to upload.bin
│                                       (bozohttpd rebuilds the CGI env from scratch)
├── etc/
│   └── htpasswd                        generated locally at install time (0600)
│                                       linked into docroot as .htpasswd
├── data/                               user data when no disk is mounted
└── state/
    ├── bozohttpd.pid                   written by bozohttpd -P in daemon mode
    ├── upload.log                      appended by upload.cgi
    ├── upload.lock                     O_EXCL single-writer lock (transient)
    ├── boot.nonweb                     install-time copy of boot.sh without markers
    └── manifest                        install paths + timestamp
```

## Data tree (resolved at install/boot time)

```
<SHARE_DIR>/                              <- user data, survives normal rollback
├── .htpasswd -> <WEB_ROOT>/etc/htpasswd  (single link protects GET / and POST /upload.cgi)
└── <user files>                          basename whitelist [A-Za-z0-9._-]
```

`SHARE_DIR` resolution order: explicit `TC_SHARE_DIR`; else the first writable
`/Volumes/dkN` whose filesystem differs from `/Volumes` (via `ls` + `df`); else
`<WEB_ROOT>/data` on Flash. bozohttpd is started with `-C .cgi <shim>` so the
CGI URL `/upload.cgi` resolves in the docroot; `.htpasswd` is not recursive,
but one link now covers both requests.

## boot.sh managed block

boot.sh is TimeCapsuleSMB's installer, runs with `set -eu`, and ends with
`echo 'boot: starting native manager'` followed by
`exec /mnt/Flash/service manager`. Appending after exec would be dead code.
The block is inserted **before the echo** (after all `|| exit 1` guards) and
is `|| true` wrapped so a non-zero hook cannot stop the Samba manager.
These are the only lines tc-webshare ever inserts:

```
# >>> TC_WEBSHARE BEGIN >>>
# tc-webshare: LAN-only HTTP share; managed block, do not edit by hand.
# Must stay BEFORE "boot: starting native manager" / the final exec.
{
if [ -x /mnt/Flash/.tc_webshare/bin/boot_hook.sh ]; then
    /mnt/Flash/.tc_webshare/bin/boot_hook.sh >/dev/null 2>&1 || true
fi
} || true
# <<< TC_WEBSHARE END <<<
```

`install.sh` uses `chmod u+w` before the write and `chmod u-w` afterwards.
`uninstall.sh` removes only the inclusive marker range and compares the
remaining lines with `state/boot.nonweb`. `sed` and line-by-line `read` are
used; `grep`, `awk`, `sha256sum`, `head`, `find`, `mount` are not available on
the device and are never called. Every script starts with
`PATH=/bin:/sbin:/usr/bin:/usr/sbin` because the interactive SSH PATH lacks
/sbin.

## Ports and coexistence

| Service | Port | Owner | Required state |
| --- | --- | --- | --- |
| HTTP (tc-webshare) | 8080 | bozohttpd | closed before fresh install, closed after rollback |
| SMB (TimeCapsuleSMB) | 139, 445 | Samba | MAY be stopped; a warning is logged, never a deployment failure |

## Notes on the root filesystem

`/` is reset at every reboot; only `/mnt/Flash` and a currently mounted disk
survive. No runtime state may be written outside the managed tree above, and
the boot hook uses absolute paths exclusively.
