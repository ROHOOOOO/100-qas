import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(join(process.env.HOME, '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright')); }
const base = process.env.QA_ONLINE_URL?.replace(/\/$/, '');
if (!base) throw new Error('Set QA_ONLINE_URL to an isolated test deployment. This test creates accounts.');
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await playwright.chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) });
const failures = [], screenshots = [];
async function login(page, url, account, password) {
  await page.goto(url+'#account');
  await page.getByLabel('账号', { exact: true }).fill(account);
  await page.getByLabel('密码', { exact: true }).fill(password);
  await page.locator('form[data-account="login"] button[type="submit"]').click();
  await page.getByRole('heading', { name: '我的记录', exact: true }).waitFor();
}
async function chineseAnswer(page, selector, value) {
  const input = page.locator(selector);
  assert.equal(await input.getAttribute('type'), 'text');
  await input.focus();
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Input.imeSetComposition', { text: value, selectionStart: value.length, selectionEnd: value.length });
  await cdp.send('Input.insertText', { text: value });
  await cdp.detach();
  assert.equal(await input.inputValue(), value);
}
async function run(local) {
  const url = base + '/' + (local ? '?backend=local' : '');
  const context = await browser.newContext({ viewport: { width: 1365, height: 950 } });
  const page = await context.newPage();
  let expectRevocation = false;
  function health(p) {
    p.on('pageerror', error => failures.push(error.message));
    p.on('console', message => {
      if (message.type() === 'error' && !(expectRevocation && /400/.test(message.text()))) failures.push(message.text());
    });
  }
  health(page);
  try {
    const account = 'profile_' + Date.now().toString().slice(-9), password = 'firstPassword', nextPassword = 'nextPassword';
    await page.goto(url+'#spin');
    await page.getByRole('heading', { name: '登录', exact: true }).waitFor();
    await page.getByRole('link', { name: '注册新账号', exact: true }).click();
    await page.getByRole("heading", { name: "注册新账号", exact: true }).waitFor();
    await page.getByLabel('账号', { exact: true }).fill(account);
    await page.getByLabel('用户名', { exact: true }).fill('小满');
    await page.locator('#account-password').fill(password);
    await page.getByLabel('确认密码', { exact: true }).fill('mismatch');
    await page.getByLabel('密保问题', { exact: true }).selectOption('2');
    await chineseAnswer(page, '#account-security-answer', '蓝色列车Train7');
    await page.getByRole('button', { name: '隐藏答案', exact: true }).click();
    assert.equal(await page.locator('#account-security-answer').getAttribute('type'), 'password');
    await page.getByRole('button', { name: '显示答案', exact: true }).click();
    assert.equal(await page.locator('#account-security-answer').inputValue(), '蓝色列车Train7');
    if (!local) {
      await page.evaluate(() => scrollTo(0,0));
      const shot = join(tmpdir(), 'account-register-desktop.png');
      await page.screenshot({ path: shot, fullPage: true }); screenshots.push(shot);
    }
    await page.getByRole('button', { name: '注册并登录' }).click();
    await page.getByText('两次输入的密码不一致。', { exact: true }).waitFor();
    await page.getByLabel('确认密码', { exact: true }).fill(password);
    await page.getByRole('button', { name: '注册并登录' }).click();
    await page.getByRole('heading', { name: 'What’s Next?', exact: true }).waitFor();
    await page.getByLabel('房间名称').fill('一起吃什么');
    await page.getByLabel('转盘选项').fill('火锅\n日料');
    await page.getByRole('button', { name: '创建转盘房间' }).click();
    await page.locator('#spin-draw-button').waitFor();
    const spinUrl = page.url();
    await page.locator('#spin-history-panel > summary').click();
    await page.locator('#spin-draw-button').click();
    await page.waitForFunction(() => document.querySelectorAll('.spin-history-item').length === 1);
    assert((await page.locator('#spin-history').innerText()).includes('小满'));
    assert(!(await page.locator('body').innerText()).includes(account));
    await page.goto(url+'#qa/create');
    await page.getByRole('button', { name: '自定义题库' }).click();
    await page.getByLabel('粘贴题目').fill('你今天好吗？');
    await page.getByRole('button', { name: '生成房间' }).click();
    await page.getByRole('button', { name: '开始答题' }).waitFor();
    assert.equal(await page.locator('input[name="nickname"]').count(), 0);
    await page.getByRole('button', { name: '开始答题' }).click();
    await page.locator('textarea[data-question="1"]').fill('很好');
    await page.getByRole('button', { name: '提交答案', exact: true }).click();
    await page.getByRole('button', { name: '确认提交', exact: true }).click();
    await page.getByRole('heading', { name: '大家的答案' }).waitFor();
    const qaUrl = page.url();
    await page.goto(url+'#tycoon');
    assert.equal(await page.locator('input[name="nickname"]').count(), 0);
    await page.getByRole('button', { name: '创建 Friends Tycoon 房间' }).click();
    await page.getByText('至少 2 人开始').waitFor();
    const tycoonUrl = page.url();
    await page.goto(url+'#account/settings');
    await page.getByLabel('用户名', { exact: true }).fill('晚风');
    await page.getByRole('button', { name: '保存用户名' }).click();
    await page.getByText('用户名已更新。', { exact: true }).waitFor();
    await page.reload();
    assert.equal(await page.getByLabel('用户名', { exact: true }).inputValue(), '晚风');
    await page.goto(qaUrl);
    await page.locator('.answer-row strong').waitFor();
    assert.equal(await page.locator('.answer-row strong').innerText(), '小满');
    assert.equal(await page.locator('.player-row strong').innerText(), '晚风');
    await page.goto(tycoonUrl);
    await page.locator('.tycoon-player-list').first().getByText('晚风').waitFor();
    assert(!(await page.locator('body').innerText()).includes(account));
    await page.goto(spinUrl);
    await page.locator('#spin-members').waitFor();
    assert.equal(await page.locator('#spin-members').innerText(), '晚风');
    assert((await page.locator('#spin-history').innerText()).includes('小满'));
    await page.locator('#spin-draw-button').click();
    await page.waitForFunction(() => document.querySelectorAll('.spin-history-item').length === 2);
    assert((await page.locator('.spin-history-item').first().innerText()).includes('晚风'));
    const otherContext = local ? context : await browser.newContext({ viewport: { width: 390, height: 844 } });
    const other = await otherContext.newPage(); health(other);
    if (local) { await other.goto(url+'#account'); await other.getByRole('heading', { name: '我的记录' }).waitFor(); }
    else await login(other, url, account, password);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(url+'#account/recover');
    await page.getByLabel('账号', { exact: true }).fill(account);
    await page.getByRole('button', { name: '下一步', exact: true }).click();
    await page.getByText('你第一次独自旅行的目的地是哪里？', { exact: true }).waitFor();
    await page.getByLabel('密保答案', { exact: true }).fill('wrong');
    await page.getByRole('button', { name: '验证答案' }).click();
    await page.getByText('账号或密保答案不正确，请检查后重试。', { exact: true }).waitFor();
    if (!local) {
      await page.evaluate(() => scrollTo(0,0));
      const shot = join(tmpdir(), 'account-recovery-mobile.png');
      await page.screenshot({ path: shot, fullPage: true }); screenshots.push(shot);
    }
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth+1));
    await page.getByLabel('密保答案', { exact: true }).fill('');
    await chineseAnswer(page, '#recovery-answer', '  蓝色列车TRAIN7 ');
    await page.getByRole('button', { name: '验证答案' }).click();
    await page.locator('#account-password').fill(nextPassword);
    await page.getByLabel('确认密码', { exact: true }).fill(nextPassword);
    expectRevocation = true;
    await page.getByRole('button', { name: '重设密码', exact: true }).click();
    await page.getByRole('heading', { name: '登录', exact: true }).waitFor();
    await other.goto(spinUrl);
    await other.getByRole('heading', { name: '登录', exact: true }).waitFor();
    expectRevocation = false;
    await login(page, url, account, nextPassword);
    await page.reload();await page.getByRole('heading', { name: '我的记录', exact: true }).waitFor();
    console.log('Account UI passed:', local ? 'local preview' : 'PostgreSQL backend');
    if (!local) await otherContext.close();
  } catch(error) {
    console.error('Failure at', page.url(), (await page.locator('body').innerText()).slice(-1600));
    await page.screenshot({ path: join(tmpdir(), 'account-test-error.png'), fullPage: true });
    throw error;
  } finally { await context.close(); }
}
try {
  await run(false); await run(true);
  assert.deepEqual(failures, []);
  console.log(JSON.stringify({ passed: true, consoleErrors: failures, screenshots }));
} finally { await browser.close(); }
