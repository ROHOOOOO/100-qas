import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { tmpdir } from "node:os";

const require = createRequire(import.meta.url);

function loadPlaywright() {
  try {
    return require("playwright");
  } catch (error) {
    const bundledPath = join(
      process.env.HOME,
      ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"
    );
    if (!existsSync(bundledPath)) {
      throw error;
    }
    return require(bundledPath);
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function launchBrowser(chromium) {
  try {
    return await chromium.launch({ headless: true });
  } catch (error) {
    const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
    if (!existsSync(chromePath)) {
      throw error;
    }
    return chromium.launch({ executablePath: chromePath, headless: true });
  }
}

function collectPageHealth(page, label, health) {
  page.on("console", (message) => {
    if (message.type() === "error" || message.type() === "warning" || message.type() === "warn") {
      health.logs.push({
        page: label,
        type: message.type(),
        text: message.text()
      });
    }
  });

  page.on("pageerror", (error) => {
    health.logs.push({
      page: label,
      type: "pageerror",
      text: error.message
    });
  });
}

async function joinAndSubmit(page, nickname, answerPrefix, questionCount) {
  await page.getByRole("heading", { name: "加入这局 100 Q&As" }).waitFor({ timeout: 20000 });
  await page.getByLabel("昵称").fill(nickname);
  await page.getByRole("button", { name: "开始答题" }).click();
  await page.locator('textarea[data-question="1"]').waitFor({ timeout: 20000 });

  const pageCount = Math.ceil(questionCount / 5);
  for (let pageIndex = 0; pageIndex < pageCount; pageIndex += 1) {
    const startNumber = pageIndex * 5 + 1;
    const endNumber = Math.min(startNumber + 4, questionCount);

    await page.locator(`textarea[data-question="${startNumber}"]`).waitFor({ timeout: 15000 });

    for (let questionNumber = startNumber; questionNumber <= endNumber; questionNumber += 1) {
      await page.locator(`textarea[data-question="${questionNumber}"]`).fill(`${answerPrefix} ${questionNumber}`);
    }

    if (pageIndex < pageCount - 1) {
      await page.getByRole("button", { name: "下一页" }).click();
    }
  }

  await page.getByText(`${questionCount} / ${questionCount} 已回答`).waitFor({ timeout: 15000 });

  const submitButton = page.getByRole("button", { name: "提交答案" });
  assert(await submitButton.isEnabled(), `${nickname} should be able to submit after all answers.`);

  await submitButton.click();
  await page.getByRole("heading", { name: "确认提交吗?" }).waitFor({ timeout: 15000 });
  await page.getByRole("button", { name: "确认提交" }).click();
  await page.getByRole("heading", { name: "大家的答案" }).waitFor({ timeout: 30000 });

  assert(await page.locator("textarea").count() === 0, `${nickname} should not see editable fields after submit.`);
}

async function waitForHeroImage(page) {
  await page.locator(".hero-visual img").waitFor({ state: "visible", timeout: 20000 });
  await page.waitForFunction(() => {
    const image = document.querySelector(".hero-visual img");
    return Boolean(image && image.complete && image.naturalWidth > 0);
  }, null, { timeout: 20000 });
}

async function waitForBankruptBadge(page) {
  await page.waitForFunction(() => {
    return Array.from(document.querySelectorAll(".small-status")).some((element) => {
      return element.textContent && element.textContent.trim() === "已破产";
    });
  }, null, { timeout: 30000 });
}

async function verifyOnlineTycoon(pageA, browser) {
  await pageA.goto(`${appBaseUrl}#tycoon`, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "Friends Tycoon" }).waitFor({ timeout: 20000 });
  await pageA.getByText("32 格世界旅行").waitFor({ timeout: 15000 });
  await pageA.getByText("退出即破产，其他人继续").waitFor({ timeout: 15000 });
  await pageA.locator("#tycoon-host-nickname").fill("线上大富翁A");
  await pageA.getByRole("button", { name: "创建 Friends Tycoon 房间" }).click();
  await pageA.waitForURL(/#tycoon\/room\//, { timeout: 30000 });
  await pageA.getByText("至少 2 人开始").waitFor({ timeout: 20000 });

  const roomUrl = pageA.url();
  const roomCode = roomUrl.split("#tycoon/room/")[1];
  assert(Boolean(roomCode), "Tycoon room URL should include a room code.");

  const contextB = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const pageB = await contextB.newPage();
  collectPageHealth(pageB, "tycoon-player-b", health);
  await pageB.goto(`${appBaseUrl}#tycoon/room/${roomCode}`, { waitUntil: "domcontentloaded" });
  await pageB.getByRole("heading", { name: "加入这局 Friends Tycoon" }).waitFor({ timeout: 30000 });
  await pageB.locator(".inline-join-form input[name=\"nickname\"]").fill("线上大富翁B");
  await pageB.locator(".inline-join-form button").click();
  await pageB.locator(".tycoon-player-list").getByText("线上大富翁B").waitFor({ timeout: 30000 });
  await pageB.locator(".tycoon-chat-form input[name=\"message\"]").fill("线上准备好了");
  await pageB.locator(".tycoon-chat-form button").click();
  await pageB.getByText("线上准备好了").waitFor({ timeout: 20000 });

  await pageA.reload({ waitUntil: "domcontentloaded" });
  await pageA.locator(".tycoon-player-list").getByText("线上大富翁B").waitFor({ timeout: 30000 });
  await pageA.getByText("线上准备好了").waitFor({ timeout: 30000 });
  await pageA.getByRole("button", { name: "开始游戏" }).click();
  await pageA.getByText("游戏中 · 第 1 回合").first().waitFor({ timeout: 30000 });

  const rollButton = pageA.getByRole("button", { name: "掷骰子" });
  assert(await rollButton.isEnabled(), "Host should be able to roll on the first Tycoon turn.");
  await rollButton.click();
  await pageA.locator(".dice-result").waitFor({ timeout: 30000 });

  if (await pageA.getByRole("button", { name: "跳过" }).count()) {
    await pageA.getByRole("button", { name: "跳过" }).click();
  }
  await pageA.getByRole("heading", { name: "线上大富翁B 的回合" }).waitFor({ timeout: 30000 });

  await pageB.reload({ waitUntil: "domcontentloaded" });
  await pageB.getByRole("heading", { name: "线上大富翁B 的回合" }).waitFor({ timeout: 30000 });
  await pageB.getByRole("button", { name: "退出游戏" }).click();
  await pageB.getByRole("heading", { name: "确认退出吗?" }).waitFor({ timeout: 15000 });
  await pageB.getByRole("button", { name: "确认退出" }).click();
  await pageB.getByText("已结束").first().waitFor({ timeout: 30000 });
  await waitForBankruptBadge(pageB);
  await pageB.getByText("最终结果").waitFor({ timeout: 30000 });
  await pageB.getByText("胜利者：线上大富翁A").waitFor({ timeout: 30000 });
  assert(await pageB.getByRole("button", { name: "退出游戏" }).count() === 0, "Bankrupt online Tycoon player should not see the exit button.");
  assert(await pageB.locator(".tycoon-message").count() === 0, "Finished Tycoon room should clear chat messages.");

  const recoveredPageB = await contextB.newPage();
  collectPageHealth(recoveredPageB, "tycoon-player-b-recovered", health);
  await recoveredPageB.goto(`${appBaseUrl}#tycoon/room/${roomCode}`, { waitUntil: "domcontentloaded" });
  await recoveredPageB.getByText("已结束").first().waitFor({ timeout: 30000 });
  await waitForBankruptBadge(recoveredPageB);
  await recoveredPageB.getByText("最终结果").waitFor({ timeout: 30000 });
  assert(await recoveredPageB.getByRole("button", { name: "退出游戏" }).count() === 0, "Recovered bankrupt online Tycoon player should remain bankrupt.");

  await pageA.reload({ waitUntil: "domcontentloaded" });
  await pageA.getByText("已结束").first().waitFor({ timeout: 30000 });
  await pageA.getByText("胜利者：线上大富翁A").waitFor({ timeout: 30000 });
  assert(await pageA.getByRole("button", { name: "退出游戏" }).count() === 0, "Finished online Tycoon winner should not see the exit button.");
  await pageA.screenshot({ path: tycoonScreenshot, fullPage: false });

  return {
    roomCode,
    statusVisible: await pageA.getByText("已结束").first().isVisible(),
    finalWinnerVisible: await pageA.getByText("胜利者：线上大富翁A").isVisible(),
    bankruptRecovered: await recoveredPageB.locator(".small-status").filter({ hasText: "已破产" }).count() > 0,
    chatCleared: await pageA.locator(".tycoon-message").count() === 0
  };
}

async function waitForAccountRecord(page, roomCode, label) {
  const recordText = `Room ${roomCode}`;
  try {
    await page.getByText(recordText).waitFor({ timeout: 10000 });
    return;
  } catch (error) {
    const refreshButton = page.getByRole("button", { name: "刷新记录" });
    if (await refreshButton.count()) {
      await refreshButton.click();
    }
    await page.getByText(recordText).waitFor({ timeout: 30000 });
  }
  assert(await page.getByText(recordText).count() > 0, `${label} account record should be visible.`);
}

async function verifyOnlineAccount(browser) {
  const username = `acct${Date.now().toString(36).slice(-8)}`;
  const password = `pw${Date.now().toString(36).slice(-6)}`;
  const contextA = await browser.newContext({ viewport: { width: 1280, height: 720 }, acceptDownloads: true });
  const pageA = await contextA.newPage();
  collectPageHealth(pageA, "account-player-a", health);

  await pageA.goto(`${appBaseUrl}#account`, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "登录或注册" }).waitFor({ timeout: 20000 });
  assert(
    await pageA.locator("#account-username").getAttribute("placeholder") === "2-20位，支持中文/英文/数字/下划线",
    "Account username placeholder should show the username rules."
  );
  assert(
    await pageA.locator("#account-password").getAttribute("placeholder") === "至少4位，请勿使用重要账号密码",
    "Account password placeholder should show the password rules."
  );
  await pageA.locator("#account-username").fill(username);
  await pageA.locator("#account-password").fill(password);
  await pageA.getByRole("button", { name: "注册新账号" }).click();
  await pageA.getByRole("heading", { name: "我的记录" }).waitFor({ timeout: 30000 });

  await pageA.goto(`${appBaseUrl}#qa/create`, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "创建房间" }).waitFor({ timeout: 20000 });
  await pageA.getByRole("button", { name: "自定义题库" }).click();
  await pageA.getByLabel("粘贴题目").fill("1. 账号跨设备测试问题?");
  await pageA.getByText("已识别 1 题，可以生成房间").waitFor({ timeout: 15000 });
  await pageA.getByRole("button", { name: "生成房间" }).click();
  await pageA.waitForURL(/#qa\/room\//, { timeout: 20000 });
  await joinAndSubmit(pageA, "账号验收QA", "账号答案", 1);
  const qaRoomCode = pageA.url().split("#qa/room/")[1];
  assert(Boolean(qaRoomCode), "Account QA room URL should include a room code.");

  await pageA.goto(`${appBaseUrl}#tycoon`, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "Friends Tycoon" }).waitFor({ timeout: 20000 });
  await pageA.locator("#tycoon-host-nickname").fill("账号验收Tycoon");
  await pageA.getByRole("button", { name: "创建 Friends Tycoon 房间" }).click();
  await pageA.waitForURL(/#tycoon\/room\//, { timeout: 30000 });
  const tycoonRoomCode = pageA.url().split("#tycoon/room/")[1];
  assert(Boolean(tycoonRoomCode), "Account Tycoon room URL should include a room code.");

  await pageA.goto(`${appBaseUrl}#account`, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "我的记录" }).waitFor({ timeout: 20000 });
  await waitForAccountRecord(pageA, qaRoomCode, "QA");
  await waitForAccountRecord(pageA, tycoonRoomCode, "Tycoon");

  const contextB = await browser.newContext({ viewport: { width: 1280, height: 720 }, acceptDownloads: true });
  const pageB = await contextB.newPage();
  collectPageHealth(pageB, "account-player-b", health);

  await pageB.goto(`${appBaseUrl}#account`, { waitUntil: "domcontentloaded" });
  await pageB.getByRole("heading", { name: "登录或注册" }).waitFor({ timeout: 20000 });
  await pageB.locator("#account-username").fill(username);
  await pageB.locator("#account-password").fill(password);
  await pageB.locator('form[data-action="account-login"] button[type="submit"]').click();
  await pageB.getByRole("heading", { name: "我的记录" }).waitFor({ timeout: 30000 });
  await waitForAccountRecord(pageB, qaRoomCode, "Cross-device QA");
  await waitForAccountRecord(pageB, tycoonRoomCode, "Cross-device Tycoon");

  await pageB.goto(`${appBaseUrl}#qa/room/${qaRoomCode}`, { waitUntil: "domcontentloaded" });
  await pageB.getByRole("heading", { name: "大家的答案" }).waitFor({ timeout: 30000 });
  await pageB.getByText("账号答案 1").waitFor({ timeout: 20000 });

  await pageB.goto(`${appBaseUrl}#tycoon/room/${tycoonRoomCode}`, { waitUntil: "domcontentloaded" });
  await pageB.getByRole("heading", { name: "Friends Tycoon" }).waitFor({ timeout: 30000 });
  await pageB.locator(".tycoon-player-list").getByText("账号验收Tycoon").waitFor({ timeout: 30000 });

  return {
    username,
    qaRoomCode,
    tycoonRoomCode,
    crossDeviceRecordsVisible: true,
    qaRoomRecovered: true,
    tycoonRoomRecovered: true
  };
}

const { chromium } = loadPlaywright();
const appUrl = process.env.QA_ONLINE_URL || "https://rohooooo.github.io/100-qas/";
const appBaseUrl = appUrl.split("#")[0];
const customQuestions = Array.from({ length: 3 }, (_, index) => `线上自定义问题 ${index + 1}?`);
const tycoonScreenshot = join(tmpdir(), "friends-tycoon-online-room.png");
const resultScreenshot = join(tmpdir(), "100-qas-online-results.png");
const mobileScreenshot = join(tmpdir(), "100-qas-online-mobile.png");
const health = { logs: [] };

const browser = await launchBrowser(chromium);
const contextA = await browser.newContext({ viewport: { width: 1280, height: 720 }, acceptDownloads: true });
const pageA = await contextA.newPage();
collectPageHealth(pageA, "player-a", health);

try {
  await pageA.goto(appUrl, { waitUntil: "domcontentloaded" });
  assert((await pageA.title()).includes("Friends Games"), "Production page title should identify Friends Games.");
  await pageA.getByRole("heading", { name: "Friends Games" }).waitFor({ timeout: 20000 });

  const accountChecks = await verifyOnlineAccount(browser);

  await pageA.goto(appUrl, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "Friends Games" }).waitFor({ timeout: 20000 });

  const tycoonChecks = await verifyOnlineTycoon(pageA, browser);

  await pageA.goto(appUrl, { waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "Friends Games" }).waitFor({ timeout: 20000 });

  await pageA.getByRole("button", { name: "进入 100 Q&As" }).click();
  await waitForHeroImage(pageA);
  await pageA.getByRole("button", { name: "创建房间" }).waitFor({ timeout: 20000 });
  await pageA.getByRole("button", { name: "创建房间" }).click();
  await pageA.getByRole("heading", { name: "创建房间" }).waitFor({ timeout: 20000 });
  await pageA.getByRole("button", { name: "自定义题库" }).click();
  assert(await pageA.getByRole("button", { name: "生成房间" }).isEnabled(), "Create room button should stay clickable for feedback.");
  await pageA.getByRole("button", { name: "生成房间" }).click();
  await pageA.getByText("还没有识别到题目。可以每题一行，或使用 1. 2. 3. 这样的编号。").waitFor({ timeout: 15000 });
  await pageA.getByLabel("粘贴题目").fill(customQuestions.map((question, index) => `${index + 1}. ${question}`).join(" "));
  await pageA.getByText("已识别 3 题，可以生成房间").waitFor({ timeout: 15000 });
  await pageA.getByRole("button", { name: "生成房间" }).click();
  await pageA.waitForURL(/#qa\/room\//, { timeout: 20000 });

  await joinAndSubmit(pageA, "线上测试A", "线上A答案", customQuestions.length);

  const roomUrl = pageA.url();
  const roomCode = roomUrl.split("#qa/room/")[1];
  assert(Boolean(roomCode), "Room URL should include a room code.");

  await pageA.waitForFunction(() => document.querySelectorAll(".result-card").length === 3, null, {
    timeout: 15000
  });
  assert(await pageA.locator(".result-card").count() === 3, "Results should show the 3 custom question cards.");
  assert(await pageA.locator(".answer-row").count() === 3, "Player A should initially see one submitted answer per question.");
  assert(await pageA.getByText("线上自定义问题 3?").count() === 1, "Results should use the shorter custom online room question bank.");

  const contextB = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const pageB = await contextB.newPage();
  collectPageHealth(pageB, "player-b", health);

  await pageB.goto(`${appUrl}#qa/room/${roomCode}`, { waitUntil: "domcontentloaded" });
  await joinAndSubmit(pageB, "线上测试B", "线上B答案", customQuestions.length);

  await pageB.waitForFunction(() => document.querySelectorAll(".answer-row").length >= 6, null, {
    timeout: 30000
  });
  assert(await pageB.locator(".answer-row").count() === 6, "Player B should see both submitted players after submitting.");
  assert(await pageB.getByText("线上A答案 3").count() === 1, "Player B should see Player A answer 3.");
  assert(await pageB.getByText("线上B答案 3").count() === 1, "Player B should see Player B answer 3.");

  await pageA.reload({ waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "大家的答案" }).waitFor({ timeout: 30000 });
  await pageA.waitForFunction(() => document.querySelectorAll(".answer-row").length >= 6, null, {
    timeout: 30000
  });
  assert(await pageA.locator(".answer-row").count() === 6, "Player A should see Player B after refreshing results.");
  assert(await pageA.getByText("你的答案已经锁定").count() === 1, "Submitted player should see locked-answer status.");

  await pageA.getByRole("button", { name: "导出 PDF" }).click();
  await pageA.waitForURL(/#qa\/export\//, { timeout: 15000 });
  await pageA.getByRole("heading", { name: "100 Q&As 导出" }).waitFor({ timeout: 15000 });
  await pageA.getByRole("button", { name: "下载 PDF" }).waitFor({ timeout: 15000 });
  await pageA.getByRole("button", { name: "打开 PDF 预览" }).waitFor({ timeout: 15000 });
  await pageA.getByRole("button", { name: "打印 / 系统保存" }).waitFor({ timeout: 15000 });
  assert(await pageA.locator(".pdf-question").count() === 3, "Online PDF export should show the 3 custom questions.");
  assert(await pageA.locator(".pdf-answer").count() === 6, "Online PDF export should include both submitted players.");
  const downloadPromise = pageA.waitForEvent("download", { timeout: 10000 });
  await pageA.getByRole("button", { name: "下载 PDF" }).click();
  const pdfDownload = await downloadPromise;
  assert(pdfDownload.suggestedFilename().endsWith(".pdf"), "Online direct export should create a PDF download.");
  await pageA.getByRole("button", { name: "返回结果页" }).click();
  await pageA.getByRole("heading", { name: "大家的答案" }).waitFor({ timeout: 15000 });

  await pageA.screenshot({ path: resultScreenshot, fullPage: false });

  const mobileContext = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true });
  const mobilePage = await mobileContext.newPage();
  collectPageHealth(mobilePage, "mobile-home", health);
  await mobilePage.goto(appUrl, { waitUntil: "domcontentloaded" });
  await mobilePage.getByRole("heading", { name: "Friends Games" }).waitFor({ timeout: 20000 });
  await mobilePage.getByRole("button", { name: "进入 100 Q&As" }).waitFor({ timeout: 20000 });
  await mobilePage.getByRole("button", { name: "进入 Friends Tycoon" }).waitFor({ timeout: 20000 });
  await mobilePage.screenshot({ path: mobileScreenshot, fullPage: false });

  const relevantLogs = health.logs.filter((entry) => {
    return !entry.text.includes("favicon");
  });
  assert(relevantLogs.length === 0, `Console should have no relevant warnings/errors: ${JSON.stringify(relevantLogs)}`);

  console.log(JSON.stringify({
    ok: true,
    appUrl,
    roomCode,
    account: accountChecks,
    tycoon: tycoonChecks,
    checks: {
      title: await pageA.title(),
      resultCards: await pageA.locator(".result-card").count(),
      answerRows: await pageA.locator(".answer-row").count(),
      lockedFields: await pageA.locator("textarea").count() === 0,
      customQuestion3Visible: await pageA.getByText("线上自定义问题 3?").count() === 1,
      mobileLobbyVisible: await mobilePage.getByRole("heading", { name: "Friends Games" }).isVisible(),
      mobileQaEntryVisible: await mobilePage.getByRole("button", { name: "进入 100 Q&As" }).isVisible(),
      mobileTycoonEntryVisible: await mobilePage.getByRole("button", { name: "进入 Friends Tycoon" }).isVisible()
    },
    screenshots: {
      tycoon: tycoonScreenshot,
      results: resultScreenshot,
      mobile: mobileScreenshot
    }
  }, null, 2));
} finally {
  await browser.close();
}
