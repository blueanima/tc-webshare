# Changelog / 变更记录

## v1.0.8 — 2026-11-22 — 网页改密码 / Web password change

网页管理界面顶部新增「修改密码」按钮与弹窗（新密码 + 确认密码，
均为 `type=password`，不回显）。两次不一致、空值、控制字符或超过 200
字节会在前端拦下；确认后向新端点 `/chpasswd.cgi` POST form-urlencoded
`new_password`。成功后关闭弹窗、清空输入框并明确提示「用新密码重新登录」；
界面不自动 `refresh()`，之后的 401 会给出「关闭并重新打开浏览器（或清除
本站登录信息）」的具体指引，避免「页面还能用、一刷新就 401」的困惑。
浏览器 XHR 的 401 无法可靠触发新的认证弹窗，强行用错凭据触发反而更糟，
因此选择明确指引用户重开；新口令本身是立即生效的（bozohttpd 每请求重读
`.htpasswd`）。

后端 `manage.c` 新增 `action_chpasswd()`：用 `crypt(3)`（静态链接
libcrypt，与 bozohttpd 相同）在 CGI 进程内部生成 `$1$` MD5-crypt hash，
明文不进 argv / shell / 管道 / 子进程 / 日志，返回前从栈缓冲清零，响应
不回显密码与 hash。目标文件固定为安装期写入的 `TC_ETC_DIR/htpasswd`
（旧分发器仅有 `TC_STATE_DIR` 时从其父目录推导 `/etc`），不接受前端路径；
同目录临时文件 + `rename()` 原子替换、mode `0600`、保留其他用户行。
支持可选 `old_password` 二次校验（不匹配 `403`），网页端按两字段设计不发送。
响应：`200 {"ok":true}` / `400` 非法或空密码 / `403` 旧密码不匹配 /
`500` hash 或写失败。仅接受 form POST，拒绝 GET query，避免口令进 URL/历史。

`install.sh` 生成的 CGI 分发器新增 `*/chpasswd.cgi) exec manage.bin` 并导出
`TC_ETC_DIR`；`-C .cgi` 下该端点自动受同一份 docroot `.htpasswd` 保护，
启动参数与鉴权模型未改。此链路是 `deploy/change_password.sh` 的无需 SSH
等价实现（同一文件、同一 `$1$` 格式、同样的原子/0600/保留其他用户语义）；
脚本仍供 SSH/自动化使用，且仍是唯一支持 `-u` 显式用户名的接口。

验证：本机 `tests/chpasswd_c_test.c`（7 组：保留其他用户/0600/原子临时文件
清理/旧密码对错/空与超长与控制字符/GET 拒绝/`TC_STATE_DIR` 回退与
`REMOTE_USER`/非法路径）与 `tests/index_ui_test.js`（原 5 组 + 新增 3 组
密码弹窗用例）全部通过；`gcc -Wall -Wextra -fsyntax-only` 原生与交叉均无
警告，所有 sh `sh -n`、内联 JS `node --check` 通过。`tc_wb` 静态交叉编译后
`nbfile` + `objdump -p` 确认含 `-lcrypt` 的 `manage.cgi` 仍是纯静态
earmv4 ELF（无 INTERP/DYNAMIC）。`httpd` 与 `upload.cgi` 未改动，哈希不变；
`manage.cgi` SHA-256 `de9e015ca2a96660881d52a00b1a2c6b48a43674502ead6656e8697882773120`。
尚未真机部署，待 QA 验证。

Added a **Change password** button and modal (new password + confirmation,
both `type=password`) to the top toolbar. Mismatches, empty values, control
characters and >200-byte values are blocked client-side; submission POSTs
`new_password` as form data to the new `/chpasswd.cgi` endpoint. On success the
modal closes, fields are cleared, and the message asks the user to log in again
with the new password; the UI deliberately does **not** auto-refresh, and any
later 401 explains how to drop the cached Basic credentials (close and reopen
the browser or clear site login data). The new password is already live because
bozohttpd re-reads `.htpasswd` on every request; an XHR 401 cannot reliably
raise a fresh auth dialog, so explicit guidance is the dependable fix.

`action_chpasswd()` in `manage.c` computes the `$1$` MD5-crypt hash **in
process** with `crypt(3)` (statically linked libcrypt, as bozohttpd already
does). Plaintext never reaches argv/shell/pipe/child/log, is zeroed before
return, and is never echoed with the hash. The target is the install-time-baked
`TC_ETC_DIR/htpasswd` (derived `/etc` fallback for older dispatchers); no
client input can choose a path. The write is atomic (same-directory temp +
`rename()`), mode `0600`, and preserves other users. An optional
`old_password` check returns `403` on mismatch; the two-field web UI does not
send it. Only form POST is accepted so passwords cannot enter URLs/history.

The generated dispatcher gains `*/chpasswd.cgi` and exports `TC_ETC_DIR`;
`-C .cgi` keeps the endpoint under the same docroot Basic auth, with no server
flag changes. This is the no-SSH equivalent of `deploy/change_password.sh`
(same file, `$1$` format, atomic/0600/other-user semantics); the script remains
for SSH/automation and is still the only interface with an explicit `-u` user.
Verified locally with 7 native C groups, 3 new UI groups (existing 5 still
pass), warning-free native/cross syntax checks, `sh -n`, `node --check`, and
`tc_wb` static ELF checks for the new `-lcrypt` link. `httpd`/`upload.cgi`
hashes unchanged; `manage.cgi` SHA-256
`de9e015ca2a96660881d52a00b1a2c6b48a43674502ead6656e8697882773120`.
Not yet deployed to real hardware; QA validation pending.

## v1.0.7 — 2026-11-21 — 设备上改 Web 密码的辅助脚本 / On-device Web password changer

新增 `deploy/change_password.sh`，由 `install.sh` 安装到设备
`<ROOT_DIR>/bin/change_password.sh`。在设备上运行，用 `openssl passwd -1 -stdin`
重算托管 `etc/htpasswd` 的 crypt(3) hash；bozohttpd 每请求重读 `.htpasswd`，
新密码**立即生效**（无需重启/reboot/重装）。交互式双次输入不回显；也可从 stdin
喂入密码（不进 argv/shell 历史）。保留其他用户、维持 0600、拒绝空密码/不一致。
README 中英双语已补用法。此改动不改任何二进制，三二进制哈希与 v1.0.6 相同。

Added `deploy/change_password.sh`, installed by `install.sh` to the device at
`<ROOT_DIR>/bin/change_password.sh`. Run it on the device; it recomputes the
crypt(3) hash in the managed `etc/htpasswd` via `openssl passwd -1 -stdin`.
bozohttpd re-reads `.htpasswd` per request, so the new password takes effect
immediately (no restart/reboot/reinstall). Interactive double-entry hides input;
a password can also be fed on stdin (never in argv/history). Other users and
mode 0600 are preserved; empty/mismatched passwords are rejected. README (both
languages) updated. No binaries changed — hashes identical to v1.0.6.

## v1.0.6 — 2026-11-21 — 中文上传文件名 + 移动到文件夹 / UTF-8 upload names + move entry

### 1. 修复：上传中文文件名被 400 拒绝 / Fix: Chinese upload filenames rejected

用户实际上传 `内网算力统...作思路.docx` 报错 `HTTP 400 ERROR: filename
rejected by security policy`，而同一界面「新建文件夹」却允许中文名。

**根因**：v1.0.4 只给 `src/manage.c` 的 `valid_folder_name()` 接入了严格 UTF-8
校验；`src/upload.c` 的 `valid_filename()` 仍是旧的 ASCII 白名单
`[A-Za-z0-9._-]`，任何 ≥0x80 的字节直接被拒。两处安全强度不一致。

**修复**：在 `upload.c` 内加入与 `manage.c` v1.0.4 **逐字节一致**的
`valid_utf8_bytes()`（严格 RFC 3629：拒游离续字节、C0/C1、overlong、UTF-16
代理区、>U+10FFFF、C0/C1/DEL 控制字节），`valid_filename()` 在保留全部旧
安全边界后用该函数替代 ASCII 白名单。选择源码镜像而非共享头文件，是因为两个
CGI 是独立静态二进制，且这样 `manage.c` 完全不动、其已发布哈希保持不变；
两处函数需同步维护（代码注释已注明）。

- 放行：中文、emoji、2/3/4 字节合法 UTF-8，以及可打印 ASCII 0x20–0x7E
  （含空格与常见符号）；`.gitignore` 等隐藏文件名行为**保持不变**。
- 仍拒绝：空名、`/`、`\`、任意 `..` 子串、单独的 `.`、NUL/控制字节、
  >200 字节（按字节计）、畸形 UTF-8。
- `upload.c` 额外增加任意位置的 `/` 检查（defence in depth）。
- `../evil.txt` 这类带路径的 `Content-Disposition` 文件名现在在取 basename
  **之前**就被 400 拒绝；以前会静默存成 `evil.txt`（虽然不会越目录，但与文档
  声明的策略不一致）。浏览器上传本来就只发送 basename，不受影响。

### 2. 新功能：移动文件/文件夹到文件夹 / Move entry into a folder

- `manage.c` 新增 `/move.cgi`，POST form-urlencoded（或 GET query）接收
  `name` 与 `to`，JSON 响应风格与 list/mkdir/delete 一致：
  `{"ok":true,"name":"...","to":"..."}`。
- `name`/`to` 都过 `valid_folder_name()` + `is_program_file()`：basename、
  拒 `/` `\`、`..`、前导点与程序文件、严格 UTF-8、≤200 字节；中文名可用。
- `lstat()` 确认 `to` 是真实目录且不是软链，`name` 也拒绝软链/特殊文件；
  用 `rename()` 仅做「顶层 → 一层顶层文件夹」，**不递归、不跨层、不移出
  `TC_SHARE_DIR`**。
- `name == to` 或目标已有同名条目 → 409（先 `lstat()` 检查，绝不覆盖用户数据）；
  源不存在 → 404，非法名 → 400，软链/特殊文件/目标非目录 → 403，其他 → 500。
- `install.sh` 生成的 CGI 分发器加入 `*/move.cgi)` 分支；`-C .cgi` 下自动受
  同一份 docroot `.htpasswd` 保护，鉴权未改。
- `manage.c` 补 `_ISOC99_SOURCE`（与 v1.0.5 的 `upload.c` 同款修复），消除
  交叉编译下 `strtoll` 的隐式声明警告并避免 32 位整数截断。
- `deploy/index.html` 操作列在「下载」与「删除」之间加「移动」按钮：从当前
  `list.cgi` 结果中 `dir:true` 的条目生成下拉（排除自身），无文件夹时提示
  「请先新建文件夹」，POST `/move.cgi` 后 `refresh()`，失败显示后端 JSON
  `error` 文案。v1.0.5 的上传进度/`finalize()`/无 `req.timeout` 逻辑未改。

### Verification / 验证

- `tests/run_filename_validation_test.sh`：32 个用例覆盖中文/emoji/符号/
  隐藏文件/200 字节边界，以及所有旧边界与畸形 UTF-8（overlong、代理区、
  超范围、游离续字节、C0/C1/DEL）→ 全部 PASS。
- `tests/index_ui_test.js`：原有 v1.0.5 上传速度/成功/错误路径 3 项仍 PASS；
  新增「移动弹窗只列出其它文件夹、中文名 URL 编码、成功提示、无文件夹提示」
  2 项 → 全部 PASS。
- `gcc -Wall -Wextra -fsyntax-only`（原生与交叉）无警告；所有 sh 脚本
  `sh -n` 通过；内联 JS `node --check` 通过。
- Docker `tc_wb` 工具链静态交叉编译，`nbfile` + `objdump -p` 三重校验：
  纯静态 earmv4 ELF、无 INTERP/DYNAMIC。`httpd` 未改动。
- 新 SHA-256：`upload.cgi` `4582a0ca1bfe40adab27a6760d00fa78e4916307fac671ddb472efa818fd98b8`，`manage.cgi` `dca20ba7541d682293daa973ba92f0a04fdd41af7c4a5e8c393a4093d35097b6`。
- **状态：** 仅本机构建与本地测试；本改动未真机部署，需 QA 验证后再上线。
  **Status:** local build and tests only; NOT deployed to the real device.

## v1.0.5 — 2026-11-21 — 修复上传完成后卡死 / Fix: upload hangs after transfer

User-reported bug: "no transfer speed shown, progress sticks at 100% after the
upload, must refresh the page manually." The file did land on disk
(`upload.log` recorded `status=OK`), but the HTTP response never finished.
用户反馈："没有显示上传速度，传完后卡 100%，要手动刷新"。文件其实已落盘（`upload.log`
记录了 `status=OK`），但 HTTP 响应一直没有结束。

### Root cause / 根因

`src/upload.c` called `drain_stdin()` on the success path after the multipart
body had already been fully parsed. bozohttpd's `cgi-bozo.c` gives a CGI **one
`AF_UNIX` socketpair as both stdin and stdout** (`dup2(sv[1], 0)` and
`dup2(sv[1], 1)`). The input parent writes `CONTENT_LENGTH` bytes to `sv[0]`
and exits, while a separate output-forwarding child **keeps `sv[0]` open** and
reads the CGI response until EOF (`finish_cgi_output()`). Therefore stdin on
the CGI side can never report EOF until the CGI itself exits:

```
CGI blocks reading stdin to EOF
  -> never writes its HTTP response
  -> forwarder never sees EOF, never replies to the browser
  -> browser XHR readyState 4 never arrives (stuck at 100%)
  -> client times out; CGI killed; atexit() never runs; upload.lock leaks
```

This was reproduced empirically with a native harness that mirrors the
socketpair topology: the pre-fix CGI timed out with the process still alive,
no response bytes forwarded, and `upload.lock` left behind.
`src/upload.c` 成功路径在 multipart 已解析完之后又调用 `drain_stdin()` 试图把 stdin 读到
EOF。bozohttpd 的 `cgi-bozo.c` 给 CGI 的是**同一个 `AF_UNIX` socketpair 同时充当 stdin 与
stdout**，输入父进程写完 `CONTENT_LENGTH` 字节就退出，但另一个输出转发子进程**一直持有
`sv[0]`**，要读到 CGI 响应 EOF 才结束。因此 CGI 侧的 stdin 在自身退出前永远不会有 EOF：
CGI 卡在读 stdin → 不写响应 → 转发子进程等不到 EOF → 浏览器 `readyState 4` 永远不来
（卡 100%）→ 客户端超时、进程被杀、`atexit()` 不执行、`upload.lock` 残留。已用复刻该
socketpair 拓扑的本地原生测试实证复现。

### Fixes / 修复

- **Removed `drain_stdin()` entirely.** The parser already consumes every body
  byte through the closing boundary; reading further was both unnecessary and
  a circular wait. A comment in `upload.c` documents why it must not return.
- **Success path now emits `Status: 200 OK`** (matching `cgi_fail()`), plus an
  explicit `fflush(stdout)` so the forwarder receives the complete response
  before `main()` returns. `cleanup_lock()` runs on the normal exit path, so
  no `upload.lock` is left behind.
- **`SIGPIPE` now routes through `on_fatal_signal()`** so a client disconnect
  also releases the O_EXCL lock (default SIGPIPE termination skips `atexit`).
- **Added `_ISOC99_SOURCE`** so the NetBSD 7.2 headers expose `strtoll`; this
  removes a pre-existing cross-compiler warning and prevents a 32-bit implicit
  `int` return from truncating `CONTENT_LENGTH` above 2 GiB.
- **Web UI shows transfer speed.** `onprogress` samples at most ~8×/s and
  smooths with an EMA; the label reads e.g. `45% · 2.3 MB/s`. A final average
  speed is appended to the completion message, and the status line is now set
  *after* `refresh()` so it is no longer cleared immediately.
- **Completion/failure handling hardened.** One idempotent `finalize()`
  covers `readyState 4`, `onerror` and a synchronous `send()` exception:
  it always hides the bar and re-enables the button. No `req.timeout` is set
  deliberately — large backups over a slow LAN can take minutes and a fixed
  deadline would report false failures.
- **删除了 `drain_stdin()`**（解析器已读到结束边界，再读就是循环等待，注释已写明禁止恢复）；
  成功响应补 `Status: 200 OK` 与 `fflush(stdout)`，正常退出时释放 `upload.lock`；
  `SIGPIPE` 走清理处理；补 `_ISOC99_SOURCE` 消除 `strtoll` 警告并避免 2 GiB 截断；
  进度条显示平滑速度、完成态显示平均速度，`finalize()` 统一处理成功/网络错误，
  故意不设 `req.timeout` 以免大文件误超时。

### Verification / 验证

- `gcc -Wall -Wextra -fsyntax-only src/upload.c`: no warnings (native and
  cross with `-Werror`); `node --check` on the inline JS: passed;
  `sh -n` on all shell scripts: passed.
- `tests/run_upload_response_test.sh`: pre-fix CGI → `BUG_REPRODUCED`
  (timeout, process alive, lock leaked); current CGI → `PASS` (response with
  `Status: 200 OK`, process exited, lock released, file intact).
- `tests/index_ui_test.js`: headless DOM/XHR test of the real inline script —
  speed text `100% · 5.0 MB/s`, success hides bar + refreshes + keeps message,
  network error also hides bar and re-enables the button.
- Cross-built in Docker (`tc_wb`, `armv4--netbsdelf-eabi-gcc --sysroot=...`,
  `-static -fno-pic -fno-PIE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE`);
  all three binaries verified by `nbfile` (static ARM ELF) and `objdump -p`
  (no `INTERP`/`DYNAMIC`). `httpd` and `manage.cgi` hashes are unchanged.
- New `upload.cgi` SHA-256:
  `04e35d26f7d25d86307f702f1f26a6343c9bb9e471cf5d2fadc648647c0a2cbd`.
- **Status:** local build + simulated-CGI tests only; NOT deployed to the real
  device by this change. QA validation required before deployment.
  **状态：** 仅本地构建与模拟 CGI 测试，本改动未真机部署；需 QA 验证后再上线。

## v1.0.4 — 2026-11-21 — 中文名、上传进度、删除 / Chinese names, upload progress, delete

Based on hands-on browser feedback: Chinese folder names were rejected, uploads
gave no progress feedback, and there was no way to delete anything. This release
closes all three gaps without weakening the single-`.htpasswd` auth model or
touching the device.
用户试用网页后反馈三点：中文文件夹名被拒、上传没有进度、只能传不能删。本版补齐三项能力，不削弱单份 `.htpasswd` 认证，也不连接真机。

### New features / 新功能

- **UTF-8 folder names.** `valid_folder_name()` in `src/manage.c` now accepts
  well-formed UTF-8 multibyte sequences in addition to printable ASCII
  (0x20–0x7E: spaces and common symbols are allowed; only `/`, `\` and a
  leading dot are excluded), so names such as `家庭照片` work for both mkdir
  and delete. Validation is
  **strict**: overlong encodings, UTF-16 surrogates (U+D800–U+DFFF), values
  above U+10FFFF, stray continuation bytes, C0/C1/DEL controls, `..`, leading
  dots, `/`, `\` and names over 200 **bytes** are still rejected. `list.cgi`
  already emits raw UTF-8 bytes under `charset=utf-8`, so JSON parses as-is.
  **UTF-8 文件夹名**：合法多字节序列（中文等）与可打印 ASCII（含空格/常见符号）放行；畸形序列、代理区、超范围码点、控制字符、`..`、前导点、斜杠与超 200 字节仍拒绝。
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
- Documentation correction: the README (EN/中文) and these notes now describe
  the actual name rule — printable ASCII (spaces and common symbols included)
  plus well-formed UTF-8 — instead of the narrower `[A-Za-z0-9._-]` whitelist
  that applies only to uploads. That correction changed no code, binaries or hashes.
  文档修正：README 中英版本条说明已与实现对齐（可打印 ASCII 含空格/常见符号 + 合法 UTF-8），不再沿用仅适用于上传的窄白名单；该次修正未改代码、二进制与哈希。

### Fix / 修复

- Update-mode Flash preflight no longer blocks in-place upgrades. Mode detection
  (boot.sh marker + managed root) now runs **before** the free-space gate, and
  the 1024 KiB threshold is relaxed to 128 KiB only when the marker **and** all
  three managed binaries (`httpd`, `upload.bin`, `manage.bin`) already exist —
  an update overwrites the same files in place and does not need a second copy.
  Fresh or partially installed trees keep the 1024 KiB gate; the 128 KiB margin
  still covers regenerated config/manifest and, when `/mnt/Memory` is absent,
  the boot.sh scratch files. Found when a real device with 956 KiB free could
  not install v1.0.4 over v1.0.3. **`deploy/install.sh` only — no binary or
  hash changed.**
  修复真机原地更新被 1024 KiB 门槛误拦：模式判定提前；仅当标记与三个二进制都在位才降到 128 KiB，首次/不完整安装仍要 1024 KiB；128 KiB 仍够配置、manifest 与（无 `/mnt/Memory` 时）boot.sh 临时文件。真机 956 KiB 空闲更新被拦是触发原因。仅改 `deploy/install.sh`，二进制与 sha256 不变。

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
