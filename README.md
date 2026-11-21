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
| Commands present | `/bin/sh`, `/bin/ls`, `/usr/bin/sed`, `/bin/df`, `/usr/bin/netstat`, `/usr/bin/tail`, partial `/usr/bin/find` |
| Commands absent | `grep`, `head`, `mount`, `disklabel`, `file`; **tc-toolbox is not installed** |
| Word size | 32-bit ⇒ **LFS mandatory**: `-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE` |

The deployment scripts use only shell builtins plus the commands above and ordinary `mkdir`/`cp`/`rm`/`chmod`/`sleep`/`cat`/`kill`; `install.sh` checks them with `require_cmds` before touching any path.

Performance figures from the earlier design (15–25 MB/s downloads, 8–15 MB/s uploads, ≤500 MB safe per file, concurrency lock = 1) are **estimates inherited from the thttpd design and have not been re-measured with bozohttpd**.

### 2. Why bozohttpd instead of thttpd

`build/build_thttpd.sh` keeps its historical filename but compiles **bozohttpd**, the NetBSD base HTTP server:

- its source ships inside the NetBSD source tree we already fetch, so no external thttpd tarball is needed;
- the compile switches are documented upstream (`-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT`) and were reproduced with the real toolchain;
- it provides the same required features: CGI, directory index, HTTP Basic auth;
- the exact CLI differs from thttpd and from older bozohttpd releases. Verified against `main.c` / `bozohttpd.8`: `-b` daemonise, `-I <port>` listen port (**not** `-p`, which is `public_html`), `-c <dir>` CGI directory, `-X` index, `-H` hide dotfiles, `-P <pidfile>` PID file, positional slashdir.

```
Browser (LAN) --HTTP :8080--> bozohttpd (static ELF, slashdir=<SHARE_DIR>)
                               |-- GET /                    -> .htpasswd 401 / index / download
                               `-- POST /cgi-bin/upload.cgi -> <WEB_ROOT>/cgi-bin/upload.cgi
                                                               (sh shim -> static upload.bin)
                                                               -> upload.lock (O_EXCL, concurrency=1)
                                                               -> <SHARE_DIR>/<basename>
```

bozohttpd **rebuilds the CGI environment from scratch** and drops custom variables, so `upload.c`'s `TC_SHARE_DIR` / `TC_STATE_DIR` cannot simply be exported by the boot hook. A generated `/bin/sh` shim at `/cgi-bin/upload.cgi` re-supplies those two variables and `exec`s the static `upload.bin`. bozohttpd also resolves `.htpasswd` relative to the request directory and does **not** recurse, so links are installed in the web root *and* in `cgi-bin/`.

### 3. Deployment path strategy

- `ROOT_DIR` (binaries, config, state, manifest) defaults to **`/mnt/Flash/.tc_webshare`** — persistent and executable. Flash is only 2.7 MB; `install.sh` aborts if `df -k /mnt/Flash` reports under 1024 KiB free. Override with `TC_ROOT_DIR`.
- `SHARE_DIR` (user data) is resolved **at install and again at every boot**: first explicit `TC_SHARE_DIR`; else the first writable `/Volumes/dkN` whose filesystem differs from `/Volumes`; else `/mnt/Memory/.tc_webshare/share` (tmpfs, volatile — a warning is printed). **No dkN number is ever hardcoded.**
- Binaries never go on the disk (it unmounts on idle and cannot execute ELF); only data does.
- The boot block is inserted **before** TimeCapsuleSMB's final `exec /mnt/Flash/service manager` line — appending after it would never run. Uninstall removes only the two marker lines and their contents and compares the rest of boot.sh line-for-line against `state/boot.nonweb` (no `sha256sum` on the device).
- Stopped Samba (139/445 silent) is only a warning; it is no longer a deployment blocker. TimeCapsuleSMB's files are never modified.

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

Generate the hash on the build machine and deploy (the device has no `htpasswd`/`openssl`, so plaintext passwords are deliberately unsupported):

```sh
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh
# Optional: TC_ROOT_DIR=... TC_SHARE_DIR=... ./deploy/install.sh
```

`install.sh` guards paths, checks free Flash space, checks commands, tolerates inactive Samba, detects install vs. update mode, installs binaries/config/shim, writes credentials, inserts the marker block before the SMB `exec`, verifies boot.sh's non-Web lines, starts bozohttpd and checks port 8080.

Upload test (from a LAN client):

```sh
curl -u admin:'<password>' -F 'file=@/path/to/test.txt' \
     http://<device-lan-ip>:8080/cgi-bin/upload.cgi
# Expect "OK files=1 bytes=..." and the file in SHARE_DIR
```

### 7. Verification checklist

- [ ] `netstat -an | tail -40` shows 8080 LISTEN (Samba 139/445 may be absent)
- [ ] `wget -S -O /dev/null http://127.0.0.1:8080/` → 401 (if a client exists)
- [ ] authenticated GET / → 200 with a directory index, no `.htpasswd` listed
- [ ] upload returns 200 and the file lands in the **resolved** share dir
- [ ] duplicate filenames get `.1` suffixes; bad filenames get 400
- [ ] `boot.sh` contains exactly one marker block, placed before the `exec` line
- [ ] `state/boot.nonweb` matches the non-marker lines of boot.sh
- [ ] after unmounting the disk, the boot hook still starts using the tmpfs fallback
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
| 缺失命令 | `grep`、`head`、`mount`、`disklabel`、`file`；**tc-toolbox 未安装** |
| 字长 | 32 位 ⇒ **LFS 必开** |

部署脚本只用 shell 内建 + 上述命令 + `mkdir/cp/rm/chmod/sleep/cat/kill`，并在动手前用 `require_cmds` 检查。旧文档里的性能数字是 thttpd 时代的经验值，**bozohttpd 未重新实测**。

### 2. 为何改用 bozohttpd

`build/build_thttpd.sh` 保留历史文件名，实际编译 **bozohttpd**（NetBSD base httpd）：

- 源码就在我们已下载的 NetBSD 源码树里，不再需要外部 thttpd 包；
- 官方编译开关已用真工具链复现：`-DDO_HTPASSWD -DNO_SSL_SUPPORT -DNO_LUA_SUPPORT`；
- CGI、目录索引、Basic auth 功能等价；
- 参数与 thttpd 及旧版文档都不同（已查 `main.c` / `bozohttpd.8`）：`-b` 后台、`-I <port>` 端口（**不是** `-p`，那是 public_html）、`-c <dir>` CGI 目录、`-X` 索引、`-H` 隐藏点文件、`-P <pidfile>`、位置参数为站点根目录。

bozohttpd 会**重建 CGI 环境**，自定义变量全部丢失，所以 `upload.c` 依赖的 `TC_SHARE_DIR` / `TC_STATE_DIR` 由生成的 `/bin/sh` 垫片在 `/cgi-bin/upload.cgi` 处补上再 `exec` 静态 `upload.bin`。`.htpasswd` 按请求目录查找且不递归，因此站点根目录和 `cgi-bin/` 都要放链接。

### 3. 部署路径策略

- `ROOT_DIR`（二进制/配置/状态）默认 **`/mnt/Flash/.tc_webshare`**，持久且可执行。Flash 只有 2.7MB，安装前用 `df -k` 检查，低于 1024 KiB 直接失败。
- `SHARE_DIR`（用户数据）在安装与每次开机时**动态解析**：显式 `TC_SHARE_DIR` > 第一个已挂载且可写的 `/Volumes/dkN` > `/mnt/Memory/.tc_webshare/share`（tmpfs，易失，会告警）。**绝不硬编码 dkN 编号。**
- 二进制不放硬盘（会卸载且不能执行），硬盘只放数据。
- boot 标记块插在 TimeCapsuleSMB 的 `exec /mnt/Flash/service manager` **之前**；卸载只删标记块，并逐行比对 boot.sh 其余内容与 `state/boot.nonweb`（设备无 `sha256sum`）。
- Samba 未启动仅告警，不再是部署阻断条件；TimeCapsuleSMB 文件绝不改动。

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

# 设备无 htpasswd/openssl，必须先在本地生成 crypt(3) hash
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh
```

`install.sh` 会做路径守卫、Flash 剩余空间检查、命令检查；容忍 Samba 未启动；识别首次安装/原地更新；安装二进制、配置与 CGI 垫片；写入凭据；在 SMB `exec` 前插入标记块；校验 boot.sh 非 Web 行；拉起 bozohttpd 并检查 8080。

### 7. 验证清单 / 8. 回退 / 9. 安全 / 10. 许可

见英文版对应章节：重点确认 8080 LISTEN、401 认证、上传落点、标记块位置、`state/boot.nonweb` 一致、硬盘卸载后 tmpfs 回退仍可用、TimeCapsuleSMB 未被改动。`./deploy/uninstall.sh` 默认保留用户数据，`--purge-data` 才删除。仅可信有线 LAN 使用明文 HTTP；凭据只以预生成 hash 传入；GPL-3.0-or-later。
