import { readFileSync } from "node:fs";
import vm from "node:vm";

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const indexHtml = readFileSync("index.html", "utf8");
const appJs = readFileSync("src/app.js", "utf8");
const configJs = readFileSync("src/config.js", "utf8");
const questionsJs = readFileSync("src/questions.js", "utf8");
const stylesCss = readFileSync("src/styles.css", "utf8");
const supabaseSql = readFileSync("supabase/schema.sql", "utf8");

const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(questionsJs, sandbox);

assert(Array.isArray(sandbox.window.QA_QUESTIONS), "Question bank must expose window.QA_QUESTIONS.");
assert(sandbox.window.QA_QUESTIONS.length === 100, "Question bank must contain exactly 100 questions.");
assert(sandbox.window.QA_QUESTIONS[22] === "现在想吃什么?", "Question 23 must use the corrected wording.");

assert(indexHtml.includes("src/questions.js"), "index.html must load src/questions.js.");
assert(indexHtml.includes("src/config.js"), "index.html must load src/config.js.");
assert(indexHtml.includes("src/app.js"), "index.html must load src/app.js.");
assert(indexHtml.includes("src/styles.css"), "index.html must load src/styles.css.");
assert(appJs.includes("assets/question-tabletop.png"), "The app must reference the project visual asset.");
assert(configJs.includes("window.QA_CONFIG"), "Config file must expose window.QA_CONFIG.");
assert(configJs.includes('backend: "supabase"'), "Config should be ready for Supabase online mode.");
assert(configJs.includes("https://yexwacezlklxqlmwgtfe.supabase.co"), "Config must include the Supabase project URL.");
assert(configJs.includes("sb_publishable_"), "Config must use a Supabase publishable key.");
assert(!configJs.includes("postgresql://"), "Config must not contain a direct database connection string.");
assert(!configJs.includes("YOUR-PASSWORD"), "Config must not contain a database password placeholder.");
assert(appJs.includes('params.get("backend") === "local"'), "App must keep the local verification override.");

assert(!appJs.includes("window.confirm"), "Submission confirmation should use the in-page dialog, not window.confirm.");
assert(appJs.includes("qa_create_room"), "App must include the Supabase create-room RPC.");
assert(appJs.includes("p_questions"), "App must send room question banks to Supabase create-room RPC.");
assert(appJs.includes("qa_join_room"), "App must include the Supabase join-room RPC.");
assert(appJs.includes("qa_save_answer"), "App must include the Supabase save-answer RPC.");
assert(appJs.includes("qa_submit_player"), "App must include the Supabase submit-player RPC.");
assert(appJs.includes('data-action="confirm-submit"'), "Submit confirmation action must exist.");
assert(appJs.includes('data-action="cancel-submit"'), "Submit cancellation action must exist.");
assert(appJs.includes("finishSubmitAnswers"), "Final submit handler must exist.");
assert(appJs.includes("submittedAt"), "Submitted state must be represented.");
assert(appJs.includes("renderRoomSummary"), "Room summary renderer must exist.");
assert(appJs.includes("renderLocalPlayers"), "Local player list renderer must exist.");
assert(appJs.includes("getRoomQuestions"), "App must read questions from each room.");
assert(appJs.includes("parseQuestionText"), "App must support pasted/uploaded question banks.");
assert(appJs.includes("questionBankProblem"), "App must explain invalid question bank input after clicking create.");
assert(appJs.includes('data-question-file'), "App must expose a question bank file input.");
assert(appJs.includes('data-question-bank'), "App must expose a pasted question bank input.");
assert(!appJs.includes("data-create-submit disabled"), "Custom question bank create button should stay clickable for feedback.");
assert(appJs.includes('data-action="switch-player"'), "Local player switching action must exist.");
assert(stylesCss.includes(".modal-backdrop"), "Submit dialog backdrop styles must exist.");
assert(stylesCss.includes(".confirm-dialog"), "Submit dialog styles must exist.");
assert(stylesCss.includes(".room-summary"), "Room summary styles must exist.");
assert(stylesCss.includes(".player-row"), "Local player row styles must exist.");
assert(stylesCss.includes(".segmented-control"), "Question bank segmented control styles must exist.");
assert(stylesCss.includes(".question-check"), "Question bank validation styles must exist.");
assert(supabaseSql.includes("create table if not exists public.qa_rooms"), "Supabase SQL must create qa_rooms.");
assert(supabaseSql.includes("create table if not exists public.qa_players"), "Supabase SQL must create qa_players.");
assert(supabaseSql.includes("create table if not exists public.qa_answers"), "Supabase SQL must create qa_answers.");
assert(supabaseSql.includes("questions jsonb"), "Supabase SQL must store room-level question banks.");
assert(supabaseSql.includes("add column if not exists questions"), "Supabase SQL must migrate existing rooms for question banks.");
assert(supabaseSql.includes("qa_create_room"), "Supabase SQL must define qa_create_room.");
assert(supabaseSql.includes("p_questions jsonb"), "Supabase SQL create-room function must accept question banks.");
assert(supabaseSql.includes("qa_submit_player"), "Supabase SQL must define qa_submit_player.");

console.log("Static verification passed.");
