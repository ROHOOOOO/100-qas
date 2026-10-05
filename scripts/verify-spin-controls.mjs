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
if (!base) throw new Error('Set QA_ONLINE_URL to an isolated test deployment; this test creates accounts and rooms.');
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await playwright.chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) });
const errors = [], screenshots = [];
const open = (page, name) => page.locator('#spin-' + name + '-panel').evaluate(node => node.open);
async function finish(page, count) {
  await page.waitForFunction(expected => document.querySelectorAll('.spin-history-item').length === expected && !document.querySelector('#spin-draw-button').disabled, count, { timeout: 15000 });
}
async function angle(page) {
  return page.locator('.spin-disc').evaluate(node => {
    const m = new DOMMatrix(getComputedStyle(node).transform);
    return (Math.atan2(m.b, m.a) * 180 / Math.PI + 360) % 360;
  });
}
async function run(local) {
  const url = base + '/' + (local ? '?backend=local' : '');
  const context = await browser.newContext({ viewport: { width: 1365, height: 950 } });
  const page = await context.newPage();
  let expectedNetworkFailure = false;
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', message => {
    if (['error','warning'].includes(message.type()) && !(expectedNetworkFailure && /ERR_FAILED/.test(message.text()))) errors.push(message.text());
  });
  async function room() {
    return page.evaluate(async local => {
      const token = JSON.parse(localStorage.getItem(local ? 'friends-games-local-auth-session-v1' : 'friends-games-auth-session-v1')).token;
      const args = { p_room_code: location.hash.split('/').at(-1), p_account_token: token };
      return local ? window.LocalGames.rpc('spin_get_room', args) : (await fetch('/rest/v1/rpc/spin_get_room', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(args) })).json();
    }, local);
  }
  async function checkPointer() {
    const saved = await room(), draw = saved.lastShared;
    assert.equal(await page.locator('#spin-result strong').innerText(), draw.result);
    const atPointer = (360 - await angle(page) + 360) % 360;
    assert.equal(Math.floor(atPointer / (360 / draw.options.length)), draw.index, 'Pointer must agree with the saved result');
    return draw;
  }
  async function createRoom(title, options) {
    await page.goto(url + '#spin');
    await page.getByLabel('房间名称', { exact: true }).fill(title);
    await page.getByLabel('转盘选项', { exact: true }).fill(options.join('\n'));
    await page.getByRole('button', { name: '创建转盘房间', exact: true }).click();
    await page.locator('#spin-draw-button').waitFor();
  }
  try {
    await page.goto(url + '#account/register');
    await page.getByRole('heading', { name: '注册新账号', exact: true }).waitFor();
    await page.getByLabel('账号', { exact: true }).fill('fold_' + Date.now().toString().slice(-9));
    await page.getByLabel('用户名', { exact: true }).fill('小满');
    await page.locator('#account-password').fill('testing123');
    await page.getByLabel('确认密码', { exact: true }).fill('testing123');
    await page.getByLabel('密保答案', { exact: true }).fill('中文密保7');
    await page.getByRole('button', { name: '注册并登录' }).click();
    await page.getByRole('heading', { name: '我的记录', exact: true }).waitFor();
    await createRoom('今天吃什么', ['火锅','烧烤','日料','饺子','披萨']);
    const firstRoom = page.url();
    assert.equal(await page.title(), '今天吃什么 | What’s Next?');
    for (const name of ['options','history']) assert.equal(await open(page,name),false);
    assert.equal(await page.locator('#spin-option-list').isVisible(),false);
    assert.equal(await page.locator('#spin-history').isVisible(),false);
    assert.equal(await page.locator('#spin-option-count').innerText(),'（5）');
    await page.locator('#spin-options-panel > summary').press('Enter');
    assert.equal(await open(page,'options'),true);
    assert.equal(await open(page,'history'),false);
    await page.reload();await page.locator('#spin-draw-button').waitFor();
    assert.equal(await open(page,'options'),true);assert.equal(await open(page,'history'),false);
    await page.locator('#spin-options-panel > summary').click();
    await page.locator('#spin-draw-button').click();await finish(page,1);
    await checkPointer();assert.equal(await open(page,'history'),false);
    assert.equal(await open(page,'options'),false);
    const previousAngle = await angle(page);
    if (!local) {
      await page.evaluate(() => scrollTo(0,0));
      const path=join(tmpdir(),'spin-panels-collapsed-desktop.png');await page.screenshot({path,fullPage:true});screenshots.push(path);
    }
    await page.locator('#spin-draw-button').click();
    await page.waitForFunction(() => document.querySelector('.spin-disc')?.getAnimations().length > 0);
    const frames = await page.locator('.spin-disc').evaluate(node => node.getAnimations()[0].effect.getKeyframes().map(f => f.transform));
    const from=Number(frames[0].match(/rotate\(([-\d.]+)deg\)/)[1]);
    assert(Math.abs(from-previousAngle)<.01,'Second animation must continue from the previous angle');
    await page.reload();await finish(page,2);await checkPointer();
    assert.equal(await open(page,'history'),false,'Polling/reloading must not expand history');
    // A response lost after saving must be retried using the same request, without an extra draw.
    expectedNetworkFailure=true;
    if (local) await page.evaluate(() => {
      const original=window.LocalGames.rpc;let lose=true;
      window.LocalGames.rpc=async function(name,args){const result=await original(name,args);if(name==='spin_draw'&&lose){lose=false;throw new Error('Simulated response loss');}return result;};
    });
    else {
      let lose=true;
      await page.route('**/rest/v1/rpc/spin_draw',async route=>{
        if(lose){lose=false;await route.fetch();await route.abort('failed');}
        else await route.continue();
      });
    }
    await page.locator('#spin-draw-button').click();await finish(page,3);
    const savedBeforeRetry=(await room()).history[0];
    await page.getByRole('button',{name:'重试这次抽取',exact:true}).click();
    await page.getByRole('button',{name:'旋转转盘',exact:true}).waitFor();
    const afterRetry=await room();assert.equal(afterRetry.history.length,3);assert.equal(afterRetry.history[0].id,savedBeforeRetry.id);
    expectedNetworkFailure=false;
    await page.locator('#spin-draw-button').evaluate(button=>{button.click();button.click();});
    await finish(page,4);const newDraw=await checkPointer();assert.notEqual(newDraw.id,savedBeforeRetry.id);
    await page.locator('#spin-history-panel > summary').press('Enter');
    assert.equal(await page.locator('.spin-history-item').count(),4);
    await page.locator('.spin-history-item details').first().locator('summary').click();
    // Another draw must preserve a reader's expanded history and expanded old snapshot.
    await page.locator('#spin-draw-button').click();await finish(page,5);
    assert.equal(await open(page,'history'),true);
    assert.equal(await page.locator('.spin-history-item details[open]').count(),1);
    await page.locator('#spin-options-panel > summary').click();
    const rememberedAngle=await angle(page);
    await createRoom('许多选项',Array.from({length:50},(_,i)=>'选项'+(i+1)+'：一段中文内容'));
    assert.equal(await open(page,'options'),false);assert.equal(await open(page,'history'),false);
    assert.equal(await page.locator('#spin-option-count').innerText(),'（50）');
    await page.locator('#spin-draw-button').click();await finish(page,1);await checkPointer();
    await page.goto(firstRoom);await page.locator('#spin-draw-button').waitFor();
    assert.equal(await open(page,'options'),true);assert.equal(await open(page,'history'),true);
    assert(Math.abs(await angle(page)-rememberedAngle)<.01,'Reload must restore the same landing point');
    await page.setViewportSize({width:390,height:844});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
    if(!local){const path=join(tmpdir(),'spin-panels-expanded-mobile.png');await page.screenshot({path,fullPage:true});screenshots.push(path);}
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.locator('#spin-draw-button').click();
    await page.waitForFunction(()=>document.querySelector('#spin-draw-button').textContent==='旋转中…');
    assert.equal(await page.locator('.spin-disc').evaluate(node=>node.getAnimations().length),0);
    await finish(page,6);await checkPointer();
    console.log('Spin controls passed:',local?'local preview':'PostgreSQL backend');
  } catch(error) {
    console.error(page.url(),(await page.locator('body').innerText()).slice(-1800));
    await page.screenshot({path:join(tmpdir(),'spin-controls-failure.png'),fullPage:true});throw error;
  } finally {await context.close();}
}
try {await run(false);await run(true);assert.deepEqual(errors,[]);console.log(JSON.stringify({passed:true,consoleErrors:errors,screenshots}));}
finally {await browser.close();}
