import { existsSync, writeFileSync } from "node:fs";
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

async function joinAndSubmit(page, nickname, answerPrefix) {
  await page.getByRole("heading", { name: "加入这局 100 Q&As" }).waitFor({ timeout: 20000 });
  await page.getByLabel("昵称").fill(nickname);
  await page.getByRole("button", { name: "开始答题" }).click();
  await page.locator('textarea[data-question="1"]').waitFor({ timeout: 20000 });

  for (let pageIndex = 0; pageIndex < 20; pageIndex += 1) {
    const startNumber = pageIndex * 5 + 1;

    await page.locator(`textarea[data-question="${startNumber}"]`).waitFor({ timeout: 15000 });

    for (let offset = 0; offset < 5; offset += 1) {
      const questionNumber = startNumber + offset;
      await page.locator(`textarea[data-question="${questionNumber}"]`).fill(`${answerPrefix} ${questionNumber}`);
    }

    if (pageIndex < 19) {
      await page.getByRole("button", { name: "下一页" }).click();
    }
  }

  await page.getByText("100 / 100 已回答").waitFor({ timeout: 15000 });

  const submitButton = page.getByRole("button", { name: "提交答案" });
  assert(await submitButton.isEnabled(), `${nickname} should be able to submit after 100 answers.`);

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

const { chromium } = loadPlaywright();
const appUrl = process.env.QA_ONLINE_URL || "https://rohooooo.github.io/100-qas/";
const customQuestions = Array.from({ length: 100 }, (_, index) => `线上自定义问题 ${index + 1}?`);
const customQuestionsPath = join(tmpdir(), "100-qas-online-custom-questions.txt");
writeFileSync(customQuestionsPath, customQuestions.map((question, index) => `${index + 1}. ${question}`).join("\n"));
const resultScreenshot = join(tmpdir(), "100-qas-online-results.png");
const mobileScreenshot = join(tmpdir(), "100-qas-online-mobile.png");
const health = { logs: [] };

const browser = await launchBrowser(chromium);
const contextA = await browser.newContext({ viewport: { width: 1280, height: 720 } });
const pageA = await contextA.newPage();
collectPageHealth(pageA, "player-a", health);

try {
  await pageA.goto(appUrl, { waitUntil: "domcontentloaded" });
  assert((await pageA.title()).includes("100 Q&As"), "Production page title should identify 100 Q&As.");
  await waitForHeroImage(pageA);
  await pageA.getByRole("button", { name: "创建房间" }).waitFor({ timeout: 20000 });
  await pageA.getByRole("button", { name: "创建房间" }).click();
  await pageA.getByRole("heading", { name: "创建房间" }).waitFor({ timeout: 20000 });
  await pageA.getByRole("button", { name: "自定义题库" }).click();
  await pageA.getByLabel("上传题库文件").setInputFiles(customQuestionsPath);
  await pageA.getByText("已识别 100 / 100 题").waitFor({ timeout: 15000 });
  await pageA.getByRole("button", { name: "生成房间" }).click();

  await joinAndSubmit(pageA, "线上测试A", "线上A答案");

  const roomUrl = pageA.url();
  const roomCode = roomUrl.split("#room/")[1];
  assert(Boolean(roomCode), "Room URL should include a room code.");

  await pageA.waitForFunction(() => document.querySelectorAll(".result-card").length === 100, null, {
    timeout: 15000
  });
  assert(await pageA.locator(".result-card").count() === 100, "Results should show 100 question cards.");
  assert(await pageA.locator(".answer-row").count() === 100, "Player A should initially see one submitted answer per question.");
  assert(await pageA.getByText("线上自定义问题 23?").count() === 1, "Results should use the custom online room question bank.");

  const contextB = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const pageB = await contextB.newPage();
  collectPageHealth(pageB, "player-b", health);

  await pageB.goto(`${appUrl}#room/${roomCode}`, { waitUntil: "domcontentloaded" });
  await joinAndSubmit(pageB, "线上测试B", "线上B答案");

  await pageB.waitForFunction(() => document.querySelectorAll(".answer-row").length >= 200, null, {
    timeout: 30000
  });
  assert(await pageB.locator(".answer-row").count() === 200, "Player B should see both submitted players after submitting.");
  assert(await pageB.getByText("线上A答案 23").count() === 1, "Player B should see Player A answer 23.");
  assert(await pageB.getByText("线上B答案 23").count() === 1, "Player B should see Player B answer 23.");

  await pageA.reload({ waitUntil: "domcontentloaded" });
  await pageA.getByRole("heading", { name: "大家的答案" }).waitFor({ timeout: 30000 });
  await pageA.waitForFunction(() => document.querySelectorAll(".answer-row").length >= 200, null, {
    timeout: 30000
  });
  assert(await pageA.locator(".answer-row").count() === 200, "Player A should see Player B after refreshing results.");
  assert(await pageA.getByText("你的答案已经锁定").count() === 1, "Submitted player should see locked-answer status.");

  await pageA.screenshot({ path: resultScreenshot, fullPage: false });

  const mobileContext = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true });
  const mobilePage = await mobileContext.newPage();
  collectPageHealth(mobilePage, "mobile-home", health);
  await mobilePage.goto(appUrl, { waitUntil: "domcontentloaded" });
  await waitForHeroImage(mobilePage);
  await mobilePage.getByRole("button", { name: "创建房间" }).waitFor({ timeout: 20000 });
  await mobilePage.screenshot({ path: mobileScreenshot, fullPage: false });

  const relevantLogs = health.logs.filter((entry) => {
    return !entry.text.includes("favicon");
  });
  assert(relevantLogs.length === 0, `Console should have no relevant warnings/errors: ${JSON.stringify(relevantLogs)}`);

  console.log(JSON.stringify({
    ok: true,
    appUrl,
    roomCode,
    checks: {
      title: await pageA.title(),
      resultCards: await pageA.locator(".result-card").count(),
      answerRows: await pageA.locator(".answer-row").count(),
      lockedFields: await pageA.locator("textarea").count() === 0,
      customQuestion23Visible: await pageA.getByText("线上自定义问题 23?").count() === 1,
      mobileCreateRoomVisible: await mobilePage.getByRole("button", { name: "创建房间" }).isVisible()
    },
    screenshots: {
      results: resultScreenshot,
      mobile: mobileScreenshot
    }
  }, null, 2));
} finally {
  await browser.close();
}
