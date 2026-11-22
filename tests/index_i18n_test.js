/*
 * index_i18n_test.js - headless tests for the bilingual UI in deploy/index.html.
 *
 * Runs the real inline script in a minimal DOM/XHR/localStorage sandbox and
 * checks that:
 *   1. first visit defaults to Chinese and fills every static string
 *   2. switching to English updates static text and the rendered file list
 *      without issuing another /list.cgi request
 *   3. already-visible status / password-modal / move-hint strings follow the
 *      new language (including {name} placeholders)
 *   4. the choice persists in localStorage and is restored on the next load;
 *      invalid or unavailable storage falls back to Chinese
 *   5. zh and en dictionaries have identical keys and no visible Chinese is
 *      hardcoded outside the dictionary
 *   6. existing upload paths still work in both languages
 *
 * No browser, no npm modules, no network.  Run: node tests/index_i18n_test.js
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
const source = matched[1];

const IDS = [
  'appTitle', 'appSubtitle', 'langLabel', 'labelFile', 'labelFolder',
  'uploadBtn', 'mkdirBtn', 'refreshBtn', 'passwdBtn', 'langSelect',
  'folder', 'file', 'status', 'progressWrap', 'progressFill', 'progressText',
  'thName', 'thSize', 'thMtime', 'thOp', 'rows',
  'moveModal', 'moveTitle', 'moveInfo', 'moveTargetLabel', 'moveTarget',
  'moveConfirm', 'moveCancel',
  'passwdModal', 'passwdTitle', 'passwdDesc', 'passwdLabel1', 'newPass1',
  'passwdLabel2', 'newPass2', 'passwdMsg', 'passwdConfirm', 'passwdCancel'
];

function makeHarness(store, withStorage) {
  const elements = {};
  const created = [];
  const xhrs = [];

  for (const id of IDS) {
    elements[id] = {
      id: id,
      hidden: id === 'progressWrap' || id === 'moveModal',
      disabled: false,
      value: '',
      textContent: '',
      innerHTML: '',
      className: '',
      placeholder: '',
      title: '',
      style: {},
      files: [],
      children: [],
      appendChild(child) { this.children.push(child); },
      focus() {},
      onclick: null,
      onchange: null
    };
  }
  elements.file.files = [{name: 'notes.txt', size: 1024}];

  class FakeXHR {
    constructor() {
      this.readyState = 0;
      this.status = 0;
      this.responseText = '';
      this.upload = {};
      this.headers = {};
      xhrs.push(this);
    }
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(key, value) { this.headers[key] = value; }
    send(body) { this.body = body; }
  }
  class FakeFormData {
    constructor() { this.parts = []; }
    append(name, file) { this.parts.push([name, file]); }
  }

  const documentElement = {lang: ''};
  const doc = {
    documentElement: documentElement,
    getElementById: (id) => elements[id] || null,
    createElement: (tag) => {
      const el = {
        tag: tag, style: {}, children: [], textContent: '', title: '', value: '',
        appendChild(child) { this.children.push(child); },
        setAttribute() {}
      };
      created.push(el);
      return el;
    }
  };
  const sandbox = {
    document: doc,
    window: {performance: {now: () => 1000}, confirm: () => true},
    performance: {now: () => 1000},
    XMLHttpRequest: FakeXHR,
    FormData: FakeFormData,
    console: console
  };
  if (withStorage) {
    sandbox.localStorage = {
      getItem: (key) => Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null,
      setItem: (key, value) => { store[key] = value; }
    };
  }
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, {filename: 'index.html:inline (i18n)'});
  return {elements, created, xhrs, sandbox, documentElement};
}

function feedList(h, entries) {
  const list = h.xhrs.filter((x) => x.url === '/list.cgi').pop();
  assert(list, 'no /list.cgi request');
  list.readyState = 4;
  list.status = 200;
  list.responseText = JSON.stringify(entries);
  list.onreadystatechange();
}

function switchLang(h, value) {
  h.elements.langSelect.value = value;
  h.elements.langSelect.onchange();
}

function renderedButtons(h, label) {
  return h.created.filter((el) => el.tag === 'button' && el.textContent === label);
}

/* --- 1. first visit: Chinese, every static string filled -------------- */
const store = {};
const h = makeHarness(store, true);
assert.strictEqual(h.documentElement.lang, 'zh-CN', 'default html lang not zh-CN');
assert.strictEqual(h.elements.appTitle.textContent, 'tc-webshare · 文件共享');
assert.strictEqual(h.elements.appSubtitle.textContent.indexOf('仅可信内网使用') !== -1, true);
assert.strictEqual(h.elements.uploadBtn.textContent, '上传');
assert.strictEqual(h.elements.mkdirBtn.textContent, '创建');
assert.strictEqual(h.elements.refreshBtn.textContent, '刷新列表');
assert.strictEqual(h.elements.passwdBtn.textContent, '修改密码');
assert.strictEqual(h.elements.langLabel.textContent, '界面语言');
assert.strictEqual(h.elements.thName.textContent, '名称');
assert.strictEqual(h.elements.folder.placeholder.indexOf('名称') === 0, true);
assert.strictEqual(h.elements.folder.title.indexOf('最多 200 字节') === 0, true);
assert.strictEqual(h.elements.rows.innerHTML.indexOf('加载中…') !== -1, true);
assert.strictEqual(store['tcws-lang'], 'zh');
console.log('1. default zh / static copy  : OK');

/* --- 2. switch to en: static + rendered list, no extra request -------- */
const entries = [
  {name: '家庭照片', size: 0, mtime: '2026-11-21T00:00:00Z', dir: true},
  {name: 'report.docx', size: 10, mtime: '2026-11-21T00:00:00Z', dir: false}
];
h.created.length = 0;
feedList(h, entries);
assert(renderedButtons(h, '移动').length === 2, 'zh move buttons missing');
assert(renderedButtons(h, '删除').length === 2, 'zh delete buttons missing');
const listCount = h.xhrs.filter((x) => x.url === '/list.cgi').length;
switchLang(h, 'en');
assert.strictEqual(h.documentElement.lang, 'en');
assert.strictEqual(h.elements.appTitle.textContent, 'tc-webshare · File Sharing');
assert.strictEqual(h.elements.uploadBtn.textContent, 'Upload');
assert.strictEqual(h.elements.passwdBtn.textContent, 'Change password');
assert.strictEqual(h.elements.thMtime.textContent, 'Modified');
assert.strictEqual(h.elements.folder.placeholder.indexOf('Name:') === 0, true);
assert.strictEqual(h.elements.folder.title.indexOf('Max 200 bytes') === 0, true);
assert.strictEqual(h.xhrs.filter((x) => x.url === '/list.cgi').length, listCount,
  'language switch must re-render from cache, not re-fetch');
assert.strictEqual(renderedButtons(h, 'Move').length, 2, 'en move buttons missing');
assert.strictEqual(renderedButtons(h, 'Delete').length, 2, 'en delete buttons missing');
assert.strictEqual(h.created.filter((el) => el.tag === 'a' && el.textContent === 'Download').length, 1,
  'en download link missing');
assert.strictEqual(renderedButtons(h, 'Move')[0].title.indexOf('another folder') !== -1, true,
  'en move title missing');
assert.strictEqual(store['tcws-lang'], 'en');
console.log('2. switch en / list re-render : OK');

/* --- 3. status strings follow the switch ------------------------------ */
h.elements.folder.value = '';
h.elements.mkdirBtn.onclick();
assert.strictEqual(h.elements.status.textContent, 'Enter a folder name');
h.created.length = 0;
switchLang(h, 'zh');
assert.strictEqual(h.elements.status.textContent, '请输入文件夹名称');
assert.strictEqual(renderedButtons(h, '移动').length, 2, 'zh render after switch missing');
switchLang(h, 'en');
assert.strictEqual(h.elements.status.textContent, 'Enter a folder name');
console.log('3. dynamic status re-render  : OK');

/* --- 4. password hint and move hint re-render ------------------------- */
h.elements.passwdBtn.onclick();
h.elements.newPass1.value = 'alpha';
h.elements.newPass2.value = 'beta';
h.elements.passwdConfirm.onclick();
assert.strictEqual(h.elements.passwdMsg.textContent, 'Passwords do not match');
switchLang(h, 'zh');
assert.strictEqual(h.elements.passwdMsg.textContent, '两次密码不一致');
switchLang(h, 'en');
assert.strictEqual(h.elements.passwdMsg.textContent, 'Passwords do not match');
h.elements.passwdCancel.onclick();
assert.strictEqual(h.elements.passwdMsg.textContent, '', 'cancel must clear password hint');

h.created.length = 0;
switchLang(h, 'zh');
const zhMoves = renderedButtons(h, '移动');
zhMoves[zhMoves.length - 1].onclick();   // last button belongs to report.docx
assert.strictEqual(h.elements.moveModal.hidden, false, 'move modal not shown');
assert.strictEqual(h.elements.moveInfo.textContent.indexOf('将「report.docx」移动到') === 0, true,
  'zh move hint missing: ' + h.elements.moveInfo.textContent);
assert.strictEqual(h.elements.moveTarget.children.length, 1, 'target folders lost');
switchLang(h, 'en');
assert.strictEqual(h.elements.moveInfo.textContent.indexOf('Move "report.docx" into') === 0, true,
  'en move hint missing: ' + h.elements.moveInfo.textContent);
assert.strictEqual(h.elements.moveModal.hidden, false, 'switch closed the move modal');
console.log('4. modal/hint re-render      : OK');

/* --- 5. persisted en is restored; bad/missing storage falls back ------ */
const storedEn = {'tcws-lang': 'en'};
const hEn = makeHarness(storedEn, true);
assert.strictEqual(hEn.documentElement.lang, 'en');
assert.strictEqual(hEn.elements.uploadBtn.textContent, 'Upload');
assert.strictEqual(hEn.elements.langSelect.value, 'en');
assert.strictEqual(hEn.elements.rows.innerHTML.indexOf('Loading…') !== -1, true);

const storedBad = {'tcws-lang': 'fr'};
const hBad = makeHarness(storedBad, true);
assert.strictEqual(hBad.documentElement.lang, 'zh-CN', 'invalid stored language must fall back');
assert.strictEqual(hBad.elements.uploadBtn.textContent, '上传');

const hNoStore = makeHarness({}, false);
assert.strictEqual(hNoStore.documentElement.lang, 'zh-CN', 'missing localStorage must fall back');
assert.strictEqual(hNoStore.elements.appTitle.textContent, 'tc-webshare · 文件共享');
console.log('5. persistence / fallback    : OK');

/* --- 6. dictionary parity and single source of truth ------------------ */
const zhStart = source.indexOf('zh: {');
const enStart = source.indexOf('en: {');
const dictEnd = source.indexOf('\n  };', enStart);
assert(zhStart !== -1 && enStart > zhStart && dictEnd > enStart, 'I18N blocks not found');
const zhBlock = source.slice(zhStart, enStart);
const enBlock = source.slice(enStart, dictEnd);
const keyList = (block) => Array.from(block.matchAll(/'([^']+)':/g), (m) => m[1]);
const zhKeys = keyList(zhBlock);
const enKeys = keyList(enBlock);
assert(zhKeys.length > 60, 'too few translation keys: ' + zhKeys.length);
assert.deepStrictEqual(zhKeys, enKeys, 'zh/en dictionaries must have identical key sets');
assert.strictEqual(new Set(zhKeys).size, zhKeys.length, 'duplicate translation keys');
for (const block of [zhBlock, enBlock]) {
  const values = Array.from(block.matchAll(/'([^']+)':\s*'([^']*)'/g), (m) => m[2]);
  assert.strictEqual(values.length, zhKeys.length, 'empty or malformed translation value');
  assert(values.every((v) => v.length > 0), 'empty translation value');
}
const htmlStart = html.indexOf('var I18N = {');
const htmlEnd = html.indexOf('\n  };', htmlStart) + 5;
const outside = html.slice(0, htmlStart) + html.slice(htmlEnd);
const cjk = outside.match(/[\u3400-\u9fff]+/g) || [];
assert.deepStrictEqual(cjk, ['中文'],
  'visible Chinese hardcoded outside I18N (only the language endonym is allowed): ' + cjk.join(','));
console.log('6. dictionary parity         : OK (' + zhKeys.length + ' keys)');

/* --- 7. upload still works in both languages -------------------------- */
const hUp = makeHarness({'tcws-lang': 'en'}, true);
hUp.elements.uploadBtn.onclick();
const up = hUp.xhrs.filter((x) => x.url === '/upload.cgi').pop();
assert(up, 'no upload request');
up.onerror();
assert.strictEqual(hUp.elements.status.textContent,
  'Upload failed: network error. Check your connection and try again.');
assert.strictEqual(hUp.elements.progressWrap.hidden, true, 'progress bar stuck on error');
assert.strictEqual(hUp.elements.uploadBtn.disabled, false, 'upload button stuck on error');
switchLang(hUp, 'zh');
assert.strictEqual(hUp.elements.status.textContent, '上传失败：网络错误，请检查连接后重试');
hUp.elements.uploadBtn.onclick();
const up2 = hUp.xhrs.filter((x) => x.url === '/upload.cgi').pop();
up2.readyState = 4;
up2.status = 200;
up2.responseText = 'OK files=1 bytes=1024\n';
up2.onreadystatechange();
assert.strictEqual(hUp.elements.status.textContent.indexOf('上传完成：') === 0, true,
  'zh upload success missing: ' + hUp.elements.status.textContent);
console.log('7. upload i18n / regression  : OK');

console.log('ALL I18N UI TESTS PASSED');
