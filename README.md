# tc-webshare — Static HTTP File Share for Apple AirPort Time Capsule / Apple AirPort Time Capsule 静态 HTTP 文件共享部署包

[中文](#chinese) | [English](#english)

---

<a id="english"></a>

## English

A plaintext HTTP file-sharing kit for **AirPort Time Capsule firmware 7.9.1**: browse, download and upload files on the LAN, coexist cleanly with the device's TimeCapsuleSMB installation, and roll back **with byte-level verification**.

This repository contains source, scripts and documentation only. All builds happen inside Docker; **no network device is contacted, no ssh/scp to real hardware is performed, and no credential file is read**.

> **Verification status — honest disclosure (updated in v1.0.2).** Build-side: the `tc_wb` Docker toolchain/sysroot compiled `httpd` and `upload.cgi`; both passed `nbfile` + `objdump -p` (pure static ARM ELF). Device-side: a **full deployment was performed and accepted** (INSTALL OK, 401/200, upload landed on the disk, `.htpasswd` 403, byte-exact rollback, Samba untouched). **A physical reboot was NOT performed**: boot-time autostart was validated by executing `boot_hook.sh` directly and checking idempotence. See the release notes at the end of this README and [CHANGELOG.md](CHANGELOG.md).

### 1. Device facts and hard constraints (on-device probe, authoritative)

| Item | Value |
| --- | --- |
| Firmware / OS | Apple AirPort Time Capsule 7.9.1 / NetBSD 6.0 evbarm / earmv4 (ARMv4, no Thumb/NEON) |
| Executable format | **Pure static ELF only** (these binaries have no dynamic linker; `ld.elf_so` on Flash is irrelevant to them) |
| Filesystems | `/` md0a 15 MB; `/mnt/Flash` flash2a 2.7 MB; `/mnt/Memory` tmpfs 16 MB. That is all of `/etc/fstab` |
| SATA disk | `/dev/ld0` exists but was **unmounted** (`/Volumes/` empty) at probe time; Apple mounts it on demand as `/Volumes/dk2` **or** `/Volumes/dk3`, the number changes every boot, it unmounts when idle, and **binaries cannot be executed from it** |
| Boot hook | `/mnt/Flash/boot.sh` belongs to **TimeCapsuleSMB**, ends with `exec /mnt/Flash/service manager`, is effectively read-only (`chmod u+w` / `u-w` window) |
| TimeCapsuleSMB | Installed and complete (`/mnt/Flash/service` manager, `tcapsulesmb.conf`, `seed_profile.sh`, diskd/wcifsnd guards), but smbd was **not running** and there were no runtime logs — must not be treated as a deployment precondition |
| Commands present | `/bin/sh`, `/bin/ls`, `/usr/bin/sed`, `/bin/df`, `/usr/bin/netstat`, `/usr/bin/tail`, `/bin/curl`, `/usr/bin/openssl` (`dgst -sha256`, `base64 -d`), plus `mkdir/cp/rm/mv/cat/ln/dd/date/sleep/ps/kill/sort/basename/expr` |
| Commands absent | `grep`, `head`, `find`, `awk`, **`dirname`**, `tr`, `cut`, `base64`, `sha256sum`, `id`, `mktemp`, `stat`, `readlink`, `tee`, `wget`, `nc`, `mount`, `disklabel`, `file`; **tc-toolbox is not installed** |

The missing `dirname` was a real deployment failure: the three deploy scripts
now compute their own directory with pure shell `${0%/*}` and need no external
helper. NAWK/mktemp-free temp files use `$$` suffixes placed on RAM tmpfs
(`/mnt/Memory/.tc_webshare_scratch`), because editing files on synchronous
Flash is extremely slow.
| Word size | 32-bit ⇒ **LFS mandatory**: `-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE` |

Every script sets `PATH=/bin:/sbin:/usr/bin:/usr/sbin` first (interactive SSH lacks `/sbin`). Scripts use only shell builtins plus the commands above; `install.sh` checks them with `require_cmds` before touching any path. QA confirmed Samba **is** running (139/445/548/22 LISTEN; the process is named `service`).

Performance figures from the earlier design (15–25 MB/s downloads, 8–15 MB/s uploads, ≤500 MB safe per file, concurrency lock = 1) are **estimates inherited from the thttpd design and have not been re-measured with bozohttpd**.

### 2. Why bozohttpd instead of thttpd

`build/build_thttpd.sh` keeps its historical filename but compiles **bozohttpd**, the NetBSD base HTTP server:

- its source ships inside the NetBSD source tree we already fetch, so no external thttpd tarball is needed;
- the compile switches are documented upstream (`-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT`) and were reproduced with the real toolchain;
- it provides the same required features: CGI, directory index, HTTP Basic auth;
- the exact CLI differs from thttpd and from older bozohttpd releases. Verified against `main.c` / `bozohttpd.8`: `-b` daemonise, `-I <port>` listen port (**not** `-p`, which is `public_html`), docroot is a **positional** argument (`-d` is debug), `-C .cgi <handler>` suffix-maps CGI, `-X` index (off by default), `-H` hide dotfiles, `-P <pidfile>` PID file, `-U <user>` for privilege drop (deliberately unused). There is **no `-D` / `-g`** option.

```
Browser (LAN) --HTTP :8080--> bozohttpd (static ELF, slashdir=<SHARE_DIR>)
                               |-- GET /                    -> hidden management homepage (-x)
                               |                               -> .htpasswd 401 / download links
                               `-- POST|GET /<action>.cgi (-C .cgi -> Flash cgi_dispatch.sh)
                                                               |-- /upload.cgi -> static upload.bin
                                                               |                  -> upload.lock (O_EXCL, concurrency=1)
                                                               |                  -> <SHARE_DIR>/<basename>
                                                               |-- /list.cgi   -> static manage.bin (JSON listing)
                                                               |-- /mkdir.cgi  -> static manage.bin (mkdir)
                                                               `-- /delete.cgi -> static manage.bin (delete, top-level only)
```

**Why a unified dispatcher:** bozohttpd's `-C .cgi` maps one suffix to **one** handler; it cannot give upload/list/mkdir/delete separate handlers. Switching to `-c <cgibin dir>` would require a second `.htpasswd` and put program files next to user data. We therefore keep `-C .cgi` (which preserves the single docroot `.htpasswd` auth for every `.cgi` URL) and generate a `/bin/sh` dispatcher in managed Flash `bin/`. It restores `TC_SHARE_DIR` / `TC_STATE_DIR` (bozohttpd rebuilds the CGI environment) and routes by `SCRIPT_NAME`. `.htpasswd` is not recursive, but `-C` keeps every action inside the docroot, so **one** link protects GET `/` and all POSTs.

The management homepage is a **program file**: its master copy lives in managed Flash `etc/index.html`, and a hidden copy (`<SHARE_DIR>/.tc-webshare-index.html`) is published into the docroot and served as the default index via bozohttpd `-x`. `-H` hides it from the generated directory listing. Uninstall deletes exactly that file; all other docroot files are user data and are never touched.

### 3. Deployment path strategy

- `ROOT_DIR` (binaries, config, state, manifest) defaults to **`/mnt/Flash/.tc_webshare`** — persistent and executable. Flash is only 2.7 MB; `install.sh` aborts if `df -k /mnt/Flash` reports under 1024 KiB free. Override with `TC_ROOT_DIR`.
- `SHARE_DIR` (user data) is resolved **at install and again at every boot** by `mount_data_volume()` / `detect_data_root()`: explicit `TC_SHARE_DIR` wins; otherwise we **actively ask Apple's diskd to mount** the internal disk with `/usr/bin/acp rpc diskd.useVolume "path:s:/Volumes/dk2"` (the typed `path:s:` prefix is mandatory; bare paths fail with `-6742`), poll `df -k` until it appears, and use `/Volumes/dk2/share/web`. dk3 is tried as a second candidate so a changed dkN is tolerated. **No formatting or partition changes are ever performed** — this only mounts a volume Apple already manages. If mounting genuinely fails we fall back to the **small but persistent** `<ROOT_DIR>/data` on Flash with a loud capacity warning; only if Flash is unavailable do we use volatile `/mnt/Memory/.tc_webshare/share` (also loudly warned). dk2 was confirmed on-device with ~1.8 TB free.
- Binaries never go on the disk (it unmounts on idle and cannot execute ELF); only data does.
- boot.sh has `set -eu` and ends with `echo 'boot: starting native manager'` + `exec /mnt/Flash/service manager`. The marker block is inserted **before the echo** and wrapped in `{ ...; } || true`, so our hook cannot stop Samba. Appending after `exec` would never run. chmod u+w/u-w brackets the write.
- Uninstall removes only the two marker lines and their contents and compares the rest of boot.sh line-for-line against `state/boot.nonweb` (`sha256sum` is absent; `openssl dgst` is available if a hash is ever needed). If data lives inside the managed root, uninstall preserves it unless `--purge-data` is given.
- Samba is currently running (139/445/548/22); silence would only produce a warning, never a deployment failure. TimeCapsuleSMB's files are never modified.

### 4. File tree

```
├── Dockerfile                 debian:bookworm cross-build image
├── run.sh                     docker build + volume + cross build
├── build/
│   ├── env.sh                 cross env; TOOLCHAIN_DIR/SYSROOT/SRC_ROOT overrides, CC includes --sysroot
│   ├── fetch_src.sh           idempotent NetBSD source download/unpack; reuses /wb-build/src
│   └── build_thttpd.sh        historical name; builds httpd + upload.cgi + manage.cgi
├── src/upload.c               streaming multipart upload CGI (unchanged)
├── src/manage.c               list/mkdir/delete CGI (static, JSON, strict UTF-8 basename whitelist)
├── deploy/
│   ├── common.sh              dependency-light on-device helpers
│   ├── install.sh / uninstall.sh
│   ├── boot_hook.sh           starts bozohttpd with verified flags
│   ├── index.html             management homepage template (program file)
│   ├── htpasswd.example       placeholder only
│   └── thttpd.conf            historical, informational only
└── docs/device-layout.md      on-device layout and ownership
```

### 5. Build (local / Docker, no hardware involved)

Prerequisites: Docker plus a NetBSD 7.2 evbarm/earmv4 toolchain. **The sysroot is mandatory**: without `--sysroot`, gcc uses host headers/libs and the result will not run. The `tc_wb` volume already contains a bootstrapped toolchain and source tree:

```
TOOLCHAIN_DIR=/wb-build/tc-earmv4-netbsd7/tools/bin
SYSROOT=/wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm
SRC_ROOT=/wb-build/src
```

```sh
# Original SDK_DIR layout
SDK_DIR=/path/to/netbsd-7.2-evbarm-sdk BUILD_OUT=/path/to/stage ./run.sh

# tc_wb volume layout, offline (no SDK_DIR needed)
VOLUME=tc_wb NO_FETCH=1 \
TOOLCHAIN_DIR=/wb-build/tc-earmv4-netbsd7/tools/bin \
SYSROOT=/wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm \
SRC_ROOT=/wb-build/src \
BUILD_OUT=/path/to/stage ./run.sh

# Force rebuild / reuse cached sources
NO_CACHE=1 ./run.sh
```

Equivalent direct compile (inside a container with `/wb-build` mounted):

```sh
CC='/wb-build/tc-earmv4-netbsd7/tools/bin/armv4--netbsdelf-eabi-gcc --sysroot=/wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm'
CFLAGS='-O2 -g0 -static -fno-pic -fno-PIE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE'
BOZO='-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT -I/wb-build/src/libexec/httpd -I/wb-build/src/include'
for f in bozohttpd.c ssl-bozo.c auth-bozo.c cgi-bozo.c daemon-bozo.c \
         tilde-luzah-bozo.c dir-index-bozo.c content-bozo.c lua-bozo.c main.c; do
  $CC $CFLAGS $BOZO -c /wb-build/src/libexec/httpd/$f -o $f.o
done
$CC -static -o httpd *.o -lcrypt -lm
$CC $CFLAGS -o upload.cgi /path/to/tc-webshare/src/upload.c
```

Artifacts: `httpd` (bozohttpd) and `upload.cgi`. Every one must pass **both** checks:

```
nbfile <artifact>            # must say "ELF 32-bit LSB ARM EABI5 statically linked ..."
objdump -p <artifact>        # must contain no INTERP / DYNAMIC section
```

`fetch_src.sh` prefers `/wb-build/usr/src` (what the source tarballs produce) but detects and reuses the volume's `/wb-build/src`; it fails loudly if `SRC_ROOT` and `EXTRACT_DIR` disagree.

Local static checks (no toolchain needed):

```sh
for f in run.sh build/env.sh build/fetch_src.sh build/build_thttpd.sh \
         deploy/common.sh deploy/install.sh deploy/uninstall.sh deploy/boot_hook.sh; do
    sh -n "$f" || exit 1
done
```

### 6. Deployment (on the device)

Copy package and artifacts (sshd has no SFTP, use `-O`):

```sh
scp -O -r tc-webshare root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg
scp -O build_out/stage/bin/httpd build_out/stage/bin/upload.cgi \
    root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg/build_out/stage/bin/
```

Generate the crypt(3) hash on the build machine (e.g. `openssl passwd -1`) and deploy; the device has no `htpasswd`, so plaintext passwords are deliberately unsupported:

```sh
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh
# Optional: TC_ROOT_DIR=... TC_SHARE_DIR=... ./deploy/install.sh
```

`install.sh` sets PATH, guards paths, checks free Flash space and commands, tolerates inactive Samba, detects install vs. update mode, installs binaries/config/shim, writes credentials, inserts the `|| true`-wrapped marker block before the native-manager echo, verifies boot.sh's non-Web lines, starts bozohttpd with `-b -I 8080 -C .cgi ... -X -H -P ...` and checks port 8080.

**Flash is synchronous and slow.** Copying the 656 KiB `httpd` with `cp` took
~20 minutes and could make the device unreachable; the installer therefore
uses `dd bs=64k`, which took ~30 s in the real deployment. Scratch files for
boot.sh rewriting go to the 16 MB RAM tmpfs, never to Flash.

Upload test (from a LAN client):

```sh
curl -u admin:'<password>' -H 'Expect:' -F 'file=@/path/to/test.txt' \
     http://<device-lan-ip>:8080/upload.cgi
# Expect "OK files=1 bytes=..." and the file in SHARE_DIR.
# The -H 'Expect:' header is REQUIRED: bozohttpd replies 417 Expectation
# Failed when curl sends the default "Expect: 100-continue".
```

#### Web management UI (v1.0.4)

Open `http://<device-lan-ip>:8080/` in a browser and pass the Basic auth
dialog. The hidden management homepage is served automatically; the top
toolbar offers **file upload** (multiple files, with a live progress bar),
**new folder**, and refresh. The table below shows top-level entries with
size, UTC mtime, download link, a **delete** button and directory markers,
rendered from `/list.cgi` (JSON) without any CDN.

All selected files are posted in one multipart request; the progress bar
therefore reports the **whole batch** (`req.upload.onprogress`), and the
upload button is disabled until the response arrives.

Endpoints (all behind the same docroot `.htpasswd`):

| URL | Method | Purpose |
| --- | --- | --- |
| `/list.cgi` | GET | JSON list of top-level entries; dotfiles skipped |
| `/mkdir.cgi` | POST `name=...` (form-urlencoded) or GET query | create a folder |
| `/delete.cgi` | POST `name=...` (form-urlencoded) or GET query | delete one top-level file or empty directory |
| `/upload.cgi` | POST multipart | existing streaming uploader |

Names for mkdir/delete accept ASCII `[A-Za-z0-9._-]` **and well-formed UTF-8
multibyte characters** (e.g. `家庭照片`), up to **200 bytes**, no leading dot,
no `/`, `\`, spaces or control characters. `..` is rejected and existing
mkdir names return 409. Malformed UTF-8 (overlong encodings, surrogates,
values above U+10FFFF) is rejected too, so no byte sequence can bypass the
basename checks. `list.cgi` returns raw UTF-8 in a `charset=utf-8` JSON body,
which `JSON.parse` handles directly. Browser `FormData` uploads do not send
`Expect: 100-continue`, so the curl-only `-H 'Expect:'` workaround is not
needed in the web UI.

**Deletion is deliberately narrow and irreversible.** It works only on the
`TC_SHARE_DIR` top level: symlinks are refused, regular files use `unlink()`,
directories use `rmdir()` (empty only, **never recursive**), dotfiles and the
two program files `.htpasswd` / `.tc-webshare-index.html` can never be named,
and the UI asks for confirmation. There is no trash and no undo — keep backups.
Responses: `200 {"ok":true,...}`, `400` bad name, `403` symlink/special file,
`404` missing, `409` directory not empty, `500` other errors.

### 7. Verification checklist

- [ ] `netstat -an | sed -n '/LISTEN/p'` shows 8080 (Samba 139/445/548 normally present)
- [ ] `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/` → 401
- [ ] authenticated GET / → 200 with a directory index, no `.htpasswd` listed
- [ ] POST to `/upload.cgi` → 200 and the file lands in the **resolved** share dir
- [ ] duplicate filenames get `.1` suffixes; bad filenames get 400
- [ ] `boot.sh` contains exactly one marker block, before the `starting native manager` echo, `|| true` wrapped; Samba still starts
- [ ] `state/boot.nonweb` matches the non-marker lines of boot.sh
- [ ] after reboot the boot hook re-mounts the disk via acp and serves from `/Volumes/dk2/share/web`; if acp fails, a loud tmpfs warning is printed
- [ ] TimeCapsuleSMB files are untouched; no tcn marker lines remain after uninstall

### 8. Rollback

```sh
./deploy/uninstall.sh              # keep user data
./deploy/uninstall.sh --purge-data # delete user data too
```

Removes the marker block, verifies boot.sh against the install-time snapshot, stops our httpd by pidfile, deletes only `ROOT_DIR`, and leaves user data and all TimeCapsuleSMB files alone. A second run prints `already clean`.

### 9. Security notes

Plaintext HTTP on a trusted wired LAN only; TLS is out of scope. `upload.c` whitelists `[A-Za-z0-9._-]` basenames, uses `O_EXCL|O_NOFOLLOW`, never overwrites, and serialises uploads with `upload.lock`. `manage.c` applies strict RFC 3629 UTF-8 validation to mkdir/delete names (valid Chinese names are allowed; malformed sequences, controls, separators, `..`, leading dots and >200-byte names are refused), and deletion is limited to a validated top-level basename: `lstat()` rejects symlinks, `rmdir()` refuses non-empty directories, no recursion is performed, and program/dotfiles are unreachable by name. Deletions are permanent. Credentials are supplied as a pre-computed crypt(3) hash; `htpasswd.example` is a placeholder. No plaintext password or credential file is read by this repository.

**v1.0.4 status:** built and tested locally only; not yet deployed to the real device. v1.0.3 remains the version validated on hardware (see below).

### 10. License

GPL-3.0-or-later; see [LICENSE](LICENSE). `build/env.sh` preserves TimeCapsuleSMB's original copyright header. NetBSD / bozohttpd sources are downloaded from official releases at build time and are not redistributed here.

### 11. Release notes — real-device validation (v1.0.2)

**Validated on the real AirPort Time Capsule:**

- `install.sh` completed with `INSTALL OK`; static binaries execute on the device.
- Unauthenticated `GET /` → 401; authenticated GET → 200 with a directory index.
- File upload via `curl -H 'Expect:'` returned success and the file landed on the internal disk (the mounted `/Volumes/dkN` share).
- A request against `.htpasswd` itself returned 403.
- The boot.sh marker block is in place before the final `exec`, and TimeCapsuleSMB / Samba were left untouched.
- `uninstall.sh` restored boot.sh byte-for-byte and preserved user data (verified with the line-exact snapshot).

**Not validated:** no physical power cycle / reboot was performed. Boot-time autostart was exercised by running `boot_hook.sh` directly and confirming idempotence, including its acp disk-mount step.

**Real-device pitfalls fixed in this release:** missing `dirname`/`awk` (removed from deploy scripts), `curl` `Expect: 100-continue` → 417 (`-H 'Expect:'`), slow synchronous Flash writes (`dd bs=64k` instead of `cp`), and boot.sh scratch files moved to RAM tmpfs.

---

<a id="chinese"></a>

## 中文

面向 **AirPort Time Capsule 固件 7.9.1** 的明文 HTTP 文件共享部署包：局域网内浏览/下载/上传，与 TimeCapsuleSMB 干净共存，并支持**字节级可验证回退**。

本仓库只含源码、脚本和文档。构建在 Docker 中完成，**不连接真机、不读写任何凭据文件**。

> **验证状态（诚实声明，v1.0.2 更新）**：构建侧已用 `tc_wb` 卷内工具链/sysroot 编译出 `httpd` 与 `upload.cgi`，并通过 `nbfile` + `objdump -p` 双重静态校验。设备侧：**已完成完整真机部署并验收通过**（INSTALL OK、401/200、上传落盘硬盘、`.htpasswd` 403、回退逐字节还原、Samba 未动）。**未做物理断电重启**：开机自启是通过直接执行 `boot_hook.sh` 并验证幂等（含 acp 挂载）来确认的。详见文末发布说明与 [CHANGELOG.md](CHANGELOG.md)。

### 1. 设备事实与硬约束（真机探测，权威）

| 项目 | 值 |
| --- | --- |
| 固件 / 系统 | 7.9.1 / NetBSD 6.0 evbarm / earmv4（无 Thumb/NEON） |
| 可执行格式 | **仅纯静态 ELF**（Flash 上的 `ld.elf_so` 与我们的二进制无关） |
| 文件系统 | `/` md0a 15MB；`/mnt/Flash` flash2a 2.7MB；`/mnt/Memory` tmpfs 16MB，`/etc/fstab` 仅此三项 |
| 硬盘 | `/dev/ld0` 存在但探测时**未挂载**（`/Volumes/` 为空）；Apple 按需挂成 `/Volumes/dk2` 或 `dk3`，编号每次启动会变，空闲时卸载，**不能从其执行二进制** |
| 开机钩子 | `/mnt/Flash/boot.sh` 属于 **TimeCapsuleSMB**，结尾是 `exec /mnt/Flash/service manager`，写前需 `chmod u+w` |
| TimeCapsuleSMB | 已安装且完整，但 smbd **未运行**、无运行日志——不能作为部署前置条件 |
| 可用命令 | `/bin/sh`、`/bin/ls`、`/usr/bin/sed`、`/bin/df`、`/usr/bin/netstat`、`/usr/bin/tail`、部分 `/usr/bin/find` |
| 可用命令补充 | `/bin/curl`、`/usr/bin/openssl`（可 `dgst -sha256`、`base64 -d`）、`sort/basename/expr/dd/ps` 等 |
| 缺失命令 | `grep`、`head`、`find`、`awk`、**`dirname`**、`tr`、`cut`、`base64`、`sha256sum`、`id`、`mktemp`、`stat`、`readlink`、`tee`、`wget`、`nc`、`mount`、`disklabel`、`file`；**tc-toolbox 未安装** |

缺少 `dirname` 是本次真机部署的实际踩坑：三个部署脚本已改用纯 shell `${0%/*}` 自算目录，不再依赖外部命令。临时文件用 `$$` 后缀并放在 RAM tmpfs（`/mnt/Memory/.tc_webshare_scratch`），因为同步写 Flash 极慢。
| 字长 | 32 位 ⇒ **LFS 必开** |

每个脚本首先设 `PATH=/bin:/sbin:/usr/bin:/usr/sbin`（交互 SSH 缺 `/sbin`）。脚本只用 shell 内建与上述命令，动手前用 `require_cmds` 检查。QA 确认 Samba **正在运行**（139/445/548/22 LISTEN，进程名是 `service`）。旧文档里的性能数字是 thttpd 时代的经验值，**bozohttpd 未重新实测**。

### 2. 为何改用 bozohttpd

`build/build_thttpd.sh` 保留历史文件名，实际编译 **bozohttpd**（NetBSD base httpd）以及 `upload.cgi`、`manage.cgi` 两个静态 CGI：

- 源码就在我们已下载的 NetBSD 源码树里，不再需要外部 thttpd 包；
- 官方编译开关已用真工具链复现：`-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT`；
- CGI、目录索引、Basic auth 功能等价；
- 参数与 thttpd 及旧版文档都不同（已查 `main.c` / `bozohttpd.8`）：`-b` 后台、`-I <port>` 端口（**不是** `-p`，那是 public_html）、docroot 是**位置参数**（`-d` 是 debug）、`-C .cgi <handler>` 后缀映射 CGI、`-X` 索引（默认关）、`-H` 隐藏点文件、`-P <pidfile>`、`-U <user>` 切用户（本包不用）。**没有 `-D` / `-g` 选项。**

**为何用统一分发器**：bozohttpd 的 `-C .cgi` 只能把一个后缀映射到**一个** handler，不能给 upload/list/mkdir/delete 分别配置。改用 `-c <cgibin目录>` 则需要第二份 `.htpasswd`，还会把程序文件混进用户数据目录。因此保留 `-C .cgi`（所有 `.cgi` URL 都在 docroot，受同一份 `.htpasswd` 保护），由 managed Flash `bin/` 中生成的 `/bin/sh` 分发器补回 `TC_SHARE_DIR` / `TC_STATE_DIR`（bozohttpd 会重建 CGI 环境），再按 `SCRIPT_NAME` 路由到三个静态二进制。

管理首页是**程序文件**：主副本放在 managed Flash `etc/index.html`，并把隐藏副本 `<SHARE_DIR>/.tc-webshare-index.html` 发布到 docroot，用 bozohttpd `-x` 作为默认首页；`-H` 让它不出现在自动目录索引里。卸载只精确删除该文件，docroot 中其他文件一律视为用户数据。

### 3. 部署路径策略

- `ROOT_DIR`（二进制/配置/状态）默认 **`/mnt/Flash/.tc_webshare`**，持久且可执行。Flash 只有 2.7MB，安装前用 `df -k` 检查，低于 1024 KiB 直接失败。
- `SHARE_DIR`（用户数据）在安装与每次开机时由 `mount_data_volume()` **主动挂载**：显式 `TC_SHARE_DIR` 优先；否则执行 `/usr/bin/acp rpc diskd.useVolume "path:s:/Volumes/dk2"`（`path:s:` 类型前缀必须带，裸路径会报 `-6742`），轮询 `df -k` 确认后使用 `/Volumes/dk2/share/web`；再尝试 dk3 以容忍编号变化。**只挂载、绝不格式化或改分区**。挂载失败才回退 Flash 上的 `<ROOT_DIR>/data`（持久但空间小，明确告警；Flash 不可用才退到易失的 `/mnt/Memory/.tc_webshare/share`）；dk2 真机已确认约 1.8TB 可用。
- 二进制不放硬盘（会卸载且不能执行），硬盘只放数据。
- boot.sh 带 `set -eu`，结尾是 `echo 'boot: starting native manager'` + `exec /mnt/Flash/service manager`。标记块插在 **echo 之前**并用 `{ ...; } || true` 包裹，避免我们的 hook 非零导致 Samba 起不来；写前 `chmod u+w`、写后 `u-w`。
- 卸载只删标记块，并逐行比对 boot.sh 其余内容与 `state/boot.nonweb`（设备无 `sha256sum`，必要时可用 `openssl dgst`）。数据若位于管理根目录内，默认卸载也会保留，除非 `--purge-data`。
- Samba 当前在运行；即使未监听也仅告警，不阻断部署。TimeCapsuleSMB 文件绝不改动。

### 4. 文件树

（同英文版，新增 `deploy/common.sh`；`deploy/thttpd.conf` 仅为历史说明文件。）

### 5. 构建（本机/Docker，不碰真机）

**`--sysroot` 是必填项**，否则 gcc 会用宿主机头文件/库，产物无法在设备上跑。`tc_wb` 卷里已有：

```
TOOLCHAIN_DIR=/wb-build/tc-earmv4-netbsd7/tools/bin
SYSROOT=/wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm
SRC_ROOT=/wb-build/src
```

```sh
# 原 SDK_DIR 布局
SDK_DIR=/path/to/netbsd-7.2-evbarm-sdk BUILD_OUT=/path/to/stage ./run.sh

# tc_wb 卷布局，离线
VOLUME=tc_wb NO_FETCH=1 \
TOOLCHAIN_DIR=/wb-build/tc-earmv4-netbsd7/tools/bin \
SYSROOT=/wb-build/tc-earmv4-netbsd7/obj/destdir.evbarm \
SRC_ROOT=/wb-build/src BUILD_OUT=/path/to/stage ./run.sh
```

产物 `httpd`、`upload.cgi`、`manage.cgi` 必须全部通过 `nbfile`（含 `statically linked`）与 `objdump -p`（无 `INTERP`/`DYNAMIC`）校验。`fetch_src.sh` 优先 `/wb-build/usr/src`，也会复用卷里的 `/wb-build/src`；两者不一致时明确报错。

静态检查：`for f in run.sh build/*.sh deploy/*.sh; do sh -n "$f" || exit 1; done`

### 6. 部署（设备上执行）

```sh
# sshd 无 SFTP，必须 -O
scp -O -r tc-webshare root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg
scp -O build_out/stage/bin/httpd build_out/stage/bin/upload.cgi \
    root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg/build_out/stage/bin/

# 设备无 htpasswd，必须先在本地（openssl passwd -1）生成 crypt(3) hash
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh
```

`install.sh` 会先设 PATH，再做路径守卫、Flash 剩余空间检查、命令检查；容忍 Samba 未启动；识别首次安装/原地更新；安装二进制、配置与 CGI 垫片；写入凭据；在 `starting native manager` 前插入 `|| true` 包裹的标记块；校验 boot.sh 非 Web 行；以 `-b -I 8080 -C .cgi ... -X -H -P ...` 拉起 bozohttpd 并检查 8080。

**Flash 是同步写入、极慢**：用 `cp` 写 656KB 的 `httpd` 曾耗时约 20 分钟并导致设备失联；安装脚本已改用 `dd bs=64k`，真机实测约 30 秒。boot.sh 的临时文件放在 16MB RAM tmpfs，绝不写 Flash。上传测试必须带 `-H 'Expect:'`，否则 bozohttpd 会因默认 `Expect: 100-continue` 返回 417。

#### 网页管理界面（v1.0.4）

浏览器打开 `http://<设备IP>:8080/` 并通过 Basic auth 后，会自动看到隐藏的管理首页：顶部工具栏提供**多文件上传**（带实时进度条）、**新建文件夹**、刷新；下方表格显示顶层文件名、大小、UTC 修改时间、下载链接、**删除**按钮与目录标记，由 `/list.cgi`（JSON）渲染，完全离线、无外部 CDN。

所选多个文件仍一次性 POST，因此进度条显示**整批**上传进度（`req.upload.onprogress`），上传期间禁用上传按钮，完成或失败后自动隐藏。

接口（均受 docroot 同一份 `.htpasswd` 保护）：

| URL | 方法 | 用途 |
| --- | --- | --- |
| `/list.cgi` | GET | 顶层条目 JSON 列表，跳过所有点文件 |
| `/mkdir.cgi` | POST 表单 `name=...` 或 GET query | 新建文件夹 |
| `/delete.cgi` | POST 表单 `name=...` 或 GET query | 删除一个顶层文件或空目录 |
| `/upload.cgi` | POST multipart | 原有流式上传 |

新建/删除的名称接受 ASCII `[A-Za-z0-9._-]` **以及合法 UTF-8 多字节字符**（如 `家庭照片`），最长 **200 字节**；不允许前导点、斜杠、反斜杠、空格及控制字符，`..` 被拒绝，重名建文件夹返回 409。畸形 UTF-8（overlong、代理区、超出 U+10FFFF）同样拒绝，任何字节序列都无法绕过 basename 检查。`list.cgi` 以 `charset=utf-8` 返回原始 UTF-8 JSON，`JSON.parse` 可直接解析。浏览器 `FormData` 不会发送 `Expect: 100-continue`，因此网页上传不需要 curl 的 `-H 'Expect:'` 补丁。

**删除范围刻意收窄且不可恢复**：仅作用于 `TC_SHARE_DIR` 顶层；拒绝符号链接；普通文件用 `unlink()`，目录只用 `rmdir()`（**仅空目录，绝不递归**）；点文件与 `.htpasswd` / `.tc-webshare-index.html` 两个程序文件无法被命名；界面会二次确认。没有回收站、没有撤销，重要数据请自行备份。返回码：`200 {"ok":true,...}`、`400` 非法名、`403` 软链/特殊文件、`404` 不存在、`409` 目录非空、`500` 其他错误。

### 7. 验证清单 / 8. 回退 / 9. 安全 / 10. 许可

见英文版对应章节：重点确认 8080 LISTEN、401 认证、`/upload.cgi` 上传落点（curl 必须加 `-H 'Expect:'`）、标记块在 `starting native manager` 之前且带 `|| true`、`state/boot.nonweb` 一致、开机后 boot hook 通过 acp 重新挂载硬盘并继续使用 `/Volumes/dk2/share/web`（失败时明确告警并回退 Flash 小容量数据目录）、TimeCapsuleSMB 未被改动。`./deploy/uninstall.sh` 默认保留用户数据（包括在管理目录内的回退数据），`--purge-data` 才删除。仅可信有线 LAN 使用明文 HTTP；凭据只以预生成 hash 传入；`manage.c` 对新建/删除名称执行严格 RFC 3629 UTF-8 校验（合法中文放行，畸形序列、控制字符、分隔符、`..`、前导点、超 200 字节拒绝）；删除仅限合法顶层 basename：`lstat()` 拒绝软链、`rmdir()` 拒绝非空目录、不递归、程序文件与点文件不可命名，且删除不可撤销。GPL-3.0-or-later。

**v1.0.4 状态**：仅在本机构建与测试，**尚未真机部署**；硬件上已验证的版本仍是 v1.0.3（见下）。

### 11. 发布说明 — 真机验证结果（v1.0.2）

**已在真机验证通过**：`install.sh` 完整执行并返回 INSTALL OK；未认证 `GET /` → 401、认证后 → 200 且可见目录索引；带 `-H 'Expect:'` 的 curl 上传成功且文件落在已挂载硬盘的共享目录；直接请求 `.htpasswd` → 403；boot.sh 标记块位于最终 `exec` 之前且 TimeCapsuleSMB / Samba 未被改动；`uninstall.sh` 逐字节还原 boot.sh 并保留用户数据。

**未验证**：没有做物理断电重启。开机自启通过直接执行 `boot_hook.sh`（含 acp 挂载步骤）并确认幂等来验证。

**本版修复的真机踩坑**：设备缺 `dirname`/`awk`（脚本改为纯 shell 实现）、curl 默认 `Expect: 100-continue` 导致 417（加 `-H 'Expect:'`）、同步 Flash 写盘过慢（`cp` 改 `dd bs=64k`）、boot.sh 临时文件改放 RAM tmpfs。
