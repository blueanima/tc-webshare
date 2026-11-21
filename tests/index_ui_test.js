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
const ids = [
  'status', 'rows', 'file', 'folder', 'uploadBtn', 'progressWrap',
  'progressFill', 'progressText', 'refreshBtn', 'mkdirBtn'
];
for (const id of ids) {
  elements[id] = {
    id: id,
    hidden: id === 'progressWrap',
    disabled: false,
    value: '',
    textContent: '',
    innerHTML: '',
    className: '',
    style: {},
    files: [],
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
    createElement: () => ({ style: {}, appendChild() {}, setAttribute() {} })
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

console.log('ALL UI TESTS PASSED');
