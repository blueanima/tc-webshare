/*
 * index_ui_test.js - headless behaviour test for deploy/index.html's JS.
 *
 * Evaluates the real inline script in a minimal DOM/XHR sandbox, drives fake
 * upload progress events, and asserts that:
 *   1. progress text shows "NN% · x.x MB/s" (speed is computed and smoothed)
 *   2. readyState 4 / 200 hides the bar, re-enables the button and refreshes
 *   3. onerror also hides the bar and re-enables the button
 *
 * No browser, no npm modules, no network.  Run: node tests/index_ui_test.js
 * Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'deploy/index.html'), 'utf8');
const matched = html.match(/<script>([\s\S]*?)<\/script>/);
assert(matched, 'inline <script> not found in deploy/index.html');

let clock = 1000;
const elements = {};
const created = [];
const ids = [
  'status', 'rows', 'file', 'folder', 'uploadBtn', 'progressWrap',
  'progressFill', 'progressText', 'refreshBtn', 'mkdirBtn',
  'moveModal', 'moveInfo', 'moveTarget', 'moveConfirm', 'moveCancel',
  'passwdBtn', 'passwdModal', 'newPass1', 'newPass2', 'passwdMsg',
  'passwdConfirm', 'passwdCancel'
];
for (const id of ids) {
  elements[id] = {
    id: id,
    hidden: id === 'progressWrap' || id === 'moveModal',
    disabled: false,
    value: '',
    textContent: '',
    innerHTML: '',
    className: '',
    style: {},
    files: [],
    children: [],
    appendChild(child) { this.children.push(child); },
    focus() {},
    onclick: null
  };
}
elements.file.files = [{ name: 'big.bin', size: 10 * 1024 * 1024 }];

const xhrs = [];
class FakeXHR {
  constructor() {
    this.readyState = 0;
    this.status = 0;
    this.responseText = '';
    this.upload = {};
    this.headers = {};
    this.sent = false;
    xhrs.push(this);
  }
  open(method, url) { this.method = method; this.url = url; }
  setRequestHeader(key, value) { this.headers[key] = value; }
  send(body) { this.body = body; this.sent = true; }
}
class FakeFormData {
  constructor() { this.parts = []; }
  append(name, file) { this.parts.push([name, file]); }
}

const sandbox = {
  document: {
    getElementById: (id) => elements[id] || null,
    createElement: (tag) => {
      const el = {
        tag: tag, style: {}, children: [], textContent: '', value: '',
        appendChild(child) { this.children.push(child); },
        setAttribute() {}
      };
      created.push(el);
      return el;
    }
  },
  window: {
    performance: { now: () => clock },
    confirm: () => true
  },
  performance: { now: () => clock },
  XMLHttpRequest: FakeXHR,
  FormData: FakeFormData,
  console: console
};
vm.createContext(sandbox);
vm.runInContext(matched[1], sandbox, { filename: 'index.html:inline' });

/* --- 1. speed display -------------------------------------------------- */
elements.uploadBtn.onclick();
const up = xhrs.find((x) => x.url === '/upload.cgi');
assert(up, 'no /upload.cgi request created');
assert.strictEqual(elements.progressWrap.hidden, false, 'progress bar not shown');
assert.strictEqual(elements.uploadBtn.disabled, true, 'upload button not disabled');

const total = 10 * 1024 * 1024;
for (let i = 1; i <= 10; i++) {
  clock += 200;                    // 1 MiB per 200 ms = 5.0 MB/s
  up.upload.onprogress({
    lengthComputable: true,
    total: total,
    loaded: i * 1024 * 1024
  });
}
const text = elements.progressText.textContent;
assert(/^\d+% · [\d.]+ (B|KB|MB|GB)\/s$/.test(text),
       'progress text lacks percentage + speed: ' + text);
assert(/MB\/s$/.test(text), 'expected MB/s at 1 MiB/200ms, got: ' + text);
assert.strictEqual(elements.progressFill.style.width, '100%', 'fill not at 100%');
console.log('1. speed display       : OK (' + text + ')');

/* --- 2. successful completion ----------------------------------------- */
let refreshes = 0;
const listXhrCount = xhrs.filter((x) => x.url === '/list.cgi').length;
up.readyState = 4;
up.status = 200;
up.responseText = 'OK files=1 bytes=10485760\n';
up.onreadystatechange();
assert.strictEqual(elements.progressWrap.hidden, true, 'bar not hidden on success');
assert.strictEqual(elements.uploadBtn.disabled, false, 'button not re-enabled');
assert(elements.status.textContent.indexOf('上传完成') === 0,
       'success status missing: ' + elements.status.textContent);
assert(elements.status.textContent.indexOf('平均') !== -1,
       'final average speed missing: ' + elements.status.textContent);
assert(xhrs.filter((x) => x.url === '/list.cgi').length > listXhrCount,
       'refresh() not called after success');
console.log('2. success completion   : OK (' + elements.status.textContent + ')');

/* --- 3. network error path -------------------------------------------- */
const before = xhrs.length;
elements.uploadBtn.onclick();
const up2 = xhrs.slice(before).find((x) => x.url === '/upload.cgi');
assert(up2, 'second upload request missing');
up2.onerror();
assert.strictEqual(elements.progressWrap.hidden, true, 'bar not hidden on error');
assert.strictEqual(elements.uploadBtn.disabled, false, 'button stuck on error');
assert(elements.status.textContent.indexOf('网络错误') !== -1,
       'error status missing: ' + elements.status.textContent);
/* A late readyState 4 must not overwrite the error (idempotent finalize). */
up2.readyState = 4;
up2.status = 0;
up2.onreadystatechange();
assert(elements.status.textContent.indexOf('网络错误') !== -1,
       'late onreadystatechange overwrote error state');
console.log('3. error/robustness     : OK (' + elements.status.textContent + ')');

/* --- 4. move-to-folder UI -------------------------------------------- */
function feedList(entries) {
  const list = xhrs.filter((x) => x.url === '/list.cgi').pop();
  list.readyState = 4;
  list.status = 200;
  list.responseText = JSON.stringify(entries);
  list.onreadystatechange();
}
function clickMoveFor(name) {
  const match = created.filter((el) => el.tag === 'button' && el.textContent === '移动');
  assert(match.length > 0, 'no 移动 button rendered');
  /* The button is rendered after its name cell; use the last rendered row
   * whose move title matches the entry we want by driving the entry list in
   * a known order and picking the corresponding button index. */
  const index = entriesUnderTest.findIndex((e) => e.name === name);
  assert(index >= 0, 'entry under test not found: ' + name);
  match[index].onclick();
}
let entriesUnderTest = [
  {name: '家庭照片', size: 0, mtime: '2026-11-21T00:00:00Z', dir: true},
  {name: '临时', size: 0, mtime: '2026-11-21T00:00:00Z', dir: true},
  {name: 'report.docx', size: 10, mtime: '2026-11-21T00:00:00Z', dir: false}
];
created.length = 0;
feedList(entriesUnderTest);
clickMoveFor('家庭照片');
assert.strictEqual(elements.moveModal.hidden, false, 'move modal not shown');
assert.deepStrictEqual(elements.moveTarget.children.map((o) => o.value), ['临时'],
                       'target list must exclude the source folder');
elements.moveTarget.value = '临时';
elements.moveConfirm.onclick();
const mvXhr = xhrs.filter((x) => x.url === '/move.cgi').pop();
assert(mvXhr, 'no /move.cgi request created');
assert.strictEqual(mvXhr.method, 'POST');
assert(mvXhr.body.indexOf('name=' + encodeURIComponent('家庭照片')) === 0,
       'source name not url-encoded in move request: ' + mvXhr.body);
assert(mvXhr.body.indexOf('&to=' + encodeURIComponent('临时')) !== -1,
       'target name not url-encoded in move request: ' + mvXhr.body);
assert.strictEqual(elements.moveModal.hidden, true, 'move modal not closed on confirm');
mvXhr.readyState = 4;
mvXhr.status = 200;
mvXhr.responseText = '{"ok":true,"name":"家庭照片","to":"临时"}\n';
mvXhr.onreadystatechange();
assert(elements.status.textContent.indexOf('已移动：家庭照片 → 临时') === 0,
       'move success status missing: ' + elements.status.textContent);
console.log('4. move UI              : OK (' + elements.status.textContent + ')');

/* No subfolder at all: show a friendly hint, never an empty dropdown. */
entriesUnderTest = [{name: 'only-file.txt', size: 1, mtime: '2026-11-21T00:00:00Z', dir: false}];
created.length = 0;
feedList(entriesUnderTest);
clickMoveFor('only-file.txt');
assert.strictEqual(elements.moveModal.hidden, true, 'modal opened with no folders');
assert(elements.status.textContent.indexOf('请先新建文件夹') !== -1,
       'missing hint when no folder exists');
console.log('5. move empty folders   : OK (' + elements.status.textContent + ')');

/* --- 6. password modal: mismatch is blocked client-side --------------- */
const pwBefore = xhrs.length;
elements.passwdBtn.onclick();
assert.strictEqual(elements.passwdModal.hidden, false, 'passwd modal not shown');
elements.newPass1.value = 'temporary-A';
elements.newPass2.value = 'temporary-B';
elements.passwdConfirm.onclick();
assert(xhrs.length === pwBefore, 'mismatched passwords must not be sent');
assert(elements.passwdMsg.textContent.indexOf('不一致') !== -1,
       'mismatch hint missing: ' + elements.passwdMsg.textContent);
elements.passwdCancel.onclick();
assert.strictEqual(elements.passwdModal.hidden, true, 'cancel did not close modal');
assert.strictEqual(elements.newPass1.value, '', 'cancel did not clear password');
assert.strictEqual(elements.newPass2.value, '', 'cancel did not clear confirmation');
console.log('6. password mismatch/cancel  : OK');

/* --- 7. password change success + stale-auth messaging ---------------- */
elements.passwdBtn.onclick();
elements.newPass1.value = '临时口令 Test 123';
elements.newPass2.value = '临时口令 Test 123';
const listsBeforePw = xhrs.filter((x) => x.url === '/list.cgi').length;
elements.passwdConfirm.onclick();
const pwXhr = xhrs.filter((x) => x.url === '/chpasswd.cgi').pop();
assert(pwXhr, 'no /chpasswd.cgi request created');
assert.strictEqual(pwXhr.method, 'POST');
assert.strictEqual(pwXhr.headers['Content-Type'], 'application/x-www-form-urlencoded');
assert.strictEqual(pwXhr.body,
  'new_password=' + encodeURIComponent('临时口令 Test 123'),
  'unexpected password body: ' + pwXhr.body);
pwXhr.readyState = 4;
pwXhr.status = 200;
pwXhr.responseText = '{"ok":true}\n';
pwXhr.onreadystatechange();
assert.strictEqual(elements.passwdModal.hidden, true, 'modal not closed on success');
assert.strictEqual(elements.newPass1.value, '', 'password left in DOM after success');
assert(elements.status.textContent.indexOf('请用新密码重新登录') !== -1,
       'success must explain re-login: ' + elements.status.textContent);
assert(xhrs.filter((x) => x.url === '/list.cgi').length === listsBeforePw,
       'must not refresh() with stale Basic credentials after a password change');
/* Any later 401 must explain the stale cache instead of a generic hint. */
elements.refreshBtn.onclick();
const refreshAfterPw = xhrs.filter((x) => x.url === '/list.cgi').pop();
refreshAfterPw.readyState = 4;
refreshAfterPw.status = 401;
refreshAfterPw.onreadystatechange();
assert(elements.status.textContent.indexOf('关闭并重新打开浏览器') !== -1,
       'stale-auth hint missing after 401: ' + elements.status.textContent);
console.log('7. password success/re-login  : OK');

/* --- 8. backend error is shown from the JSON error field -------------- */
elements.passwdBtn.onclick();
elements.newPass1.value = 'another-temporary';
elements.newPass2.value = 'another-temporary';
elements.passwdConfirm.onclick();
const pwFail = xhrs.filter((x) => x.url === '/chpasswd.cgi').pop();
pwFail.readyState = 4;
pwFail.status = 400;
pwFail.responseText = '{"ok":false,"error":"malformed new_password"}';
pwFail.onreadystatechange();
assert.strictEqual(elements.passwdModal.hidden, false, 'modal must stay open on failure');
assert(elements.passwdMsg.textContent.indexOf('malformed new_password') !== -1,
       'backend error not shown inside modal: ' + elements.passwdMsg.textContent);
assert.strictEqual(elements.passwdConfirm.disabled, false, 'confirm stuck disabled');
console.log('8. password backend error     : OK');

console.log('ALL UI TESTS PASSED');
