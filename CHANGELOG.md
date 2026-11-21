# Changelog / 变更记录

## v1.0.4 — 2026-11-21 — 中文名、上传进度、删除 / Chinese names, upload progress, delete

Based on hands-on browser feedback: Chinese folder names were rejected, uploads
gave no progress feedback, and there was no way to delete anything. This release
closes all three gaps without weakening the single-`.htpasswd` auth model or
touching the device.
用户试用网页后反馈三点：中文文件夹名被拒、上传没有进度、只能传不能删。本版补齐三项能力，不削弱单份 `.htpasswd` 认证，也不连接真机。

### New features / 新功能

- **UTF-8 folder names.** `valid_folder_name()` in `src/manage.c` now accepts
  well-formed UTF-8 multibyte sequences in addition to `[A-Za-z0-9._-]`, so
  names such as `家庭照片` work for both mkdir and delete. Validation is
  **strict**: overlong encodings, UTF-16 surrogates (U+D800–U+DFFF), values
  above U+10FFFF, stray continuation bytes, C0/C1/DEL controls, `..`, leading
  dots, `/`, `\` and names over 200 **bytes** are still rejected. `list.cgi`
  already emits raw UTF-8 bytes under `charset=utf-8`, so JSON parses as-is.
  **UTF-8 文件夹名**：合法多字节序列（中文等）放行；畸形序列、代理区、超范围码点、控制字符、`..`、前导点、斜杠与超 200 字节仍拒绝。
- **Upload progress.** The management page now shows a progress bar and a
  percentage while `XMLHttpRequest` sends the multipart body
  (`req.upload.onprogress`). All selected files are still sent in ONE POST, so
  the bar reports the whole batch; this keeps the uploader unchanged and avoids
  extra requests. The bar is hidden again on completion or failure, and the
  upload button is disabled during transfer. Pure native JS/CSS, no CDN.
  **上传进度条**：按整批显示（多文件一次 POST），完成/失败自动隐藏，上传期间禁用按钮；无外部依赖。
- **Delete.** New `/delete.cgi` action in `manage.bin`, routed by the generated
  `cgi_dispatch.sh` and exposed as a confirm()-guarded "删除" button on every
  row. It reads `name` from the same form/query source as mkdir and returns
  JSON: `200 {"ok":true,...}`, `400` invalid name, `403` symlink/special file,
  `404` missing, `409` non-empty directory, `500` other errors.
  **删除功能**：新增 `/delete.cgi` 与每行确认删除按钮；复用同名校验，JSON 状态码覆盖 400/403/404/409/500。

### Security boundary of delete / 删除的安全边界

- Top level of `TC_SHARE_DIR` only: `name` is a validated basename with no
  separators or `..`, then joined as `SHARE_DIR/name`.
- `lstat()` first; symlinks are **never** followed or deleted. `unlink()` only
  removes the link itself even under a race, and `rmdir()` fails on a symlink.
- Regular files use `unlink()`; directories use `rmdir()` only — **empty
  directories only, never recursive**, so user data cannot be wiped.
- Dotfiles (including `.htpasswd` and `.tc-webshare-index.html`) are rejected
  by name validation, with an explicit second check for the two program files.
- Deletion is **irreversible**: there is no trash or undo. The UI asks for
  confirmation; keep backups of anything important.
- 仅顶层、仅空目录、绝不递归；拒绝软链与全部点文件；删除不可恢复，请先确认。

### Verification / 验证

- `gcc -Wall -Wextra -fsyntax-only src/manage.c`: no warnings; `sh -n` on all
  shell scripts: passed.
- Docker `tc_wb` cross-build: `manage.cgi` compiled with the verified
  `armv4--netbsdelf-eabi-gcc --sysroot=...` toolchain and checked with both
  `nbfile` (static ARM ELF) and `objdump -p` (no INTERP/DYNAMIC).
- Native functional tests: valid Chinese/ASCII names accepted; malformed
  UTF-8, overlong encodings, surrogates, out-of-range code points, `..`,
  leading dots, separators, control bytes and 201-byte names rejected;
  delete refuses symlinks, non-empty directories, program files and traversal
  names, and removes a top-level file / empty directory with the expected
  status codes. Dispatcher routes all four CGI names correctly.
- **Not deployed to the real device in this release**; device validation is
  the operator's next step.
  本版**未连接真机部署**，待 QA 验证后再由操作者上线。

## v1.0.3 — 2026-11-21 — 网页管理界面 / Web management UI

The device served only bozohttpd's bare directory index. This release adds a
self-contained management homepage, a JSON listing endpoint and a folder
creation endpoint, without weakening the single-`.htpasswd` auth model.
用户反馈目录页没有上传/新建入口；本版加入离线管理首页、列表接口与建文件夹接口，且不削弱单份 `.htpasswd` 认证。

### Design / 设计

- Kept `-C .cgi` instead of switching to `-c <cgibin dir>`: the former keeps
  every `.cgi` request inside the docroot, so one `.htpasswd` covers all
  endpoints and no program file is mixed into user data. Because `-C` maps one
  suffix to one handler, a generated `/bin/sh` dispatcher in managed Flash
  `bin/cgi_dispatch.sh` routes `SCRIPT_NAME` to `upload.bin` or `manage.bin`.
  保留 `-C .cgi`（单份认证）；用 Flash 上的 shell 分发器按 SCRIPT_NAME 路由。
- New static CGI `src/manage.c` → `manage.bin`: `/list.cgi` returns a JSON
  array of top-level entries (dotfiles skipped, names JSON-escaped), and
  `/mkdir.cgi` creates a folder from a URL-encoded `name` parameter with the
  same whitelist as uploads (`[A-Za-z0-9._-]`, ≤200, no leading dot/`..`).
  新增静态 manage.cgi：顶层列表 + 安全建文件夹。
- Homepage master stays in managed Flash `etc/index.html`; a hidden copy
  `.tc-webshare-index.html` is published into the docroot and served with
  bozohttpd `-x` (hidden from `-H` index). Uninstall deletes exactly that
  file and never other docroot files.
  首页主副本在 Flash，隐藏副本发布到 docroot；卸载精确删除、不碰用户数据。

### Verification / 验证

- `sh -n` on all scripts and `gcc -fsyntax-only src/manage.c`: passed.
- Docker cross-build produced `httpd`, `upload.cgi`, `manage.cgi`; all three
  passed `nbfile` (statically linked ARM ELF) and `objdump -p` (no
  INTERP/DYNAMIC).
- Native functional tests: JSON escaping, dotfile hiding, folder creation,
  `..`/separator rejection, duplicate → 409. Dispatcher routing tested for
  all three SCRIPT_NAME values. Install/uninstall rehearsal confirmed the
  hidden homepage is removed while a user file is preserved.

## v1.0.2 — 2026-11-21 — 真机部署验证与踩坑回写 / Real-device deployment verified

A full on-device deployment was completed and accepted by the lead. This
release writes the observed pitfalls back into the repository so the documented
procedure is reproducible without the ad-hoc fixes used during deployment.
lead 已完成完整真机部署并验收通过；本版把踩坑与修复回写仓库，使文档流程可复现。

### Real-device validation / 真机验证

- `install.sh` → `INSTALL OK`; static binaries run on the device.
  安装成功，静态二进制在真机正常运行。
- Unauthenticated `GET /` → 401; authenticated GET → 200 + directory index.
  未认证 401、认证后 200 与目录索引。
- Upload with `curl -H 'Expect:'` succeeded and the file landed on the mounted
  internal disk; direct request to `.htpasswd` → 403.
  上传落盘硬盘，`.htpasswd` 直接请求 403。
- boot.sh marker block sits before the final `exec`; TimeCapsuleSMB / Samba
  untouched. `uninstall.sh` restored boot.sh byte-for-byte and kept user data.
  标记块位置正确，Samba 未动；回退逐字节还原且保留用户数据。
- **NOT validated:** no physical reboot. Boot autostart was exercised by
  running `boot_hook.sh` directly (including its acp mount step) and checking
  idempotence.
  **未验证**：未做物理断电重启；开机自启通过直接执行 boot_hook 验证幂等。

### Pitfalls fixed / 踩坑修复

- The device has **no `dirname` and no `awk`** (QA's matrix missed `dirname`).
  `deploy/install.sh`, `deploy/uninstall.sh` and `deploy/boot_hook.sh` now
  compute their script directory with pure POSIX shell `${0%/*}`, working for
  both relative and absolute invocation paths.
  设备无 `dirname`/`awk`，三个脚本改用 `${0%/*}` 纯 shell 实现。
- Flash is synchronous and extremely slow: `cp` of the 656 KiB `httpd` took
  ~20 minutes and risked making the device unreachable. `install.sh` now uses
  `dd bs=64k` (~30 s on device); boot.sh scratch files live on RAM tmpfs.
  二进制安装改为 `dd bs=64k`，临时文件放 RAM tmpfs。
- Upload tests with plain `curl -F` failed with `417 Expectation Failed`;
  document the mandatory `-H 'Expect:'` header.
  上传测试必须加 `-H 'Expect:'`，否则 417。
- README (EN/中文) gained a real-device validation section and the updated
  command matrix; `dd` added to `require_cmds`.
  双语 README 增加真机验证清单与命令矩阵。

## v1.0.1 — 2026-11-21 — 真机事实适配 / Real-device事实 adaptation

Based on the lead's authoritative on-device probe. This is a **deployment and
build adaptation**, not a feature release.

依据 lead 的真机探测事实所做的适配，非功能新增版本。

### Build / 构建

- `build_thttpd.sh` keeps its historical filename but now compiles **bozohttpd**
  (NetBSD base httpd) from `${SRC_ROOT}/libexec/httpd` into `httpd`, plus
  `src/upload.c` into `upload.cgi`. Flags: `-DDO_HTPASSWD -DNO_SSL_SUPPORT
  -DNO_LUA_SUPPORT`, `-static -fno-pic -fno-PIE -D_FILE_OFFSET_BITS=64
  -D_LARGEFILE_SOURCE`.
  `build_thttpd.sh` 保留历史文件名，实际编译 **bozohttpd** → `httpd`，并编译
  `upload.cgi`；开关如上。
- `env.sh`: `CC` now contains `--sysroot=${SYSROOT}`; `TOOLCHAIN_DIR`,
  `SYSROOT`, `NBFILE` and `SRC_ROOT` can point at the bootstrapped `tc_wb`
  volume (`/wb-build/tc-earmv4-netbsd7/...`, `/wb-build/src`) with no
  `SDK_DIR`. Original SDK layout remains supported. **Without `--sysroot`
  the build produces unusable binaries** — this was the earlier trap.
  env.sh 支持卷内工具链与 sysroot，保留原 SDK 布局；`--sysroot` 必填。
- Every artifact is rejected unless `nbfile` reports "statically linked"
  **and** `objdump -p` shows no INTERP/DYNAMIC section. Both checks were
  run for real in the `tc_wb` container during this release.
  两个产物均经 nbfile + objdump 双重校验，且本轮在容器里实跑通过。
- `fetch_src.sh` detects an already-provisioned source tree and fails loudly
  on an `SRC_ROOT`/`EXTRACT_DIR` mismatch (the QA-flagged pitfall).
  fetch_src.sh 识别已存在的源码树，路径不一致时明确报错。

### Deploy / 部署

- Default managed root moved from `/Volumes/dk2` to
  `/mnt/Flash/.tc_webshare` (persistent, executable). Data dir is resolved
  at install **and every boot**: mounted `/Volumes/dkN` if present, else
  `/mnt/Flash/.tc_webshare/data`. No dkN number is hardcoded.
  默认管理根目录改为 Flash；数据目录动态解析，不再硬编码 dkN。
- bozohttpd CLI corrected against upstream source: docroot is positional,
  CGI uses `-C .cgi <handler>` (one argument), port is `-I 8080`; old
  `-D/-p/-d` and two-argument `-c` were wrong.
  参数已按源码纠正：docroot 为位置参数，CGI 用单参数 `-C .cgi`。
- Generated `/bin/sh` CGI shim re-supplies `TC_SHARE_DIR` / `TC_STATE_DIR`
  because bozohttpd rebuilds the CGI environment; `-C .cgi` keeps the request
  in the docroot so a single `.htpasswd` link covers GET / and POST /upload.cgi.
  CGI 垫片补回环境变量；`-C .cgi` 让一份 .htpasswd 覆盖全部请求。
- QA-driven final corrections: docroot is POSITIONAL and `-C .cgi <handler>`
  maps CGI (single-argument `-c` no longer used); one `.htpasswd` in docroot
  covers GET / and POST /upload.cgi. The boot block goes **before**
  `echo 'boot: starting native manager'` and is `{ ...; } || true` wrapped so
  Samba still starts under boot.sh's `set -eu`. Every script sets
  `PATH=/bin:/sbin:/usr/bin:/usr/sbin`. lead then verified the on-device
  mount call `/usr/bin/acp rpc diskd.useVolume "path:s:/Volumes/dk2"`; both
  install and the boot hook now actively mount the internal disk and use
  `/Volumes/dk2/share/web` (dk3 fallback), so uploads survive reboot. No
  formatting or partition operation is performed. Only a genuine mount
  failure falls back to small but persistent `<ROOT_DIR>/data` on Flash with
  a loud capacity warning, then to volatile `/mnt/Memory` only as last resort. `BIN_SRC` default corrected to `build_out/stage/bin`. Uninstall
  preserves data unless `--purge-data`. Samba is in fact running; its absence
  is only a warning. TimeCapsuleSMB is never modified.
- Scripts avoid grep/awk/head/find/tr/cut/base64/sha256sum/mktemp/stat/mount
  etc.; a new `deploy/common.sh` provides shell-only helpers, and boot.sh
  verification uses a line-exact `state/boot.nonweb` snapshot.
  脚本不再依赖设备缺失的命令；Samba 未运行仅告警。
- Credentials: `TC_WEB_PASS_HASH` is required (no htpasswd/openssl on device);
  no plaintext password is generated or read.
  凭据只接受预生成的 crypt(3) hash。

### Verification scope / 验证范围（v1.0.1）

- `sh -n` on all eight shell scripts: passed.
  八个 shell 脚本语法检查通过。
- Docker build in `tc_wb`: `httpd` and `upload.cgi` compiled and verified as
  `ELF 32-bit LSB ARM EABI5 statically linked for NetBSD 7.2 earmv4`
  (nbfile) with no INTERP/DYNAMIC (objdump).
  容器内实编译并通过双重静态校验。
- Lead confirmed the static earmv4 ELF binaries execute on the real device.
  lead 已确认静态 ELF 可在真机执行。

Still **not** verified: full on-device install, HTTP auth handshake, upload,
reboot persistence and rollback. Real-device validation remains the
operator's responsibility.
仍未做完整真机部署、认证、上传、重启与回退验证。

## v1.0.0 — 2026-11-21

Initial public release of `tc-webshare`: a static HTTP file-share deployment kit for
Apple AirPort Time Capsule firmware 7.9.1 (NetBSD 6.0 / evbarm / earmv4) with
byte-verifiable rollback.

`tc-webshare` v1.0.0 首次公开发布：面向 Apple AirPort Time Capsule 固件 7.9.1
（NetBSD 6.0 / evbarm / earmv4）的静态 HTTP 文件共享部署包，支持字节级可验证回退。

### Origin / 由来

This package went through architecture review → implementation → two independent QA rounds:

本部署包经历 架构评审 → 实现 → 两轮独立 QA 验证：

1. **Architecture review ( architect sign-off )** — pinned the device facts and hard
   constraints (static ELF only, no Thumb/NEON, 32-bit LFS, boot.sh read-only window,
   coexistence with tc-toolbox and Samba, zero-fork downloads, single-writer uploads).
   **架构评审（架构师定稿）** —— 确定设备事实与硬约束（仅静态 ELF、无 Thumb/NEON、
   32 位 LFS、boot.sh 只读写入窗口、与 tc-toolbox 和 Samba 共存、零 fork 下载、
   单写者上传）。
2. **Implementation** — `Dockerfile`, `run.sh`, three `build/` scripts, `src/upload.c`,
   five `deploy/` files, `docs/device-layout.md` and the README.
   **实现** —— `Dockerfile`、`run.sh`、三个 `build/` 脚本、`src/upload.c`、
   五个 `deploy/` 文件、`docs/device-layout.md` 与 README。
3. **QA round 1** — found **2 bugs and applied 1 hardening change**; all findings were
   fixed and re-verified before the next round.
   **QA 第 1 轮** —— 发现 **2 个 bug，并完成 1 项加固**；所有问题均已修复并在下一轮复验。
4. **QA round 2** — **all checks passed**, with **1 additional low-risk fix**: an empty-string
   guard for optional string inputs, preventing an empty value from being treated as a
   valid configured path/identifier.
   **QA 第 2 轮** —— **全部检查通过**，另含 **1 处低危修复**：为可选字符串输入增加空串守卫，
   防止空值被误当作有效的配置路径/标识。

### Verification scope / 验证范围

What **was** verified locally:

本地**已完成**的验证：

- `gcc -fsyntax-only -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE src/upload.c` — syntax check passed.
  `gcc` 语法检查通过。
- POSIX `sh -n` on all 7 shell scripts (`run.sh`, 3 × `build/*.sh`, 3 × `deploy/*.sh`) — all passed.
  全部 7 个 shell 脚本的 POSIX `sh -n` 解析均通过。
- `upload.c` functional-safety stub tests — **10/10 passed** (filename whitelist, traversal and
  absolute-path rejection, collision suffixes, lock semantics, malformed headers, streaming
  boundary handling).
  `upload.c` 功能安全桩测 —— **10/10 通过**（文件名白名单、路径穿越与绝对路径拒绝、
  重名后缀、锁语义、畸形请求头、流式边界处理）。
- Idempotent rollback stub rehearsals — repeated install/uninstall cycles preserved
  non-Web `boot.sh` bytes and left user data intact unless `--purge-data` was given.
  回退幂等桩演练 —— 重复安装/卸载周期保持 boot.sh 非 Web 行字节不变；
  未指定 `--purge-data` 时用户数据保持不变。

What was **NOT** verified — honest disclosure:

**未**验证的内容 —— 诚实声明：

- **No real-device NetBSD 6 hardware test was performed. No real device was ever connected**
  at any point during design, implementation, QA or release preparation.
  **未做真机 NetBSD 6 实测；在设计、实现、QA 与发布准备全过程中从未连接真机。**
- No cross-compiled binaries are shipped here. The Docker cross-build requires a
  NetBSD 7.2 evbarm/earmv4 SDK that was not available in the preparation environment;
  hence `objdump` static-ELF verification of produced binaries was not executed here.
  本仓库不含交叉编译产物。准备环境中没有 NetBSD 7.2 evbarm/earmv4 SDK，
  因此未执行 Docker 交叉构建，也未对产物运行 `objdump` 静态 ELF 校验。
- No live HTTP deployment, authentication handshake, or on-device port/rollback
  observation was carried out.
  未进行实际 HTTP 部署、认证握手，也未在真机上观测端口状态或回退效果。

Real-device validation remains the operator's responsibility. Review the verification
checklist in README section 6 before and after any deployment.

真机验证仍由实际使用者负责。任何部署前后请对照 README 第 6 节的验证清单逐项确认。

### Release hygiene / 发布卫生

All real device identifiers (LAN addresses, serial numbers, MAC addresses) and any
credential material were removed before publication. Only generic placeholders such as
`<TC-LAN-IP>` and `<device-lan-ip>` remain. See [LICENSE](LICENSE) for GPL-3.0-or-later.

发布前已清除所有真实设备标识（局域网地址、序列号、MAC 地址）及任何凭据材料，
仅保留 `<TC-LAN-IP>`、`<device-lan-ip>` 等通用占位符。许可条款见 [LICENSE](LICENSE)（GPL-3.0-or-later）。
