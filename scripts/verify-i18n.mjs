// Browser regressions for language changes. Always uses the isolated local backend.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(join(process.env.HOME, '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright')); }
const base = new URL(process.env.QA_I18N_URL || 'http://127.0.0.1:8000/');
base.searchParams.set('backend', 'local');
const url = hash => { const value = new URL(base); value.hash = hash; return value.href; };
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await playwright.chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) });
try {
  const context = await browser.newContext({ locale: 'en-US', viewport: { width: 1365, height: 900 }, acceptDownloads: true });
  const page = await context.newPage(), errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(url('home'));
  const language = page.locator('[data-language-select]:visible');
  assert.equal(await language.inputValue(), 'en');
  await page.getByRole('button', { name: 'Open Board Games', exact: true }).waitFor();
  const library = await page.evaluate(() => {
    const i = FriendsI18n, bank = QA_QUESTIONS, before = JSON.stringify(bank);
    const values = [i.detect(['fr', 'zh-HK']), i.detect(['de']), i.detect(['zh-Hans']), i.detect(['en-GB'])];
    const custom = [bank[0], '登录'];
    const translated = i.questionBank(bank), preserved = i.questionBank(custom);
    const slots = value => [...new Set(value.match(/\{\d+\}/g) || [])].sort().join();
    const valid = FRIENDS_I18N_CATALOG.messages.every(row => row.length === 3 && row.every(Boolean) && slots(row[0]) === slots(row[1]) && slots(row[0]) === slots(row[2]));
    const lengths = Object.values(FRIENDS_I18N_CATALOG.questions).map(q => q.length);
    return { values, first: translated[0], last: translated[99], custom: preserved, unchanged: before === JSON.stringify(bank), valid, lengths };
  });
  assert.deepEqual(library.values, ['zh-TW', 'zh-CN', 'zh-CN', 'en']);
  assert.equal(library.first, 'Sunny or rainy?');
  assert.equal(library.last, "What would you like to say to tomorrow's you?");
  assert.deepEqual(library.custom, ['晴天 or 雨天?', '登录']);
  assert(library.unchanged && library.valid);
  assert.deepEqual(library.lengths, [100, 100]);
  // Test system history from both local and SQL RPCs, including display-name collisions.
  const logs = await page.evaluate(() => {
    const node = document.createElement('section');
    node.innerHTML = ['登录 向 开始 支付租金 900。', '北京胡同 暂无主人，可以购买。', '登录 支付费用 900。', '登录 将 北京胡同 升级。'].map(FriendsI18n.logHtml).join('');
    FriendsI18n.apply(node); return [...node.children].map(n => n.textContent);
  });
  assert.deepEqual(logs, ['登录 paid 900 rent to 开始.', 'Beijing Hutong is unowned and available to buy.', '登录 paid a fee of 900.', '登录 upgraded Beijing Hutong.']);
  await page.goto(url('account/register'));
  await page.locator('#account-username').fill('language_test');
  await page.locator('#account-display-name').fill('登录');
  await page.locator('#account-password').fill('testpass123');
  await page.locator('#account-password-confirm').fill('testpass123');
  await page.locator('#account-security-answer').fill('中文答案 English7');
  await page.evaluate(() => { window.draftNode = document.querySelector('#account-security-answer'); });
  for (const code of ['zh-TW', 'zh-CN', 'en']) {
    await language.selectOption(code);
    assert.equal(await page.inputValue('#account-security-answer'), '中文答案 English7');
    assert(await page.evaluate(() => window.draftNode === document.querySelector('#account-security-answer')));
  }
  await page.locator('[data-account=register] button[type=submit]').click();
  await page.locator('[data-action=account-logout]').waitFor();
  assert.equal(await page.locator('.account-panel > p.muted').textContent(), '登录');
  await page.goto(url('qa/create'));
  await page.locator('[data-create-submit]').click();
  await page.locator('[data-action=join-room] button[type=submit]').click();
  await page.locator('textarea[data-question]').first().fill('游戏大厅 <b>原样</b> 😀');
  await language.selectOption('zh-TW');
  assert.equal(await page.locator('[data-i18n-question="1"]').textContent(), '此時此刻在哪裡?天氣?感受如何?');
  await language.selectOption('en');
  assert.equal(await page.locator('[data-i18n-question="0"]').textContent(), 'Sunny or rainy?');
  assert.equal(await page.locator('textarea[data-question]').first().inputValue(), '游戏大厅 <b>原样</b> 😀');
  await page.reload();
  assert.equal(await language.inputValue(), 'en');
  assert.equal(await page.locator('textarea[data-question]').first().inputValue(), '游戏大厅 <b>原样</b> 😀');
  await page.goto(url('spin'));
  await page.locator('#spin-title').fill('游戏大厅');
  await page.locator('#spin-options').fill('登录\n开始');
  await page.locator('[data-spin=create] button[type=submit]').click();
  await page.locator('#spin-options-panel > summary').click();
  await language.selectOption('zh-TW');
  assert.equal(await page.locator('#spin-room-title').textContent(), '游戏大厅');
  assert((await page.locator('#spin-option-list').innerText()).includes('登录'));
  assert(await page.locator('#spin-options-panel').getAttribute('open') !== null);
  await page.goto(url('tycoon'));
  await page.locator('[data-action=tycoon-create-room] button[type=submit]').click();
  await page.waitForURL(/#tycoon\/room\//);
  await page.setViewportSize({ width: 390, height: 844 });
  await language.selectOption('en');
  assert.equal(await language.count(), 1);
  await page.goto(url('home'));
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  const independent = await browser.newContext({ locale: 'zh-TW' });
  const other = await independent.newPage();
  await other.goto(url('home'));
  assert.equal(await other.inputValue('[data-language-select]'), 'zh-TW');
  assert.equal(await language.inputValue(), 'en');
  assert.deepEqual(errors, []);
  console.log('Language detection, catalog, logs, raw content, draft retention, default questions, persistence and mobile controls: PASS');
} finally { await browser.close(); }
