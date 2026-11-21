# Target device layout and file ownership

AirPort Time Capsule, firmware 7.9.1, NetBSD 6.0 / evbarm / earmv4.
All paths below are on the device. Nothing in this document is executed on
the build machine or by this repository's scripts.

## Ownership summary

| Path | Ownership | Action on rollback |
| --- | --- | --- |
| `/mnt/Flash/boot.sh` | Apple / device (read-only except the managed write window) | Only the managed marker block is removed; every other line is byte-identical and sha256-verified |
| `/Volumes/dk2/.tc_tools/bin/` | **tc-toolbox — DO NOT TOUCH** | Never read-modify-write; only counted for verification |
| `/Volumes/dk2/.samba4/` | **TimeCapsuleSMB Samba — DO NOT TOUCH** | Never modified; existence verified |
| `/Volumes/dk2/.tc_webshare/` | **tc-webshare managed (rollback boundary)** | Removed completely by `uninstall.sh` |
| `/Volumes/dk2/share/web/` | User upload data | Preserved by default; deleted only with `--purge-data` |
| `/Volumes/dk2/share/web/cgi-bin/` | CGI endpoint owned by tc-webshare | Managed marker file + `upload.cgi` removed on rollback |
| `/Volumes/dk2/share/web/.htpasswd` | Symlink into managed `etc/` | Symlink removed on rollback |

## Managed tree

```
/Volumes/dk2/.tc_webshare/                <- deletion boundary
├── bin/
│   ├── thttpd                            static ELF, no INTERP/DYNAMIC
│   ├── upload.cgi                        static ELF, LFS enabled
│   └── boot_hook.sh                      POSIX sh, absolute paths only
├── etc/
│   ├── thttpd.conf                       port 8080, dir=/Volumes/dk2/share/web
│   └── htpasswd                          generated locally at install time (0600)
└── state/
    ├── thttpd.pid                        PID of foreground thttpd (-D)
    ├── thttpd.log                        server log
    ├── upload.log                        appended by upload.cgi
    ├── upload.lock                       O_EXCL single-writer lock (transient)
    └── manifest                          install paths + boot.sh hashes + timestamp
```

## Data tree

```
/Volumes/dk2/share/web/                   <- user data, survives normal rollback
├── .htpasswd -> /Volumes/dk2/.tc_webshare/etc/htpasswd
├── cgi-bin/
│   ├── upload.cgi                        copy of managed binary (CGI path)
│   └── .tc-webshare-link                 ownership marker
└── <user files>                          basename whitelist [A-Za-z0-9._-]
```

## boot.sh managed block

The only lines tc-webshare ever inserts into `/mnt/Flash/boot.sh`:

```
# >>> TC_WEBSHARE BEGIN >>>
# tc-webshare: LAN-only HTTP share; managed block, do not edit by hand.
if [ -x /Volumes/dk2/.tc_webshare/bin/boot_hook.sh ]; then
    /Volumes/dk2/.tc_webshare/bin/boot_hook.sh >/dev/null 2>&1
fi
# <<< TC_WEBSHARE END <<<
```

`install.sh` changes permissions with `chmod u+w` before the write and
`chmod u-w` afterwards. `uninstall.sh` deletes only the inclusive sed range
between these two markers (NetBSD syntax: `sed -i ""`), then compares the
filtered SHA-256 with the value recorded in `state/manifest`.

## Ports and coexistence

| Service | Port | Owner | Required state |
| --- | --- | --- | --- |
| HTTP (tc-webshare) | 8080 | thttpd | closed before install, closed after rollback |
| SMB (TimeCapsuleSMB) | 139, 445 | Samba | listening before install and after rollback |

## Notes on the root filesystem

`/` is reset at every reboot; only `/Volumes/dk2` and the Flash boot hook
survive. Therefore no runtime state may be written outside the two trees
above, and the boot hook must use absolute paths exclusively.
