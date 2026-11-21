# tc-webshare — Static HTTP File Share for Apple AirPort Time Capsule / Apple AirPort Time Capsule 静态 HTTP 文件共享部署包

[中文](#chinese) | [English](#english)

---

<a id="english"></a>

## English

A plaintext HTTP file-sharing kit for **AirPort Time Capsule firmware 7.9.1**: browse, download and upload files on the LAN, coexist cleanly with the device's existing tc-toolbox and TimeCapsuleSMB Samba, and roll back **with byte-level verification**.

This repository contains source, scripts and documentation only. All builds happen inside Docker; **no network device is contacted, no ssh/scp to real hardware is performed, and no credential file is read**.

> **Verification status — honest disclosure.** This release was validated locally only: gcc syntax checks, POSIX `sh -n` parsing, `upload.c` functional-safety stub tests (10/10), and idempotent rollback stub rehearsals. **It has never been tested on real NetBSD 6 hardware and no real device was ever connected.** See [CHANGELOG.md](CHANGELOG.md) for the full record.

### 1. Device Facts and Hard Constraints (architect final)

| Item | Value |
| --- | --- |
| Firmware | Apple AirPort Time Capsule 7.9.1 |
| Kernel / architecture | NetBSD 6.0 / evbarm / earmv4 (ARMv4, **no Thumb / NEON**) |
| Executable format | **Pure static ELF only** (no dynamic linker) |
| Disk mount point | `/Volumes/dk2` |
| Root filesystem | Reset on every reboot |
| Boot hook | `/mnt/Flash/boot.sh` (read-only from the factory; `chmod u+w` before writing, `chmod u-w` afterwards) |
| Must be preserved | `/Volumes/dk2/.tc_tools/bin/` (53 static tools), `/Volumes/dk2/.samba4/` (Samba, 139/445) |
| Transfer method | sshd has no SFTP; use `scp -O` |
| In-place `sed` | NetBSD syntax must be `sed -i ""` |
| Shell | Every script is POSIX `#!/bin/sh` (bash is not guaranteed on the device) |

The word size is 32-bit, so **LFS is mandatory**: cross-compilation must include `-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE`, otherwise the 32-bit `off_t` overflows at 2 GB.

#### Device performance limits (measured / empirical, not guaranteed)

- Download (thttpd, zero-fork server): typically **15–25 MB/s**
- Upload (CGI streaming to disk): typically **8–15 MB/s**
- Safe per-file ceiling **≤ 500 MB**; practical ceiling **1–2 GB** (limited by fragmentation and the 32-bit process address space)
- Concurrent upload lock **= 1**: only one multipart upload at a time; duplicate requests receive `503`
- HTTP concurrency `maxconns=10`

### 2. Architecture

```
Browser (LAN)  --HTTP :8080-->  thttpd (static ELF, dir=/Volumes/dk2/share/web)
                                  |-- GET /            -> Basic auth (401 / 200)
                                  |                    -> directory index / file download (zero fork)
                                  `-- POST /cgi-bin/upload.cgi
                                          -> static C CGI, 64KB streaming write
                                          -> upload.lock (O_EXCL, concurrency=1)
                                          -> /Volumes/dk2/share/web/<basename>
```

- **Downloads / indexing** are served directly by thttpd without forking a process per request.
- **Uploads** are handled by the static CGI built from `src/upload.c`: the multipart boundary is scanned block by block, at most 64 KiB is written per call, and a whole file is never buffered in memory.
- All web artifacts live under `/Volumes/dk2/.tc_webshare/` (the **rollback boundary**); user uploads live in `/Volumes/dk2/share/web/` and are preserved by a default rollback.
- Only one marker block is inserted into `/mnt/Flash/boot.sh`; the file is **never rewritten wholesale**:

```
# >>> TC_WEBSHARE BEGIN >>>
# tc-webshare: LAN-only HTTP share; managed block, do not edit by hand.
if [ -x /Volumes/dk2/.tc_webshare/bin/boot_hook.sh ]; then
    /Volumes/dk2/.tc_webshare/bin/boot_hook.sh >/dev/null 2>&1
fi
# <<< TC_WEBSHARE END <<<
```

Uninstall deletes only the lines between and including the two markers, then uses static `sha256sum` to compare the checksum of the "non-Web lines" against the value recorded in `state/manifest`.

### 3. File Tree

```
tc-webshare/
├── README.md                 this file (EN + 中文)
├── CHANGELOG.md               release history, verification scope and honest limitations
├── LICENSE                    GPL-3.0-or-later full text
├── .gitignore                 excludes build/staging/QA/credential artifacts
├── Dockerfile                 debian:bookworm cross-build env, case-sensitive volume /wb-build
├── run.sh                     docker build + volume + build (EXTRA and other switches)
├── build/
│   ├── env.sh                 NetBSD 7.2_STABLE cross env (from TimeCapsuleSMB, GPL header kept)
│   ├── fetch_src.sh           idempotent download/unpack of NetBSD 7.2 sources into /wb-build
│   └── build_thttpd.sh        static build of thttpd + upload.cgi, objdump check for INTERP/DYNAMIC
├── src/
│   └── upload.c               streaming multipart upload CGI (LFS, filename whitelist, O_EXCL lock)
├── deploy/
│   ├── install.sh             idempotent deployment + verification report
│   ├── uninstall.sh           idempotent rollback (user data kept by default)
│   ├── boot_hook.sh           idempotent thttpd starter at boot
│   ├── thttpd.conf            configuration template
│   └── htpasswd.example       example credentials (placeholder, not a real password)
└── docs/
    └── device-layout.md       on-device directory layout and file ownership
```

### 4. Build (local / Docker, no hardware involved)

Prerequisites: Docker on the build machine plus a **NetBSD 7.2_STABLE evbarm/earmv4 cross toolchain** (triplet `armv4--netbsdelf-eabi`). If the toolchain is unavailable the scripts remain reproducible but cannot produce binaries in that environment.

```sh
# 1) Build the image and run the cross build (BSD/macOS/Linux)
SDK_DIR=/path/to/netbsd-7.2-evbarm-sdk \
BUILD_OUT=/path/to/output/stage \
./run.sh

# 2) Artifacts (pure static ELF)
ls "$BUILD_OUT/bin"
# thttpd  upload.cgi  ../build-info

# 3) Force rebuild / reuse cached sources offline / append docker arguments
NO_CACHE=1 ./run.sh
NO_FETCH=1 ./run.sh
EXTRA='-e TC_ENV_QUIET=0' ./run.sh
```

`run.sh` creates the Docker named volume `tc-webshare-wb-build` as `/wb-build` to avoid build failures caused by the case-insensitive default of macOS APFS when unpacking the NetBSD source tree. Main flags used by `build_thttpd.sh`:

```
-O2 -g0 -static -fno-pic -fno-PIE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE
```

Every artifact is checked with `objdump -p`: the build fails if an `INTERP` or `DYNAMIC` section is present.

#### Local static checks (no cross toolchain needed)

```sh
# POSIX sh only parses the FIRST file passed to "sh -n", so loop over all 7.
for f in run.sh build/env.sh build/fetch_src.sh build/build_thttpd.sh \
         deploy/install.sh deploy/uninstall.sh deploy/boot_hook.sh; do
    sh -n "$f" || exit 1
done
gcc -fsyntax-only -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE src/upload.c
```

### 5. Deployment (run on the device)

Copy the whole package and the build artifacts to the device, for example:

```sh
# Push from the build machine (sshd has no SFTP, so -O is required)
scp -O -r tc-webshare root@<TC-LAN-IP>:/Volumes/dk2/.tc_webshare_pkg
# Create build_out/bin on the device first, then push the artifacts
scp -O build_out/bin/thttpd build_out/bin/upload.cgi \
    root@<TC-LAN-IP>:/Volumes/dk2/.tc_webshare_pkg/build_out/bin/
```

On the device:

```sh
cd /Volumes/dk2/.tc_webshare_pkg

# Recommended: generate a crypt(3) hash locally and pass it via the environment (no plaintext on disk)
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh

# Or: let install.sh generate a one-time random password on the device and print it once
./deploy/install.sh
```

`install.sh` will:

1. Preflight: apply path guards first (reject `/`, `$HOME`, `/Volumes` and other dangerous paths), then check `uname`, the `/Volumes/dk2` mount, Samba listening on 139/445, the presence of `boot.sh`, and the static tool inventory. **Detect the marker block first**: an existing installation switches to in-place update mode; a fresh install is refused only if port 8080 is occupied.
2. In update mode, gracefully stop **its own** thttpd by pidfile (verifying process ownership with `ps`; never kill a foreign process), confirm port 8080 is free, then overwrite binaries to avoid ETXTBSY.
3. Create `.tc_webshare/{bin,etc,state}` and `share/web/`, then install binaries, configuration and credentials.
4. Write `state/manifest`: all installed paths, boot.sh SHA-256 before and after installation, and a timestamp.
5. Insert the marker block idempotently (skip if present); the checksum of the non-Web lines of `boot.sh` must be identical before and after.
6. Call `boot_hook.sh` once immediately using absolute paths (the marker block only takes effect at boot).
7. Verify port 8080 is listening and perform one GET: expect `401 Unauthorized` (proving Basic auth is enforced).
8. Re-running needs no prior stop: it prints `already installed: updated in place`, updates files/manifest in place and restarts thttpd automatically; it never inserts a second marker block and the non-Web lines stay byte-identical. If the PID in the pidfile is not our thttpd but holds port 8080, the script fails explicitly to avoid killing someone else's process.

Upload test (requires Basic auth):

```sh
curl -u admin:'<password>' -F 'file=@/path/to/test.txt' \
     http://<device-lan-ip>:8080/cgi-bin/upload.cgi
# Expected: 200 + "OK files=1 bytes=..."; the file lands in /Volumes/dk2/share/web/
```

### 6. Verification Checklist

Confirm each item after deployment:

- [ ] `netstat -an | grep LISTEN` shows 8080, 139 and 445 all listening
- [ ] `wget -S -O /dev/null http://127.0.0.1:8080/` returns **401**
- [ ] `curl -u <user>:<pass> http://127.0.0.1:8080/` returns 200 with a directory index
- [ ] Uploading a small file returns 200 and the file appears in `/Volumes/dk2/share/web/`
- [ ] Uploading the same filename yields `.1`, `.2` suffixes and **never overwrites** the original
- [ ] Invalid filenames such as `../x`, `/etc/passwd`, `a\b` are rejected with 400
- [ ] With two concurrent uploads, the second returns 503 (concurrency lock = 1)
- [ ] `sha256sum` of boot.sh with the marker block filtered out equals the value in `state/manifest`
- [ ] `/Volumes/dk2/.tc_tools/bin` still holds ≥ 50 files; `.samba4/` is still present
- [ ] Port 8080 comes back automatically after a device reboot (boot.sh marker block works)

### 7. Rollback

```sh
cd /Volumes/dk2/.tc_webshare_pkg
./deploy/uninstall.sh              # keep /Volumes/dk2/share/web user data
./deploy/uninstall.sh --purge-data # delete user data only when explicitly required
```

`uninstall.sh` will:

1. Stop thttpd by pidfile and confirm port 8080 is closed.
2. Use `sed -i ""` to delete only the lines between and including the two markers in boot.sh; verify the non-Web SHA-256 against the manifest.
3. Remove only `/Volumes/dk2/.tc_webshare/`; user data is preserved by default.
4. Verify: port 8080 closed; 139/445 still listening; `.tc_tools/bin` intact; `.samba4/` and the share root accessible; no marker block in boot.sh and checksum unchanged.
5. Re-running after uninstall prints `already clean` and exits successfully.

### 8. Security Notes

- This release is **plaintext HTTP** only; use it solely on a trusted wired LAN. TLS is out of scope.
- Basic auth credentials are generated locally on the device; the scripts read no password file on the build machine. `deploy/htpasswd.example` in this repository is a **placeholder**, not a real credential.
- Upload filenames allow only `[A-Za-z0-9._-]`; `..`, absolute paths, backslashes, NUL and control characters are rejected, and only the basename is written.
- Destination files are opened with `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`; collisions get a numeric suffix, so existing files are never overwritten and symlinks are never followed.
- The upload CGI uses `upload.lock` (`O_CREAT|O_EXCL` + PID, removed via `unlink` on exit) to enforce concurrency = 1; it does not rely on `flock` and therefore runs on NetBSD 6.
- Neither the server nor the CGI writes to `/`; the resetting root filesystem leaves no state behind.

### 9. License and Attribution

- Project source (except the file noted below): **GPL-3.0-or-later**, Copyright (C) 2026 tc-webshare contributors. Full text in [LICENSE](LICENSE).
- `build/env.sh` **is derived from the TimeCapsuleSMB project's cross-build environment**. Its original copyright notice and GPL-3.0-or-later license header are preserved verbatim at the top of the file, including the source comment. Do not remove that header when re-syncing upstream.
- `src/upload.c` and `deploy/*.sh` are implemented by this project and are GPL-3.0-or-later.
- thttpd and NetBSD sources follow their respective upstream licenses; they are downloaded from official releases at build time and their source is not redistributed here.

### 10. Changes and Boundaries

- All path conventions are defined by `docs/device-layout.md`.
- The marker strings are byte-identical in `install.sh`, `uninstall.sh`, `docs/device-layout.md` and this README:
  - Begin: `# >>> TC_WEBSHARE BEGIN >>>`
  - End: `# <<< TC_WEBSHARE END <<<`
- This package does not modify tc-toolbox, Samba configuration or data; it contacts no real device and reads or writes no credential file.

---

<a id="chinese"></a>

## 中文

面向 **AirPort Time Capsule 固件 7.9.1** 的明文 HTTP 文件共享系统：局域网内浏览/下载上传文件，与设备上已有的 tc-toolbox 和 TimeCapsuleSMB Samba 完全共存，并且可以**字节级验证地回退**。

本仓库只含源码、脚本和文档。构建在 Docker 中完成，**不连接任何网络设备、不 ssh/scp 到真机、不读取任何凭据文件**。

> **验证状态（诚实声明）**：本版本仅完成本地验证——gcc 语法检查、POSIX `sh -n` 解析、`upload.c` 功能安全桩测（10/10）、回退幂等桩演练。**从未在真实 NetBSD 6 设备上实测，也未连接过任何真机。** 完整记录见 [CHANGELOG.md](CHANGELOG.md)。

### 1. 设备事实与硬约束（架构师定稿）

| 项目 | 值 |
| --- | --- |
| 固件 | Apple AirPort Time Capsule 7.9.1 |
| 内核 / 架构 | NetBSD 6.0 / evbarm / earmv4（ARMv4，**无 Thumb / NEON**） |
| 可执行格式 | **仅纯静态 ELF**（无动态链接器） |
| 硬盘挂载点 | `/Volumes/dk2` |
| 根文件系统 | 每次重启重置 |
| 开机钩子 | `/mnt/Flash/boot.sh`（出厂只读；写前 `chmod u+w`，写后 `chmod u-w`） |
| 必须保留 | `/Volumes/dk2/.tc_tools/bin/`（53 个静态工具）、`/Volumes/dk2/.samba4/`（Samba，139/445） |
| 传输方式 | sshd 无 SFTP，传文件用 `scp -O` |
| `sed` 就地编辑 | NetBSD 语法必须为 `sed -i ""` |
| Shell | 全部脚本使用 POSIX `#!/bin/sh`（设备不保证 bash） |

Word size 是 32 位，所以 **LFS 必开**：交叉编译参数必须包含 `-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE`，否则 32 位 `off_t` 在 2 GB 处溢出。

#### 设备性能极限（实测/经验值，非保证值）

- 下载（thttpd，server 零 fork）：典型 **15~25 MB/s**
- 上传（CGI 流式写盘）：典型 **8~15 MB/s**
- 单文件安全上限 **≤ 500 MB**；实用上限 **1~2 GB**（受磁盘碎片与 32 位进程地址空间影响）
- 并发上传锁 **= 1**：同一时刻只允许一个 multipart 上传，重复请求返回 `503`
- HTTP 并发连接数 `maxconns=10`

### 2. 架构

```
浏览器 (LAN)  --HTTP :8080-->  thttpd (静态 ELF, dir=/Volumes/dk2/share/web)
                                  |-- GET /            -> Basic auth (401 / 200)
                                  |                    -> 目录索引 / 文件下载 (零 fork)
                                  `-- POST /cgi-bin/upload.cgi
                                          -> 静态 C CGI, 64KB 流式写盘
                                          -> upload.lock (O_EXCL, 并发=1)
                                          -> /Volumes/dk2/share/web/<basename>
```

- **下载/索引**由 thttpd 直接处理，不为每个请求 fork 新进程。
- **上传**由 `src/upload.c` 编译出的静态 CGI 处理：multipart 边界逐块扫描，每次最多 64 KiB 写入文件，绝不把整个文件读进内存。
- 所有 Web 产物集中在 `/Volumes/dk2/.tc_webshare/`（**回退边界**），用户上传数据放在 `/Volumes/dk2/share/web/`（默认回退时保留）。
- `/mnt/Flash/boot.sh` 中只插入一个标记块，**不重写整个文件**：

```
# >>> TC_WEBSHARE BEGIN >>>
# tc-webshare: LAN-only HTTP share; managed block, do not edit by hand.
if [ -x /Volumes/dk2/.tc_webshare/bin/boot_hook.sh ]; then
    /Volumes/dk2/.tc_webshare/bin/boot_hook.sh >/dev/null 2>&1
fi
# <<< TC_WEBSHARE END <<<
```

卸载时只删除这两个标记之间（含标记）的行，并用静态 `sha256sum` 比对“非 Web 行”的校验和与 `state/manifest` 中记录的值一致。

### 3. 文件树

```
tc-webshare/
├── README.md                 本文件（英中双语）
├── CHANGELOG.md               版本由来、验证范围与未验证项声明
├── LICENSE                    GPL-3.0-or-later 全文
├── .gitignore                 排除构建/暂存/QA/凭据类产物
├── Dockerfile                 debian:bookworm 交叉构建环境，大小写敏感卷 /wb-build
├── run.sh                     docker build + 建卷 + 构建（EXTRA 等开关）
├── build/
│   ├── env.sh                 NetBSD 7.2_STABLE 交叉环境（源自 TimeCapsuleSMB，保留 GPL 头）
│   ├── fetch_src.sh           幂等下载/解包 NetBSD 7.2 源码到 /wb-build
│   └── build_thttpd.sh        静态编译 thttpd + upload.cgi，objdump 校验无 INTERP/DYNAMIC
├── src/
│   └── upload.c               流式 multipart 上传 CGI（LFS，文件名白名单，O_EXCL 锁）
├── deploy/
│   ├── install.sh             幂等部署 + 校验报告
│   ├── uninstall.sh           幂等回退（默认保留用户数据）
│   ├── boot_hook.sh           开机拉起 thttpd（幂等）
│   ├── thttpd.conf            配置模板
│   └── htpasswd.example       示例凭据（占位，非真实口令）
└── docs/
    └── device-layout.md       设备目录布局与文件归属
```

### 4. 构建（本机/Docker，不碰真机）

前提：本机有 Docker，且有一个 **NetBSD 7.2_STABLE evbarm/earmv4 交叉工具链**（三元组 `armv4--netbsdelf-eabi`）。本机没有该工具链也没关系，脚本可复现，只是不能在此环境产出二进制。

```sh
# 1) 构建镜像并运行交叉编译（BSD/macOS/Linux 均可）
SDK_DIR=/path/to/netbsd-7.2-evbarm-sdk \
BUILD_OUT=/path/to/output/stage \
./run.sh

# 2) 产物（纯静态 ELF）
ls "$BUILD_OUT/bin"
# thttpd  upload.cgi  ../build-info

# 3) 强制重建 / 离线复用缓存源码 / 追加 docker 参数
NO_CACHE=1 ./run.sh
NO_FETCH=1 ./run.sh
EXTRA='-e TC_ENV_QUIET=0' ./run.sh
```

`run.sh` 会创建 Docker 命名卷 `tc-webshare-wb-build` 作为 `/wb-build`，避免 macOS APFS 默认大小写不敏感导致 NetBSD 源码树构建失败。`build_thttpd.sh` 使用的主要参数：

```
-O2 -g0 -static -fno-pic -fno-PIE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE
```

每个产物都经 `objdump -p` 检查：若出现 `INTERP` 或 `DYNAMIC` 段则构建失败。

#### 本地静态检查（无需交叉工具链）

```sh
# POSIX sh only parses the FIRST file passed to "sh -n", so loop over all 7.
for f in run.sh build/env.sh build/fetch_src.sh build/build_thttpd.sh \
         deploy/install.sh deploy/uninstall.sh deploy/boot_hook.sh; do
    sh -n "$f" || exit 1
done
gcc -fsyntax-only -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE src/upload.c
```

### 5. 部署（在设备上执行）

把整个包和构建产物放到设备，例如：

```sh
# 从本机推送（sshd 无 SFTP，必须用 -O）
scp -O -r tc-webshare root@<TC-LAN-IP>:/Volumes/dk2/.tc_webshare_pkg
# 先在设备上创建 build_out/bin 目录，再推送产物
scp -O build_out/bin/thttpd build_out/bin/upload.cgi \
    root@<TC-LAN-IP>:/Volumes/dk2/.tc_webshare_pkg/build_out/bin/
```

在设备上：

```sh
cd /Volumes/dk2/.tc_webshare_pkg

# 推荐：先在本地生成 crypt(3) hash，再通过环境变量传入（不落盘明文）
TC_WEB_PASS_HASH='$1$xxxx$....' ./deploy/install.sh

# 或者：让 install.sh 在设备上生成一次性随机口令并打印一次
./deploy/install.sh
```

`install.sh` 会：

1. 预检：先做路径守卫（拒绝 `/`、`$HOME`、`/Volumes` 等危险路径），再查 `uname`、`/Volumes/dk2` 挂载、Samba 139/445 在听、`boot.sh` 存在、静态工具齐全。**先判定标记块**：已安装则进入原地更新模式，未安装且 8080 被占用才拒绝部署。
2. 更新模式下先按 pidfile 优雅停掉**自身** thttpd（用 `ps` 校验 PID 归属，非自身进程绝不 kill），确认 8080 释放后再覆盖二进制，避免 ETXTBSY。
3. 建 `.tc_webshare/{bin,etc,state}` 与 `share/web/`，装二进制、配置和凭据。
4. 生成 `state/manifest`：所有安装路径 + boot.sh 安装前后 sha256 + 时间戳。
5. 幂等插入标记块（已存在则跳过）；`boot.sh` 非 Web 行校验和前后必须一致。
6. 立即用绝对路径调用一次 `boot_hook.sh`（标记块只在开机时生效）。
7. 验证 8080 监听，并做一次 GET：期望 `401 Unauthorized`（证明 Basic auth 生效）。
8. 重复运行无需先停服务：输出 `already installed: updated in place`，原地更新文件/清单并自动重启 thttpd；不会插入第二个标记块，非 Web 行字节不变。若 pidfile 的 PID 不是自身 thttpd 却占着 8080，则明确报错退出，防止误杀他人进程。

上传测试（需要 Basic auth）：

```sh
curl -u admin:'<password>' -F 'file=@/path/to/test.txt' \
     http://<device-lan-ip>:8080/cgi-bin/upload.cgi
# 期望: 200 + "OK files=1 bytes=..."；文件落在 /Volumes/dk2/share/web/
```

### 6. 验证清单

部署后逐项确认：

- [ ] `netstat -an | grep LISTEN` 显示 8080、139、445 均在听
- [ ] `wget -S -O /dev/null http://127.0.0.1:8080/` 返回 **401**
- [ ] `curl -u <user>:<pass> http://127.0.0.1:8080/` 返回 200 且能看到目录索引
- [ ] 上传小文件返回 200，文件出现在 `/Volumes/dk2/share/web/`
- [ ] 上传同名文件得到 `.1`、`.2` 后缀，**不覆盖**原文件
- [ ] 上传 `../x`、`/etc/passwd`、`a\b` 等非法文件名被 400 拒绝
- [ ] 并发两个上传时第二个返回 503（并发锁 = 1）
- [ ] `sha256sum` 计算 boot.sh 过滤掉标记块后的值 == `state/manifest` 中的值
- [ ] `/Volumes/dk2/.tc_tools/bin` 文件数仍 ≥ 50；`.samba4/` 仍在
- [ ] 重启设备后 8080 自动恢复（boot.sh 标记块生效）

### 7. 回退

```sh
cd /Volumes/dk2/.tc_webshare_pkg
./deploy/uninstall.sh              # 保留 /Volumes/dk2/share/web 用户数据
./deploy/uninstall.sh --purge-data # 仅在确实需要时删除用户数据
```

`uninstall.sh` 会：

1. 按 pidfile 停 thttpd，确认 8080 关闭。
2. 用 `sed -i ""` 只删 boot.sh 中两个标记之间（含标记）的行；
   校验非 Web 行 sha256 与 manifest 一致。
3. 只删 `/Volumes/dk2/.tc_webshare/`；默认保留用户数据。
4. 验证：8080 已关；139/445 仍在听；`.tc_tools/bin` 工具仍在；
   `.samba4/` 与共享根目录可访问；boot.sh 无标记块且校验和一致。
5. 已卸载时再次运行输出 `already clean` 并成功退出。

### 8. 安全说明

- 本轮为**明文 HTTP**，仅建议在有线的可信 LAN 内使用；TLS 不在范围内。
- Basic auth 凭据只在设备本地生成，脚本不读取本机任何口令文件。
  仓库中的 `deploy/htpasswd.example` 是**占位符**，不是真实凭据。
- 上传文件名仅允许 `[A-Za-z0-9._-]`，拒绝 `..`、绝对路径、反斜杠、
  空字节与控制字符；落盘时只取 basename。
- 目标文件用 `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW` 打开，重名加数字后缀，
  不会覆盖已有文件，也不会跟随符号链接。
- 上传 CGI 用 `upload.lock`（`O_CREAT|O_EXCL` + PID，退出 `unlink`）实现并发 = 1，
  不依赖 `flock`，可在 NetBSD 6 上运行。
- 服务与 CGI 都不写 `/`；根文件系统重启重置不会留下状态。

### 9. 许可证与来源标注

- 本项目源码（除下述文件外）：**GPL-3.0-or-later**，
  Copyright (C) 2026 tc-webshare contributors。全文见 [LICENSE](LICENSE)。
- `build/env.sh` **源自 TimeCapsuleSMB 项目的交叉构建环境**，
  其原始版权声明与 GPL-3.0-or-later 许可头已原样保留在文件顶部，
  包括来源注释。再次同步上游时请勿删除该头部。
- `src/upload.c` 与 `deploy/*.sh` 为本项目实现，GPL-3.0-or-later。
- thttpd 与 NetBSD 源码各自遵循其上游许可证；构建时从官方发行版下载，
  本仓库不分发其源码。

### 10. 变更与边界

- 所有路径约定以 `docs/device-layout.md` 为准。
- 标记块字符串在 `install.sh`、`uninstall.sh`、`docs/device-layout.md`、本 README 中完全一致：
  - 开始：`# >>> TC_WEBSHARE BEGIN >>>`
  - 结束：`# <<< TC_WEBSHARE END <<<`
- 本部署包不修改 tc-toolbox、Samba 配置或数据，不连接真机，不读写任何凭据文件。
