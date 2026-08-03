import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

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

const { chromium } = loadPlaywright();
const appUrl = pathToFileURL(join(process.cwd(), "index.html")).href + "?backend=local";
const customQuestions = Array.from({ length: 100 }, (_, index) => `自定义问题 ${index + 1}?`);

async function launchBrowser() {
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

const browser = await launchBrowser();
const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
const page = await context.newPage();
const consoleErrors = [];

page.on("console", (message) => {
  if (message.type() === "error") {
    consoleErrors.push(message.text());
  }
});

page.on("pageerror", (error) => {
  consoleErrors.push(error.message);
});

try {
  await page.goto(appUrl);

  await page.getByRole("button", { name: "创建房间" }).click();
  await page.getByRole("heading", { name: "创建房间" }).waitFor();
  await page.getByRole("button", { name: "自定义题库" }).click();
  assert(await page.getByRole("button", { name: "生成房间" }).isEnabled(), "Create room button should stay clickable for feedback.");

  await page.getByLabel("粘贴题目").fill("1. 只有一道测试题");
  await page.getByRole("button", { name: "生成房间" }).click();
  await page.getByText("已识别 1 / 100 题，还差 99 题。").waitFor();

  await page.getByLabel("粘贴题目").fill(customQuestions.map((question, index) => `${index + 1}. ${question}`).join(" "));
  await page.getByText("已识别 100 / 100 题").waitFor();
  await page.getByRole("button", { name: "生成房间" }).click();

  await page.getByLabel("昵称").fill("完整验证玩家");
  await page.getByRole("button", { name: "开始答题" }).click();
  await page.getByText("自定义问题 1?").waitFor();

  for (let pageIndex = 0; pageIndex < 20; pageIndex += 1) {
    const startNumber = pageIndex * 5 + 1;
    for (let offset = 0; offset < 5; offset += 1) {
      const questionNumber = startNumber + offset;
      const answerBox = page.locator(`textarea[data-question="${questionNumber}"]`);
      await answerBox.fill(`测试答案 ${questionNumber}`);
    }

    if (pageIndex < 19) {
      await page.getByRole("button", { name: "下一页" }).click();
    }
  }

  await page.getByText("100 / 100 已回答").waitFor();
  assert(await page.getByRole("button", { name: "提交答案" }).isEnabled(), "Submit button should be enabled.");

  await page.getByRole("button", { name: "提交答案" }).click();
  await page.getByRole("heading", { name: "确认提交吗?" }).waitFor();

  await page.getByRole("button", { name: "再检查一下" }).click();
  assert(await page.locator(".confirm-dialog").count() === 0, "Cancel should close the confirmation dialog.");
  assert(await page.getByRole("heading", { name: "大家的答案" }).count() === 0, "Cancel should not submit.");

  await page.getByRole("button", { name: "提交答案" }).click();
  await page.getByRole("button", { name: "确认提交" }).click();
  await page.getByRole("heading", { name: "大家的答案" }).waitFor();

  assert(await page.locator("textarea").count() === 0, "Submitted player should not see editable textareas.");
  assert(await page.locator(".result-card").count() === 100, "Results should show 100 question cards.");
  assert(await page.locator(".answer-row").count() === 100, "One submitted player should produce 100 answer rows.");
  assert(await page.getByText("自定义问题 23?").count() === 1, "Result page should use the custom room question bank.");
  assert(await page.getByText("测试答案 23").count() === 1, "Result page should include answer 23.");
  assert(await page.getByText("你的答案已经锁定").count() === 1, "Result page should show the locked-answer status.");

  await page.getByRole("button", { name: "再加一位本地玩家" }).click();
  await page.getByRole("heading", { name: "加入这局 100 Q&As" }).waitFor();
  assert(await page.locator(".player-row").count() === 1, "Join page should show the submitted local player.");

  await page.getByLabel("昵称").fill("未提交玩家");
  await page.getByRole("button", { name: "开始答题" }).click();
  await page.getByRole("heading", { name: "未提交玩家 的 100 Q&As" }).waitFor();

  assert(await page.getByRole("heading", { name: "大家的答案" }).count() === 0, "Unsubmitted player should not see results.");
  assert(await page.locator("textarea").count() === 5, "Unsubmitted player should stay on the answer page.");
  assert(await page.locator(".player-row").count() === 2, "Room should show two local players.");
  assert(await page.locator('[data-action="switch-player"]').count() === 1, "There should be one other local player to switch to.");

  const roomSummaryText = await page.locator(".room-summary").textContent();
  assert(roomSummaryText.includes("加入2 人"), "Room summary should show two joined players.");
  assert(roomSummaryText.includes("提交1 人"), "Room summary should show one submitted player.");

  await page.locator('[data-action="switch-player"]').click();
  await page.getByRole("heading", { name: "大家的答案" }).waitFor();
  assert(await page.locator("textarea").count() === 0, "Switching back to submitted player should keep answers locked.");
  assert(await page.locator(".answer-row").count() === 100, "Results should still show only submitted players.");

  const stateSummary = await page.evaluate(() => {
    const raw = localStorage.getItem("hundred-qas-state-v1");
    const state = raw ? JSON.parse(raw) : { rooms: {} };
    const room = Object.values(state.rooms)[0];
    const players = room ? Object.values(room.players) : [];
    const submittedPlayers = players.filter((player) => Boolean(player.submittedAt));
    const firstPlayer = players.find((player) => player.nickname === "完整验证玩家");
    const secondPlayer = players.find((player) => player.nickname === "未提交玩家");
    return {
      roomCode: room ? room.code : null,
      playerCount: players.length,
      submittedCount: submittedPlayers.length,
      firstSubmitted: Boolean(firstPlayer && firstPlayer.submittedAt),
      firstAnswerCount: firstPlayer ? Object.keys(firstPlayer.answers).length : 0,
      firstAnswer23: firstPlayer ? firstPlayer.answers["23"] : null,
      secondSubmitted: Boolean(secondPlayer && secondPlayer.submittedAt),
      secondAnswerCount: secondPlayer ? Object.keys(secondPlayer.answers).length : 0,
      question23: room && room.questions ? room.questions[22] : null
    };
  });

  assert(stateSummary.playerCount === 2, "Room should have two local players.");
  assert(stateSummary.submittedCount === 1, "Only one local player should be submitted.");
  assert(stateSummary.firstSubmitted, "First player should be marked as submitted.");
  assert(stateSummary.firstAnswerCount === 100, "First player should have 100 saved answers.");
  assert(stateSummary.firstAnswer23 === "测试答案 23", "Saved answer 23 should match the filled value.");
  assert(stateSummary.question23 === "自定义问题 23?", "Room should persist its custom question bank.");
  assert(!stateSummary.secondSubmitted, "Second player should remain unsubmitted.");
  assert(stateSummary.secondAnswerCount === 0, "Second player should have no saved answers in this scenario.");
  assert(consoleErrors.length === 0, `Console should have no errors: ${consoleErrors.join("; ")}`);

  console.log(JSON.stringify({ ok: true, state: stateSummary }, null, 2));
} finally {
  await browser.close();
}
