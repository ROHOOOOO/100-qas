import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(join(process.env.HOME, '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright')); }
const { chromium } = playwright;
const assert=require('node:assert/strict');
const base=process.env.QA_ONLINE_URL?.replace(/\/$/, '');
if (!base) throw new Error('Set QA_ONLINE_URL to a test deployment; this test creates accounts and rooms.');const stamp=String(Date.now()).slice(-7);const errors=[];
(async()=>{
 const chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
 const browser=await chromium.launch({headless:true,...(existsSync(chrome)?{executablePath:chrome}:{})});
 const aContext=await browser.newContext({viewport:{width:1365,height:950}}),bContext=await browser.newContext({viewport:{width:390,height:844}});
 const a=await aContext.newPage(),b=await bContext.newPage();global.testPages=[a,b];global.testBrowser=browser;
 for(const p of [a,b]){p.on('pageerror',e=>errors.push(e.message));p.on('console',m=>{if(m.type()==='error')errors.push(m.text())});}
 async function register(page,name,url){
  await page.goto(url);await page.getByRole('heading',{name:'登录',exact:true}).waitFor();
  await page.getByRole('link',{name:'注册新账号',exact:true}).click();
  await page.getByRole("heading", { name: "注册新账号", exact: true }).waitFor();
  await page.getByLabel('账号',{exact:true}).fill(name);
  await page.getByLabel('用户名',{exact:true}).fill(name);
  await page.locator('#account-password').fill('testing123');
  await page.getByLabel('确认密码',{exact:true}).fill('testing123');
  await page.getByLabel('密保答案',{exact:true}).fill('test answer');
  await page.getByRole('button',{name:'注册并登录'}).click();
 }
 async function finish(page){await page.locator('#spin-draw-button').waitFor();await page.waitForFunction(()=>!document.querySelector('#spin-draw-button').disabled,{timeout:10000});}
 await register(a,'测试甲'+stamp,base+'/#spin');
 await a.getByRole('heading',{name:'What’s Next?',exact:true}).waitFor();
 await a.getByLabel('房间名称',{exact:true}).fill('今天吃什么');await a.getByLabel('转盘选项',{exact:true}).fill('火锅\n烧烤\n日料\n披萨\n面条\n饺子');
 await a.getByRole('button',{name:'创建转盘房间'}).click();await a.waitForURL(/#spin\/room\//);await a.locator('#spin-draw-button').waitFor();
 const link=a.url();await register(b,'测试乙'+stamp,link);
 await b.getByRole('button',{name:'加入这个房间'}).click();await b.locator('#spin-draw-button').waitFor();assert.equal(await b.locator('#spin-settings').count(),0);
 await a.getByRole('button',{name:'旋转转盘',exact:true}).click();await finish(a);await finish(b);
 await b.waitForFunction(()=>document.querySelectorAll('.spin-history-item').length===1);
 assert.equal(await a.locator('#spin-result strong').innerText(),await b.locator('#spin-result strong').innerText());
 assert.equal(await a.locator('.spin-disc').evaluate(n=>n.style.transform),await b.locator('.spin-disc').evaluate(n=>n.style.transform),'Shared viewers must see the same landing point');
 await a.reload();await a.locator('#spin-draw-button').waitFor();assert.equal(await a.getByRole('heading',{name:'登录',exact:true}).count(),0);
 console.log('Shared draw and reload passed');await a.locator('#spin-settings summary').click();await a.getByLabel('抽取模式').selectOption('individual');await a.getByRole('button',{name:'保存设置'}).click();
 await a.waitForFunction(()=>document.querySelector('#spin-mode-label')?.textContent==='各自抽取');await b.waitForFunction(()=>document.querySelector('#spin-mode-label')?.textContent==='各自抽取');
 await Promise.all([a.getByRole('button',{name:'旋转转盘',exact:true}).click(),b.getByRole('button',{name:'旋转转盘',exact:true}).click()]);await finish(a);await finish(b);
 for(const p of[a,b])await p.waitForFunction(()=>document.querySelectorAll('.spin-history-item').length===3);
 await a.evaluate(()=>scrollTo(0,0)); await b.evaluate(()=>scrollTo(0,0));
 await a.screenshot({path:join(tmpdir(),'whats-next-desktop.png'),fullPage:true});await b.screenshot({path:join(tmpdir(),'whats-next-mobile.png'),fullPage:true});
 assert(await b.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'Mobile overflow');
 // Account records, return links, and the two existing module gates.
 await a.locator('[data-action="open-account"]').click();await a.getByRole('heading',{name:'我的记录',exact:true}).waitFor();assert(await a.locator('[data-spin="open"]').count());
 await a.getByRole('button',{name:'退出登录',exact:true}).click();await a.getByRole('heading',{name:'登录',exact:true}).waitFor();
 for(const hash of['qa','tycoon','qa/room/ABCDEF']){await a.goto(base+'/#'+hash);await a.getByRole('heading',{name:'登录',exact:true}).waitFor();}
 // Local preview accounts are separate and support the full new module.
 const local=await aContext.newPage();local.on('pageerror',e=>errors.push(e.message));
 await register(local,'本地试玩',base+'/?backend=local#spin');await local.getByLabel('房间名称',{exact:true}).fill('见面玩什么');await local.getByLabel('转盘选项',{exact:true}).fill('桌游\n电影');await local.getByRole('button',{name:'创建转盘房间'}).click();await local.locator('#spin-draw-button').waitFor();await local.getByRole('button',{name:'旋转转盘',exact:true}).click();await finish(local);assert.equal(await local.locator('.spin-history-item').count(),1);await local.reload();await local.locator('#spin-draw-button').waitFor();
 await local.locator('[data-action="open-qa"]').click();await local.getByRole('button',{name:'创建房间',exact:true}).click();await local.getByRole('button',{name:'自定义题库',exact:true}).click();await local.getByLabel('粘贴题目').fill('今天开心吗？\n晚饭吃什么？');await local.getByRole('button',{name:'生成房间'}).click();await local.getByRole('button',{name:'开始答题'}).click();await local.locator('textarea[data-question="1"]').fill('开心');await local.locator('textarea[data-question="2"]').fill('火锅');
 await local.locator('[data-action="submit-answers"]').click();await local.locator('[data-action="confirm-submit"]').click();await local.locator('[data-action="open-qa-export"]').waitFor();
 console.log(JSON.stringify({passed:true,room:link,consoleErrors:errors,screenshots:[join(tmpdir(),'whats-next-desktop.png'),join(tmpdir(),'whats-next-mobile.png')]}));
 assert.equal(errors.length,0,errors.join('\n'));
 await browser.close();
})().catch(async e=>{console.error(e);for(const [i,p] of (global.testPages||[]).entries()){console.error('form-state',await p.locator('form').evaluateAll(forms=>forms.map(f=>({valid:f.checkValidity(),fields:[...f.querySelectorAll('input')].map(n=>({id:n.id,length:n.value.length,valid:n.checkValidity()})),disabled:f.querySelector('fieldset')?.disabled}))));console.error(i,p.url(),(await p.locator('body').innerText()).slice(-2400));await p.screenshot({path:join(tmpdir(),'whats-next-error-'+i+'.png')});}if(global.testBrowser)await global.testBrowser.close();process.exit(1)});
