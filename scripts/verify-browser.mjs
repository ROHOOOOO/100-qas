import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
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
const customQuestions = Array.from({ length: 3 }, (_, index) => `自定义问题 ${index + 1}?`);
const lobbyScreenshot = join(tmpdir(), "friends-games-local-lobby.png");
const tycoonScreenshot = join(tmpdir(), "friends-games-local-tycoon.png");
const tycoonRoomScreenshot = join(tmpdir(), "friends-games-local-tycoon-room.png");
const resultsScreenshot = join(tmpdir(), "friends-games-local-results.png");
const mobileLobbyScreenshot = join(tmpdir(), "friends-games-local-mobile-lobby.png");
const mobileTycoonRoomScreenshot = join(tmpdir(), "friends-games-local-mobile-tycoon-room.png");

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

async function waitForToastsToClear(page) {
  await page.locator(".toast").last().waitFor({ state: "detached", timeout: 5000 }).catch(() => {});
}

const browser = await launchBrowser();
const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, acceptDownloads: true });
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
  assert((await page.title()).includes("Friends Games"), "App title should identify Friends Games.");
  await page.getByRole("heading", { name: "Friends Games" }).waitFor();
  await page.getByRole("button", { name: "进入 100 Q&As" }).waitFor();
  await page.getByRole("button", { name: "进入 Friends Tycoon" }).waitFor();
  await page.screenshot({ path: lobbyScreenshot, fullPage: false });

  await page.getByRole("button", { name: "进入 Friends Tycoon" }).click();
  await page.getByRole("heading", { name: "Friends Tycoon" }).waitFor();
  await page.getByText("32 格世界旅行").waitFor();
  await page.getByText("退出即破产，其他人继续").waitFor();
  await page.screenshot({ path: tycoonScreenshot, fullPage: false });

  await page.locator("#tycoon-host-nickname").fill("Tycoon房主");
  await page.getByRole("button", { name: "创建 Friends Tycoon 房间" }).click();
  await page.waitForURL(/#tycoon\/room\//);
  await page.getByText("至少 2 人开始").waitFor();
  await page.getByRole("button", { name: "本地加朋友" }).click();
  await page.locator(".inline-join-form input[name=\"nickname\"]").fill("Tycoon朋友");
  await page.locator(".inline-join-form button").click();
  await page.locator(".tycoon-player-list").getByText("Tycoon朋友").waitFor();
  await page.locator(".tycoon-chat-form input[name=\"message\"]").fill("准备好了");
  await page.locator(".tycoon-chat-form button").click();
  await page.getByText("准备好了").waitFor();
  await page.locator('[data-action="switch-tycoon-player"]').first().click();
  await page.getByRole("button", { name: "开始游戏" }).click();
  await page.getByText("游戏中 · 第 1 回合").first().waitFor();
  await page.getByRole("button", { name: "游戏规则" }).click();
  await page.getByRole("heading", { name: "游戏规则" }).waitFor();
  await page.getByRole("button", { name: "知道了" }).click();
  await page.getByRole("button", { name: "掷骰子" }).click();
  await page.locator(".dice-result").waitFor();
  if (await page.getByRole("button", { name: "跳过" }).count()) {
    await page.getByRole("button", { name: "跳过" }).click();
  }
  await page.getByRole("heading", { name: "Tycoon朋友 的回合" }).waitFor();
  await page.locator('[data-action="switch-tycoon-player"]').first().click();
  await page.getByRole("button", { name: "退出游戏" }).click();
  await page.getByRole("heading", { name: "确认退出吗?" }).waitFor();
  await page.getByRole("button", { name: "确认退出" }).click();
  await page.getByText("已结束").first().waitFor();
  await page.reload();
  await page.getByText("已结束").first().waitFor();
  await page.getByText("最终结果").waitFor();
  assert(await page.getByRole("button", { name: "退出游戏" }).count() === 0, "Bankrupt Tycoon player should not see the exit button again.");
  await page.locator('[data-action="switch-tycoon-player"]').first().click();
  await page.getByText("胜利者：Tycoon房主").waitFor();
  assert(await page.getByRole("button", { name: "退出游戏" }).count() === 0, "Finished Tycoon winner should not see the exit button.");
  await page.screenshot({ path: tycoonRoomScreenshot, fullPage: false });

  const tycoonStateSummary = await page.evaluate(() => {
    const raw = localStorage.getItem("friends-tycoon-state-v1");
    const state = raw ? JSON.parse(raw) : { rooms: {} };
    const room = Object.values(state.rooms)[0];
    const players = room ? Object.values(room.players) : [];
    const bankruptPlayers = players.filter((player) => player.status === "bankrupt");
    return {
      roomCode: room ? room.code : null,
      status: room ? room.status : null,
      playerCount: players.length,
      bankruptCount: bankruptPlayers.length,
      currentPlayerId: room ? room.currentPlayerId : null,
      finalWinner: room && room.finalResults ? room.finalResults.winnerName : null,
      logCount: room && room.logs ? room.logs.length : 0,
      messageCount: room && room.messages ? room.messages.length : 0
    };
  });

  assert(tycoonStateSummary.playerCount === 2, "Tycoon room should have two local players.");
  assert(tycoonStateSummary.bankruptCount === 1, "Exiting Tycoon player should become bankrupt.");
  assert(tycoonStateSummary.status === "finished", "Tycoon should finish when one active player remains.");
  assert(tycoonStateSummary.finalWinner === "Tycoon房主", "Host should win after the other player exits.");
  assert(tycoonStateSummary.logCount > 0, "Tycoon should keep game logs after reload.");
  assert(tycoonStateSummary.messageCount === 0, "Tycoon should clear chat after the game ends.");

  await page.getByRole("button", { name: "游戏大厅" }).click();
  await page.getByRole("heading", { name: "Friends Games" }).waitFor();

  await page.getByRole("button", { name: "进入 100 Q&As" }).click();
  await page.getByRole("button", { name: "创建房间" }).click();
  await page.getByRole("heading", { name: "创建房间" }).waitFor();
  await page.getByRole("button", { name: "自定义题库" }).click();
  assert(await page.getByRole("button", { name: "生成房间" }).isEnabled(), "Create room button should stay clickable for feedback.");
  await page.getByRole("button", { name: "生成房间" }).click();
  await page.getByText("还没有识别到题目。可以每题一行，或使用 1. 2. 3. 这样的编号。").waitFor();

  await page.getByLabel("粘贴题目").fill(customQuestions.map((question, index) => `${index + 1}. ${question}`).join(" "));
  await page.getByText("已识别 3 题，可以生成房间").waitFor();
  await page.getByRole("button", { name: "生成房间" }).click();
  await page.waitForURL(/#qa\/room\//);

  await page.getByLabel("昵称").fill("完整验证玩家");
  await page.getByRole("button", { name: "开始答题" }).click();
  await page.getByText("自定义问题 1?").waitFor();

  for (let questionNumber = 1; questionNumber <= customQuestions.length; questionNumber += 1) {
    const answerBox = page.locator(`textarea[data-question="${questionNumber}"]`);
    await answerBox.fill(`测试答案 ${questionNumber}`);
  }

  await page.getByText("3 / 3 已回答").waitFor();
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
  assert(await page.locator(".result-card").count() === 3, "Results should show the 3 custom question cards.");
  assert(await page.locator(".answer-row").count() === 3, "One submitted player should produce 3 answer rows.");
  assert(await page.getByText("自定义问题 3?").count() === 1, "Result page should use the shorter custom room question bank.");
  assert(await page.getByText("测试答案 3").count() === 1, "Result page should include answer 3.");
  assert(await page.getByText("你的答案已经锁定").count() === 1, "Result page should show the locked-answer status.");

  await page.getByRole("button", { name: "导出 PDF" }).click();
  await page.waitForURL(/#qa\/export\//);
  await page.getByRole("heading", { name: "100 Q&As 导出" }).waitFor();
  await page.getByRole("button", { name: "下载 PDF" }).waitFor();
  await page.getByRole("button", { name: "打开 PDF 预览" }).waitFor();
  await page.getByRole("button", { name: "打印 / 系统保存" }).waitFor();
  assert(await page.locator(".pdf-question").count() === 3, "PDF export should show the 3 custom questions.");
  assert(await page.locator(".pdf-answer").count() === 3, "PDF export should include only submitted player answers.");
  assert(await page.getByText("导出范围：所有已提交玩家的答案").count() === 1, "PDF export should state its export scope.");
  const downloadPromise = page.waitForEvent("download", { timeout: 10000 });
  await page.getByRole("button", { name: "下载 PDF" }).click();
  const pdfDownload = await downloadPromise;
  assert(pdfDownload.suggestedFilename().endsWith(".pdf"), "Direct export should create a PDF download.");
  await page.getByRole("button", { name: "返回结果页" }).click();
  await page.getByRole("heading", { name: "大家的答案" }).waitFor();

  await page.getByRole("button", { name: "再加一位本地玩家" }).click();
  await page.getByRole("heading", { name: "加入这局 100 Q&As" }).waitFor();
  assert(await page.locator(".player-row").count() === 1, "Join page should show the submitted local player.");

  await page.getByLabel("昵称").fill("未提交玩家");
  await page.getByRole("button", { name: "开始答题" }).click();
  await page.getByRole("heading", { name: "未提交玩家 的 3 Q&As" }).waitFor();

  assert(await page.getByRole("heading", { name: "大家的答案" }).count() === 0, "Unsubmitted player should not see results.");
  assert(await page.locator("textarea").count() === customQuestions.length, "Unsubmitted player should stay on the answer page.");
  assert(await page.locator(".player-row").count() === 2, "Room should show two local players.");
  assert(await page.locator('[data-action="switch-player"]').count() === 1, "There should be one other local player to switch to.");

  const roomSummaryText = await page.locator(".room-summary").textContent();
  assert(roomSummaryText.includes("加入2 人"), "Room summary should show two joined players.");
  assert(roomSummaryText.includes("提交1 人"), "Room summary should show one submitted player.");

  await page.locator('[data-action="switch-player"]').click();
  await page.getByRole("heading", { name: "大家的答案" }).waitFor();
  assert(await page.locator("textarea").count() === 0, "Switching back to submitted player should keep answers locked.");
  assert(await page.locator(".answer-row").count() === 3, "Results should still show only submitted players.");

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
      firstAnswer3: firstPlayer ? firstPlayer.answers["3"] : null,
      secondSubmitted: Boolean(secondPlayer && secondPlayer.submittedAt),
      secondAnswerCount: secondPlayer ? Object.keys(secondPlayer.answers).length : 0,
      question3: room && room.questions ? room.questions[2] : null
    };
  });

  assert(stateSummary.playerCount === 2, "Room should have two local players.");
  assert(stateSummary.submittedCount === 1, "Only one local player should be submitted.");
  assert(stateSummary.firstSubmitted, "First player should be marked as submitted.");
  assert(stateSummary.firstAnswerCount === 3, "First player should have 3 saved answers.");
  assert(stateSummary.firstAnswer3 === "测试答案 3", "Saved answer 3 should match the filled value.");
  assert(stateSummary.question3 === "自定义问题 3?", "Room should persist its shorter custom question bank.");
  assert(!stateSummary.secondSubmitted, "Second player should remain unsubmitted.");
  assert(stateSummary.secondAnswerCount === 0, "Second player should have no saved answers in this scenario.");

  await page.getByRole("button", { name: "登录" }).click();
  await page.getByRole("heading", { name: "本地模式记录" }).waitFor();
  assert(await page.locator(".account-record-card").count() >= 2, "Local account page should list local QA and Tycoon records.");
  assert(await page.getByText("100 Q&As").count() >= 1, "Account page should include 100 Q&As records.");
  assert(await page.getByText("Friends Tycoon").count() >= 1, "Account page should include Friends Tycoon records.");

  await page.goto(`${appUrl}#room/${stateSummary.roomCode}`);
  await page.getByRole("heading", { name: "大家的答案" }).waitFor();
  await waitForToastsToClear(page);
  await page.screenshot({ path: resultsScreenshot, fullPage: false });

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`${appUrl}#tycoon/room/${tycoonStateSummary.roomCode}`);
  await page.getByText("最终结果").waitFor();
  await page.getByRole("button", { name: "动态" }).waitFor();
  await page.getByRole("button", { name: "聊天" }).waitFor();
  await page.screenshot({ path: mobileTycoonRoomScreenshot, fullPage: false });

  const mobileContext = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true });
  const mobilePage = await mobileContext.newPage();
  await mobilePage.goto(appUrl);
  await mobilePage.getByRole("heading", { name: "Friends Games" }).waitFor();
  assert(await mobilePage.getByRole("button", { name: "进入 100 Q&As" }).isVisible(), "Mobile lobby should show the 100 Q&As entry.");
  assert(await mobilePage.getByRole("button", { name: "进入 Friends Tycoon" }).isVisible(), "Mobile lobby should show the Friends Tycoon entry.");
  await mobilePage.screenshot({ path: mobileLobbyScreenshot, fullPage: false });
  assert(consoleErrors.length === 0, `Console should have no errors: ${consoleErrors.join("; ")}`);

  console.log(JSON.stringify({
    ok: true,
    state: stateSummary,
    tycoonState: tycoonStateSummary,
    screenshots: {
      lobby: lobbyScreenshot,
      tycoon: tycoonScreenshot,
      tycoonRoom: tycoonRoomScreenshot,
      results: resultsScreenshot,
      mobileLobby: mobileLobbyScreenshot,
      mobileTycoonRoom: mobileTycoonRoomScreenshot
    }
  }, null, 2));
} finally {
  await browser.close();
}
