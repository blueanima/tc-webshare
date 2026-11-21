# Changelog / 变更记录

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
  `PATH=/bin:/sbin:/usr/bin:/usr/sbin`. Data fallback is `<ROOT_DIR>/data` on
  Flash (no forced mount; disk is Apple-mounted on demand). Uninstall
  preserves that data unless `--purge-data`. Samba is in fact running; its
  absence is only a warning. TimeCapsuleSMB is never modified.
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
