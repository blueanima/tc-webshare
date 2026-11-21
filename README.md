# tc-webshare — Static HTTP File Share for Apple AirPort Time Capsule / Apple AirPort Time Capsule 静态 HTTP 文件共享部署包

[中文](#chinese) | [English](#english)

---

<a id="english"></a>

## English

A plaintext HTTP file-sharing kit for **AirPort Time Capsule firmware 7.9.1**: browse, download and upload files on the LAN, coexist cleanly with the device's TimeCapsuleSMB installation, and roll back **with byte-level verification**.

This repository contains source, scripts and documentation only. All builds happen inside Docker; **no network device is contacted, no ssh/scp to real hardware is performed, and no credential file is read**.

> **Verification status — honest disclosure (updated in v1.0.1).** Build-side: the cross toolchain, sysroot and NetBSD source tree in the `tc_wb` Docker volume were used to compile `httpd` and `upload.cgi`, and both artifacts were checked with `nbfile` and `objdump -p` (pure static ARM ELF). Device-side: the lead verified that these statically linked earmv4 ELF binaries **execute on the real Time Capsule** (no `Exec format error`). **A complete on-device deployment / HTTP / authentication / reboot / rollback run has NOT been performed.** See [CHANGELOG.md](CHANGELOG.md).

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
| Commands absent | `grep`, `head`, `find`, `awk`, `tr`, `cut`, `base64`, `sha256sum`, `id`, `mktemp`, `stat`, `readlink`, `tee`, `wget`, `nc`, `mount`, `disklabel`, `file`; **tc-toolbox is not installed** |
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
                               |-- GET /                    -> .htpasswd 401 / index / download
                               `-- POST /upload.cgi (-C .cgi -> <WEB_ROOT>/bin/upload_shim)
                                                               -> static upload.bin
                                                               -> upload.lock (O_EXCL, concurrency=1)
                                                               -> <SHARE_DIR>/<basename>
```

bozohttpd **rebuilds the CGI environment from scratch** and drops custom variables, so `upload.c`'s `TC_SHARE_DIR` / `TC_STATE_DIR` cannot simply be exported by the boot hook. A generated `/bin/sh` shim in managed Flash `bin/` re-supplies those two variables and `exec`s the static `upload.bin`. `.htpasswd` is not recursive; using `-C .cgi` keeps the `/upload.cgi` request inside the docroot, so **one** `.htpasswd` link in the docroot protects both GET and POST.

### 3. Deployment path strategy

- `ROOT_DIR` (binaries, config, state, manifest) defaults to **`/mnt/Flash/.tc_webshare`** — persistent and executable. Flash is only 2.7 MB; `install.sh` aborts if `df -k /mnt/Flash` reports under 1024 KiB free. Override with `TC_ROOT_DIR`.
- `SHARE_DIR` (user data) is resolved **at install and again at every boot** by `detect_data_root()`: first explicit `TC_SHARE_DIR`; else the first writable `/Volumes/dkN` whose filesystem differs from `/Volumes` (via `ls` + `df`); else `<ROOT_DIR>/data` on Flash. **No dkN number is ever hardcoded**, and we never force a mount: Apple mounts the disk only when a client touches the share. The Flash fallback is small (the two binaries already use ~844 KiB); keep uploads small while the disk is unmounted.
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
│   └── build_thttpd.sh        historical name; builds bozohttpd -> httpd + upload.cgi
├── src/upload.c               streaming multipart upload CGI (unchanged)
├── deploy/
│   ├── common.sh              dependency-light on-device helpers
│   ├── install.sh / uninstall.sh
│   ├── boot_hook.sh           starts bozohttpd with verified flags
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
scp -O build_out/bin/httpd build_out/bin/upload.cgi \
    root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg/build_out/bin/
```

Generate the crypt(3) hash on the build machine (e.g. `openssl passwd -1`) and deploy; the device has no `htpasswd`, so plaintext passwords are deliberately unsupported:

```sh
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh
# Optional: TC_ROOT_DIR=... TC_SHARE_DIR=... ./deploy/install.sh
```

`install.sh` sets PATH, guards paths, checks free Flash space and commands, tolerates inactive Samba, detects install vs. update mode, installs binaries/config/shim, writes credentials, inserts the `|| true`-wrapped marker block before the native-manager echo, verifies boot.sh's non-Web lines, starts bozohttpd with `-b -I 8080 -C .cgi ... -X -H -P ...` and checks port 8080.

Upload test (from a LAN client):

```sh
curl -u admin:'<password>' -F 'file=@/path/to/test.txt' \
     http://<device-lan-ip>:8080/upload.cgi
# Expect "OK files=1 bytes=..." and the file in SHARE_DIR
```

### 7. Verification checklist

- [ ] `netstat -an | sed -n '/LISTEN/p'` shows 8080 (Samba 139/445/548 normally present)
- [ ] `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/` → 401
- [ ] authenticated GET / → 200 with a directory index, no `.htpasswd` listed
- [ ] POST to `/upload.cgi` → 200 and the file lands in the **resolved** share dir
- [ ] duplicate filenames get `.1` suffixes; bad filenames get 400
- [ ] `boot.sh` contains exactly one marker block, before the `starting native manager` echo, `|| true` wrapped; Samba still starts
- [ ] `state/boot.nonweb` matches the non-marker lines of boot.sh
- [ ] after the disk unmounts, the boot hook still starts using the Flash `data/` fallback
- [ ] TimeCapsuleSMB files are untouched; no tcn marker lines remain after uninstall

### 8. Rollback

```sh
./deploy/uninstall.sh              # keep user data
./deploy/uninstall.sh --purge-data # delete user data too
```

Removes the marker block, verifies boot.sh against the install-time snapshot, stops our httpd by pidfile, deletes only `ROOT_DIR`, and leaves user data and all TimeCapsuleSMB files alone. A second run prints `already clean`.

### 9. Security notes

Plaintext HTTP on a trusted wired LAN only; TLS is out of scope. `upload.c` whitelists `[A-Za-z0-9._-]` basenames, uses `O_EXCL|O_NOFOLLOW`, never overwrites, and serialises uploads with `upload.lock`. Credentials are supplied as a pre-computed crypt(3) hash; `htpasswd.example` is a placeholder. No plaintext password or credential file is read by this repository.

### 10. License

GPL-3.0-or-later; see [LICENSE](LICENSE). `build/env.sh` preserves TimeCapsuleSMB's original copyright header. NetBSD / bozohttpd sources are downloaded from official releases at build time and are not redistributed here.

---

<a id="chinese"></a>

## 中文

面向 **AirPort Time Capsule 固件 7.9.1** 的明文 HTTP 文件共享部署包：局域网内浏览/下载/上传，与 TimeCapsuleSMB 干净共存，并支持**字节级可验证回退**。

本仓库只含源码、脚本和文档。构建在 Docker 中完成，**不连接真机、不读写任何凭据文件**。

> **验证状态（诚实声明，v1.0.1 更新）**：构建侧已用 `tc_wb` 卷内的工具链、sysroot 与 NetBSD 源码实际编译出 `httpd` 与 `upload.cgi`，并用 `nbfile` 和 `objdump -p` 双重校验为纯静态 ARM ELF。设备侧：lead 已实测这两个静态 ELF **能在真机执行**（无 `Exec format error`）。**但尚未做完整的真机部署 / HTTP / 认证 / 重启 / 回退验证。** 详见 [CHANGELOG.md](CHANGELOG.md)。

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
| 缺失命令 | `grep`、`head`、`find`、`awk`、`tr`、`cut`、`base64`、`sha256sum`、`id`、`mktemp`、`stat`、`readlink`、`tee`、`wget`、`nc`、`mount`、`disklabel`、`file`；**tc-toolbox 未安装** |
| 字长 | 32 位 ⇒ **LFS 必开** |

每个脚本首先设 `PATH=/bin:/sbin:/usr/bin:/usr/sbin`（交互 SSH 缺 `/sbin`）。脚本只用 shell 内建与上述命令，动手前用 `require_cmds` 检查。QA 确认 Samba **正在运行**（139/445/548/22 LISTEN，进程名是 `service`）。旧文档里的性能数字是 thttpd 时代的经验值，**bozohttpd 未重新实测**。

### 2. 为何改用 bozohttpd

`build/build_thttpd.sh` 保留历史文件名，实际编译 **bozohttpd**（NetBSD base httpd）：

- 源码就在我们已下载的 NetBSD 源码树里，不再需要外部 thttpd 包；
- 官方编译开关已用真工具链复现：`-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT`；
- CGI、目录索引、Basic auth 功能等价；
- 参数与 thttpd 及旧版文档都不同（已查 `main.c` / `bozohttpd.8`）：`-b` 后台、`-I <port>` 端口（**不是** `-p`，那是 public_html）、docroot 是**位置参数**（`-d` 是 debug）、`-C .cgi <handler>` 后缀映射 CGI、`-X` 索引（默认关）、`-H` 隐藏点文件、`-P <pidfile>`、`-U <user>` 切用户（本包不用）。**没有 `-D` / `-g` 选项。**

bozohttpd 会**重建 CGI 环境**，自定义变量全部丢失，所以 `upload.c` 依赖的 `TC_SHARE_DIR` / `TC_STATE_DIR` 由 managed Flash `bin/` 里的 `/bin/sh` 垫片补上再 `exec` 静态 `upload.bin`。`.htpasswd` 不递归；用 `-C .cgi` 让 `/upload.cgi` 请求落在 docroot，因此**一份** docroot `.htpasswd` 同时保护 GET 与 POST。

### 3. 部署路径策略

- `ROOT_DIR`（二进制/配置/状态）默认 **`/mnt/Flash/.tc_webshare`**，持久且可执行。Flash 只有 2.7MB，安装前用 `df -k` 检查，低于 1024 KiB 直接失败。
- `SHARE_DIR`（用户数据）由 `detect_data_root()` 在安装与每次开机时**动态解析**：显式 `TC_SHARE_DIR` > 第一个已挂载且可写的 `/Volumes/dkN`（`ls` + `df` 判定）> `<ROOT_DIR>/data`（Flash）。**绝不硬编码 dkN 编号，也不主动触发挂载**（Apple 只在客户端访问共享时挂盘）。Flash 回退空间很小，硬盘未挂载时请控制上传体积。
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

产物 `httpd`、`upload.cgi` 必须同时通过 `nbfile`（含 `statically linked`）与 `objdump -p`（无 `INTERP`/`DYNAMIC`）校验。`fetch_src.sh` 优先 `/wb-build/usr/src`，也会复用卷里的 `/wb-build/src`；两者不一致时明确报错。

静态检查：`for f in run.sh build/*.sh deploy/*.sh; do sh -n "$f" || exit 1; done`

### 6. 部署（设备上执行）

```sh
# sshd 无 SFTP，必须 -O
scp -O -r tc-webshare root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg
scp -O build_out/bin/httpd build_out/bin/upload.cgi \
    root@<TC-LAN-IP>:/mnt/Flash/.tc_webshare_pkg/build_out/bin/

# 设备无 htpasswd，必须先在本地（openssl passwd -1）生成 crypt(3) hash
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh
```

`install.sh` 会先设 PATH，再做路径守卫、Flash 剩余空间检查、命令检查；容忍 Samba 未启动；识别首次安装/原地更新；安装二进制、配置与 CGI 垫片；写入凭据；在 `starting native manager` 前插入 `|| true` 包裹的标记块；校验 boot.sh 非 Web 行；以 `-b -I 8080 -C .cgi ... -X -H -P ...` 拉起 bozohttpd 并检查 8080。

### 7. 验证清单 / 8. 回退 / 9. 安全 / 10. 许可

见英文版对应章节：重点确认 8080 LISTEN、401 认证、`/upload.cgi` 上传落点、标记块在 `starting native manager` 之前且带 `|| true`、`state/boot.nonweb` 一致、硬盘卸载后 Flash `data/` 回退仍可用、TimeCapsuleSMB 未被改动。`./deploy/uninstall.sh` 默认保留用户数据（包括在管理目录内的回退数据），`--purge-data` 才删除。仅可信有线 LAN 使用明文 HTTP；凭据只以预生成 hash 传入；GPL-3.0-or-later。
