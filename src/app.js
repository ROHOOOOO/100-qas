(function () {
  var STORAGE_KEY = "hundred-qas-state-v1";
  var IDENTITY_KEY = "hundred-qas-current-players-v1";
  var TYCOON_STORAGE_KEY = "friends-tycoon-state-v1";
  var TYCOON_IDENTITY_KEY = "friends-tycoon-current-players-v1";
  var AUTH_SESSION_KEY = "friends-games-auth-session-v1";
  var PAGE_SIZE = 5;
  var QUESTION_TARGET = 100;
  var QUESTION_MINIMUM = 1;
  var MAX_QUESTION_LENGTH = 240;
  var MAX_QUESTION_FILE_BYTES = 120 * 1024;
  var TYCOON_MIN_PLAYERS = 2;
  var TYCOON_MAX_PLAYERS = 6;
  var TYCOON_START_CASH = 200000;
  var TYCOON_PASS_START_REWARD = 20000;
  var TYCOON_MAX_LEVEL = 4;
  var TYCOON_LOG_LIMIT = 80;
  var TYCOON_CHAT_LIMIT = 40;
  var defaultQuestions = window.QA_QUESTIONS || [];
  var app = document.getElementById("app");
  var saveTimer = null;
  var remoteAnswerTimers = {};
  var tycoonPollTimer = null;
  var accountRecordsCache = null;
  var createRoomDraft = {
    mode: "default",
    rawText: "",
    questions: defaultQuestions.slice()
  };
  var games = [
    {
      id: "qa",
      title: "100 Q&As",
      description: "慢慢答完一组问题，提交之后再看朋友们的答案。",
      action: "open-qa",
      cta: "进入 100 Q&As",
      meta: "已上线"
    },
    {
      id: "tycoon",
      title: "Friends Tycoon",
      description: "文字版线上大富翁，开房间后轮流掷骰、买地、聊天。",
      action: "open-tycoon",
      cta: "进入 Friends Tycoon",
      meta: "开发中"
    }
  ];
  var tycoonMap = [
    { name: "起点", type: "start" },
    { name: "北京胡同", type: "property", price: 42000, rent: 3600, upgradeCost: 22000 },
    { name: "机会", type: "chance" },
    { name: "东京涩谷", type: "property", price: 56000, rent: 4600, upgradeCost: 28000 },
    { name: "城市税", type: "tax", fee: 9000 },
    { name: "首尔弘大", type: "property", price: 50000, rent: 4200, upgradeCost: 26000 },
    { name: "机场", type: "airport" },
    { name: "新加坡滨海湾", type: "property", price: 68000, rent: 5600, upgradeCost: 34000 },
    { name: "旅行奖金", type: "bonus", bonus: 12000 },
    { name: "曼谷夜市", type: "property", price: 47000, rent: 3900, upgradeCost: 24000 },
    { name: "悉尼港湾", type: "property", price: 62000, rent: 5100, upgradeCost: 31000 },
    { name: "机会", type: "chance" },
    { name: "迪拜塔", type: "property", price: 72000, rent: 6200, upgradeCost: 36000 },
    { name: "伊斯坦布尔老城", type: "property", price: 54000, rent: 4500, upgradeCost: 27000 },
    { name: "奢侈税", type: "tax", fee: 14000 },
    { name: "雅典卫城", type: "property", price: 52000, rent: 4300, upgradeCost: 26000 },
    { name: "免费停车", type: "rest" },
    { name: "罗马斗兽场", type: "property", price: 64000, rent: 5300, upgradeCost: 32000 },
    { name: "巴黎左岸", type: "property", price: 70000, rent: 6000, upgradeCost: 35000 },
    { name: "机会", type: "chance" },
    { name: "伦敦西区", type: "property", price: 69000, rent: 5900, upgradeCost: 34000 },
    { name: "阿姆斯特丹运河", type: "property", price: 58000, rent: 4800, upgradeCost: 29000 },
    { name: "机场", type: "airport" },
    { name: "柏林博物馆岛", type: "property", price: 57000, rent: 4700, upgradeCost: 28000 },
    { name: "灵感奖金", type: "bonus", bonus: 15000 },
    { name: "哥本哈根港口", type: "property", price: 60000, rent: 5000, upgradeCost: 30000 },
    { name: "雷克雅未克极光", type: "property", price: 66000, rent: 5500, upgradeCost: 33000 },
    { name: "维护费", type: "tax", fee: 11000 },
    { name: "纽约时代广场", type: "property", price: 76000, rent: 6500, upgradeCost: 38000 },
    { name: "洛杉矶日落大道", type: "property", price: 67000, rent: 5600, upgradeCost: 33000 },
    { name: "机会", type: "chance" },
    { name: "旧金山海湾", type: "property", price: 71000, rent: 6100, upgradeCost: 36000 }
  ];

  function getConfig() {
    var config = window.QA_CONFIG || {};
    var params = new URLSearchParams(window.location.search);
    if (params.get("backend") === "local") {
      return {
        backend: "local",
        supabaseUrl: "",
        supabaseAnonKey: ""
      };
    }
    return config;
  }

  function isSupabaseMode() {
    var config = getConfig();
    return config.backend === "supabase" && Boolean(config.supabaseUrl) && Boolean(config.supabaseAnonKey);
  }

  function loadAuthSession() {
    try {
      var saved = localStorage.getItem(AUTH_SESSION_KEY);
      return saved ? JSON.parse(saved) : null;
    } catch (error) {
      return null;
    }
  }

  function saveAuthSession(session) {
    if (!session || !session.access_token) return;
    var existing = loadAuthSession();
    var savedSession = Object.assign({}, session);
    if (!savedSession.user && existing && existing.user) {
      savedSession.user = existing.user;
    }
    if (!savedSession.expires_at && savedSession.expires_in) {
      savedSession.expires_at = Math.floor(Date.now() / 1000) + Number(savedSession.expires_in);
    }
    localStorage.setItem(AUTH_SESSION_KEY, JSON.stringify(savedSession));
    accountRecordsCache = null;
  }

  function normalizeAuthSession(result) {
    if (!result) return null;
    var session = result.session || result;
    if (result.user && !session.user) {
      session.user = result.user;
    }
    return session;
  }

  function clearAuthSession() {
    localStorage.removeItem(AUTH_SESSION_KEY);
    accountRecordsCache = null;
  }

  function getAuthUser() {
    var session = loadAuthSession();
    return session && session.user ? session.user : null;
  }

  function getAuthAccessToken() {
    var session = loadAuthSession();
    if (!session || !session.access_token) return "";
    return session.access_token;
  }

  function isLoggedIn() {
    return Boolean(getAuthAccessToken() && getAuthUser());
  }

  function accountLabel() {
    var user = getAuthUser();
    if (!user) return "登录";
    return user.email || user.phone || "我的账号";
  }

  function authBaseUrl() {
    var config = getConfig();
    return String(config.supabaseUrl || "").replace(/\/$/, "") + "/auth/v1";
  }

  async function authRequest(path, body, options) {
    options = options || {};
    var config = getConfig();
    var headers = {
      apikey: config.supabaseAnonKey,
      "Content-Type": "application/json"
    };
    if (options.accessToken) {
      headers.Authorization = "Bearer " + options.accessToken;
    }

    var response = await fetch(authBaseUrl() + path, {
      method: options.method || "POST",
      headers: headers,
      body: body ? JSON.stringify(body) : undefined
    });

    var data = null;
    var text = await response.text();
    if (text) {
      try {
        data = JSON.parse(text);
      } catch (error) {
        data = { message: text };
      }
    }

    if (!response.ok) {
      throw new Error((data && (data.msg || data.message || data.error_description || data.error)) || "Auth request failed.");
    }

    return data || {};
  }

  function normalizeEmail(value) {
    return String(value || "").trim().toLowerCase();
  }

  async function ensureFreshAuthSession() {
    if (!isSupabaseMode()) return;
    var session = loadAuthSession();
    if (!session || !session.refresh_token) return;

    var expiresAt = Number(session.expires_at || 0);
    var nowSeconds = Math.floor(Date.now() / 1000);
    if (expiresAt && expiresAt - nowSeconds > 90) return;

    try {
      var refreshed = await authRequest("/token?grant_type=refresh_token", {
        refresh_token: session.refresh_token
      });
      if (refreshed && refreshed.access_token) {
        saveAuthSession(refreshed);
      }
    } catch (error) {
      clearAuthSession();
    }
  }

  function supabaseHeaders() {
    var config = getConfig();
    var accessToken = getAuthAccessToken();
    return {
      apikey: config.supabaseAnonKey,
      Authorization: "Bearer " + (accessToken || config.supabaseAnonKey),
      "Content-Type": "application/json"
    };
  }

  async function supabaseRpc(name, payload) {
    var config = getConfig();
    var baseUrl = String(config.supabaseUrl || "").replace(/\/$/, "");
    var response = await fetch(baseUrl + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: supabaseHeaders(),
      body: JSON.stringify(payload || {})
    });

    if (!response.ok) {
      var message = await response.text();
      throw new Error(message || "Supabase request failed.");
    }

    if (response.status === 204) return null;
    return response.json();
  }

  function loadState() {
    try {
      var saved = localStorage.getItem(STORAGE_KEY);
      return saved ? JSON.parse(saved) : { rooms: {} };
    } catch (error) {
      return { rooms: {} };
    }
  }

  function saveState(state) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  }

  function loadIdentities() {
    try {
      var saved = localStorage.getItem(IDENTITY_KEY);
      return saved ? JSON.parse(saved) : {};
    } catch (error) {
      return {};
    }
  }

  function saveIdentities(identities) {
    localStorage.setItem(IDENTITY_KEY, JSON.stringify(identities));
  }

  function loadTycoonState() {
    try {
      var saved = localStorage.getItem(TYCOON_STORAGE_KEY);
      return saved ? JSON.parse(saved) : { rooms: {} };
    } catch (error) {
      return { rooms: {} };
    }
  }

  function saveTycoonState(state) {
    localStorage.setItem(TYCOON_STORAGE_KEY, JSON.stringify(state));
  }

  function loadTycoonIdentities() {
    try {
      var saved = localStorage.getItem(TYCOON_IDENTITY_KEY);
      return saved ? JSON.parse(saved) : {};
    } catch (error) {
      return {};
    }
  }

  function saveTycoonIdentities(identities) {
    localStorage.setItem(TYCOON_IDENTITY_KEY, JSON.stringify(identities));
  }

  function getTycoonIdentity(roomOrCode) {
    var identities = loadTycoonIdentities();
    if (!roomOrCode) return null;

    if (typeof roomOrCode === "string") {
      return identities[String(roomOrCode).toUpperCase()] || null;
    }

    return identities[roomOrCode.id] || identities[roomOrCode.code] || null;
  }

  function saveTycoonIdentity(room, identity) {
    var identities = loadTycoonIdentities();
    identities[room.id] = identity;
    identities[room.code] = identity;
    saveTycoonIdentities(identities);
  }

  function getTycoonIdentityPlayerId(identity) {
    if (!identity) return null;
    return typeof identity === "string" ? identity : identity.playerId;
  }

  function getIdentity(roomOrCode) {
    var identities = loadIdentities();
    if (!roomOrCode) return null;

    if (typeof roomOrCode === "string") {
      return identities[roomOrCode] || null;
    }

    return identities[roomOrCode.id] || identities[roomOrCode.code] || null;
  }

  function saveIdentity(room, identity) {
    var identities = loadIdentities();
    identities[room.id] = identity;
    identities[room.code] = identity;
    saveIdentities(identities);
  }

  function getIdentityPlayerId(identity) {
    if (!identity) return null;
    return typeof identity === "string" ? identity : identity.playerId;
  }

  function makePlayerKey() {
    if (window.crypto && window.crypto.randomUUID) {
      return window.crypto.randomUUID();
    }
    return makeId("key");
  }

  function makeId(prefix) {
    return prefix + "-" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
  }

  function makeRoomCode() {
    var alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var code = "";
    for (var i = 0; i < 6; i += 1) {
      code += alphabet[Math.floor(Math.random() * alphabet.length)];
    }
    return code;
  }

  function cleanQuestion(value) {
    return String(value || "")
      .replace(/^\uFEFF/, "")
      .replace(/\s+/g, " ")
      .replace(/^\s*(?:Q\s*)?\d{1,3}\s*[.、):：-]?\s*/i, "")
      .trim();
  }

  function isQuestionHeader(value) {
    return /^(问题|题目|question|questions)$/i.test(String(value || "").trim());
  }

  function isNumberish(value) {
    return /^(?:Q\s*)?\d{1,3}$/i.test(String(value || "").trim());
  }

  function parseCsvRow(row) {
    var cells = [];
    var current = "";
    var inQuotes = false;

    for (var i = 0; i < row.length; i += 1) {
      var char = row[i];
      var next = row[i + 1];

      if (char === '"' && inQuotes && next === '"') {
        current += '"';
        i += 1;
      } else if (char === '"') {
        inQuotes = !inQuotes;
      } else if (char === "," && !inQuotes) {
        cells.push(current);
        current = "";
      } else {
        current += char;
      }
    }

    cells.push(current);
    return cells;
  }

  function pickQuestionFromLine(line) {
    var cells = line.indexOf(",") >= 0 ? parseCsvRow(line) : [line];

    for (var i = 0; i < cells.length; i += 1) {
      var raw = cells[i].trim();
      var cleaned = cleanQuestion(raw);
      if (cleaned && !isNumberish(raw) && !isQuestionHeader(cleaned)) {
        return cleaned;
      }
    }

    return "";
  }

  function parseQuestionText(rawText) {
    var normalizedText = String(rawText || "")
      .replace(/\r/g, "\n")
      .replace(/([^\n])\s+((?:Q\s*)?\d{1,3}\s*[.、):：-]\s*)/gi, "$1\n$2");

    return normalizedText
      .split(/\r?\n/)
      .map(function (line) { return pickQuestionFromLine(line); })
      .filter(Boolean);
  }

  function normalizeQuestionArray(value) {
    if (!Array.isArray(value)) return [];

    return value
      .map(cleanQuestion)
      .filter(Boolean);
  }

  function getRoomQuestions(room) {
    var roomQuestions = normalizeQuestionArray(room && room.questions);
    if (isValidStoredQuestionBank(roomQuestions)) {
      return roomQuestions;
    }
    return defaultQuestions.slice();
  }

  function isValidStoredQuestionBank(roomQuestions) {
    return roomQuestions.length >= QUESTION_MINIMUM
      && roomQuestions.length <= QUESTION_TARGET
      && roomQuestions.every(function (question) {
        return question.length <= MAX_QUESTION_LENGTH;
      });
  }

  function getSelectedCreateQuestions() {
    if (createRoomDraft.mode === "custom") {
      return normalizeQuestionArray(createRoomDraft.questions);
    }
    return defaultQuestions.slice();
  }

  function isQuestionBankReady(roomQuestions) {
    return roomQuestions.length >= QUESTION_MINIMUM
      && roomQuestions.length <= QUESTION_TARGET
      && roomQuestions.every(function (question) {
        return question.length <= MAX_QUESTION_LENGTH;
      });
  }

  function questionBankStatus(roomQuestions) {
    var tooLong = roomQuestions.some(function (question) {
      return question.length > MAX_QUESTION_LENGTH;
    });

    if (tooLong) {
      return "有题目超过 " + MAX_QUESTION_LENGTH + " 字，请缩短后再创建。";
    }

    if (roomQuestions.length === 0) {
      return "还没有识别到题目";
    }

    if (roomQuestions.length > QUESTION_TARGET) {
      return "已识别 " + roomQuestions.length + " 题，请保留 " + QUESTION_TARGET + " 题。";
    }

    return "已识别 " + roomQuestions.length + " 题，可以生成房间";
  }

  function questionBankProblem(roomQuestions) {
    var tooLong = roomQuestions.some(function (question) {
      return question.length > MAX_QUESTION_LENGTH;
    });

    if (tooLong) {
      return "有题目超过 " + MAX_QUESTION_LENGTH + " 字，请缩短后再生成房间。";
    }

    if (roomQuestions.length === 0) {
      return "还没有识别到题目。可以每题一行，或使用 1. 2. 3. 这样的编号。";
    }

    if (roomQuestions.length > QUESTION_TARGET) {
      return "已识别 " + roomQuestions.length + " 题，请保留 " + QUESTION_TARGET + " 题后再生成房间。";
    }

    return "";
  }

  function resetCreateRoomDraft() {
    createRoomDraft = {
      mode: "default",
      rawText: "",
      questions: defaultQuestions.slice()
    };
  }

  function getHashParts() {
    var raw = window.location.hash.replace(/^#\/?/, "");
    return raw ? raw.split("/") : ["home"];
  }

  function getQaRoomCode() {
    var parts = getHashParts();
    if (parts[0] === "qa" && parts[1] === "room") return parts[2] || "";
    if (parts[0] === "room") return parts[1] || "";
    return "";
  }

  function getTycoonRoomCode() {
    var parts = getHashParts();
    if (parts[0] === "tycoon" && parts[1] === "room") return parts[2] || "";
    return "";
  }

  function setRoute(path) {
    window.location.hash = path;
  }

  function renderShell(content, activeGame) {
    app.innerHTML = [
      renderGlobalNav(activeGame),
      content
    ].join("");
  }

  function renderGlobalNav(activeGame) {
    return [
      '<header class="site-nav">',
      '  <button class="brand-button" data-action="open-lobby" type="button">Friends Games</button>',
      '  <nav aria-label="游戏导航">',
      '    <button class="' + (activeGame === "lobby" ? "is-active" : "") + '" data-action="open-lobby" type="button">游戏大厅</button>',
      '    <button class="' + (activeGame === "qa" ? "is-active" : "") + '" data-action="open-qa" type="button">100 Q&As</button>',
      '    <button class="' + (activeGame === "tycoon" ? "is-active" : "") + '" data-action="open-tycoon" type="button">Friends Tycoon</button>',
      '    <button class="' + (activeGame === "account" ? "is-active" : "") + '" data-action="open-account" type="button">' + escapeHtml(isLoggedIn() ? "我的记录" : "登录") + '</button>',
      '  </nav>',
      '</header>'
    ].join("");
  }

  function getRoomByCode(state, code) {
    var roomIds = Object.keys(state.rooms);
    var upperCode = String(code || "").trim().toUpperCase();
    for (var i = 0; i < roomIds.length; i += 1) {
      var room = state.rooms[roomIds[i]];
      if (room.code === upperCode) return room;
    }
    return null;
  }

  function getCurrentPlayer(room) {
    var identity = getIdentity(room);
    var playerId = getIdentityPlayerId(identity);
    if (!playerId || !room.players[playerId]) return null;
    return room.players[playerId];
  }

  function answeredCount(player, room) {
    var roomQuestions = getRoomQuestions(room);
    return roomQuestions.reduce(function (count, _, index) {
      var answer = (player.answers[String(index + 1)] || "").trim();
      return count + (answer ? 1 : 0);
    }, 0);
  }

  function getRoomPlayers(room) {
    return Object.keys(room.players)
      .map(function (id) { return room.players[id]; })
      .sort(function (a, b) { return a.createdAt.localeCompare(b.createdAt); });
  }

  function submittedCount(room) {
    return getRoomPlayers(room).filter(function (player) {
      return Boolean(player.submittedAt);
    }).length;
  }

  function escapeHtml(value) {
    return String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function roomLink(room) {
    var base = window.location.href.split("#")[0];
    return base + "#qa/room/" + room.code;
  }

  function normalizeOnlineRoom(bundle) {
    if (!bundle || !bundle.room) return null;

    var room = {
      id: bundle.room.id,
      code: bundle.room.code,
      title: bundle.room.title || "100 Q&As",
      createdAt: bundle.room.createdAt || bundle.room.created_at || new Date().toISOString(),
      questions: getRoomQuestions({ questions: bundle.room.questions || bundle.room.questionBank }),
      players: {}
    };

    (bundle.players || []).forEach(function (player) {
      room.players[player.id] = {
        id: player.id,
        nickname: player.nickname,
        createdAt: player.createdAt || player.created_at || new Date().toISOString(),
        submittedAt: player.submittedAt || player.submitted_at || null,
        lastPage: 0,
        answers: player.answers || {}
      };
    });

    return room;
  }

  function cacheRoom(room) {
    var state = loadState();
    Object.keys(state.rooms).forEach(function (id) {
      if (state.rooms[id].code === room.code && id !== room.id) {
        delete state.rooms[id];
      }
    });
    state.rooms[room.id] = room;
    saveState(state);
    return room;
  }

  function getTycoonRoomByCode(state, code) {
    var roomIds = Object.keys(state.rooms || {});
    var upperCode = String(code || "").trim().toUpperCase();
    for (var i = 0; i < roomIds.length; i += 1) {
      var room = state.rooms[roomIds[i]];
      if (room.code === upperCode) return room;
    }
    return null;
  }

  function tycoonRoomLink(room) {
    var base = window.location.href.split("#")[0];
    return base + "#tycoon/room/" + room.code;
  }

  function getTycoonPlayers(room) {
    return Object.keys(room.players || {})
      .map(function (id) { return room.players[id]; })
      .sort(function (a, b) { return a.createdAt.localeCompare(b.createdAt); });
  }

  function getTycoonPresentPlayers(room) {
    return getTycoonPlayers(room).filter(function (player) {
      return player.status !== "bankrupt";
    });
  }

  function getTycoonActivePlayers(room) {
    return getTycoonPlayers(room).filter(function (player) {
      return player.status === "active";
    });
  }

  function getTycoonCurrentPlayer(room) {
    var identity = getTycoonIdentity(room);
    var playerId = getTycoonIdentityPlayerId(identity);
    if (!playerId || !room.players[playerId]) return null;
    return room.players[playerId];
  }

  function isTycoonHost(room, player) {
    return Boolean(room && player && room.hostPlayerId === player.id);
  }

  function getTycoonCell(index) {
    var safeIndex = ((Number(index) || 0) + tycoonMap.length) % tycoonMap.length;
    return tycoonMap[safeIndex];
  }

  function makeTycoonProperties() {
    return tycoonMap.reduce(function (properties, cell, index) {
      if (cell.type === "property") {
        properties[String(index)] = {
          cellIndex: index,
          ownerId: null,
          level: 0
        };
      }
      return properties;
    }, {});
  }

  function getTycoonProperty(room, cellIndex) {
    return room.properties && room.properties[String(cellIndex)];
  }

  function tycoonRent(cell, level) {
    return Number(cell.rent || 0) * Math.max(1, Number(level || 1));
  }

  function tycoonPropertyValue(cell, property) {
    var level = Number(property && property.level || 0);
    if (!level) return 0;
    return Number(cell.price || 0) + Math.max(0, level - 1) * Number(cell.upgradeCost || 0);
  }

  function tycoonNetWorth(room, player) {
    if (!player) return 0;
    var total = Number(player.cash || 0);
    Object.keys(room.properties || {}).forEach(function (key) {
      var property = room.properties[key];
      if (property.ownerId === player.id) {
        total += tycoonPropertyValue(getTycoonCell(property.cellIndex), property);
      }
    });
    return total;
  }

  function formatMoney(amount) {
    var value = Number(amount || 0);
    return value.toLocaleString("zh-CN");
  }

  function appendTycoonLog(room, message, kind) {
    room.logs = room.logs || [];
    room.logs.unshift({
      id: makeId("log"),
      kind: kind || "info",
      message: message,
      createdAt: new Date().toISOString()
    });
    room.logs = room.logs.slice(0, TYCOON_LOG_LIMIT);
  }

  function appendTycoonMessage(room, player, content) {
    room.messages = room.messages || [];
    room.messages.push({
      id: makeId("msg"),
      playerId: player.id,
      nickname: player.nickname,
      content: content,
      createdAt: new Date().toISOString()
    });
    room.messages = room.messages.slice(-TYCOON_CHAT_LIMIT);
  }

  function transferTycoonHost(room) {
    if (room.players[room.hostPlayerId] && room.players[room.hostPlayerId].status !== "bankrupt") {
      return;
    }

    var replacement = getTycoonPresentPlayers(room)[0] || null;
    room.hostPlayerId = replacement ? replacement.id : null;
    if (replacement) {
      appendTycoonLog(room, replacement.nickname + " 成为新的房主。", "host");
    }
  }

  function buildTycoonFinalResults(room) {
    return getTycoonPlayers(room).map(function (player) {
      return {
        id: player.id,
        nickname: player.nickname,
        cash: Number(player.cash || 0),
        status: player.status,
        propertyCount: Object.keys(room.properties || {}).filter(function (key) {
          return room.properties[key].ownerId === player.id;
        }).length,
        netWorth: tycoonNetWorth(room, player)
      };
    }).sort(function (a, b) {
      if ((a.status === "active") !== (b.status === "active")) {
        return a.status === "active" ? -1 : 1;
      }
      return b.netWorth - a.netWorth;
    });
  }

  function finishTycoonRoom(room, reason) {
    var results = buildTycoonFinalResults(room);
    var survivorWinner = reason === "survivor" ? getTycoonActivePlayers(room)[0] : null;
    var winner = survivorWinner || results[0] || null;
    room.status = "finished";
    room.turnPhase = "finished";
    room.currentPlayerId = null;
    room.finalResults = {
      reason: reason,
      winnerId: winner ? winner.id : null,
      winnerName: winner ? winner.nickname : "",
      results: results,
      finishedAt: new Date().toISOString()
    };
    room.messages = [];
    appendTycoonLog(room, winner ? "游戏结束，" + winner.nickname + " 获胜。" : "游戏结束。", "finish");
  }

  function checkTycoonFinish(room) {
    if (room.status !== "active") return;

    var activePlayers = getTycoonActivePlayers(room);
    if (activePlayers.length <= 1) {
      finishTycoonRoom(room, "survivor");
      return;
    }

    if (room.victoryMode === "turnLimit" && room.currentTurn > room.turnLimit) {
      finishTycoonRoom(room, "turnLimit");
    }
  }

  function bankruptTycoonPlayer(room, player, reason) {
    player.status = "bankrupt";
    player.cash = Number(player.cash || 0);
    Object.keys(room.properties || {}).forEach(function (key) {
      if (room.properties[key].ownerId === player.id) {
        room.properties[key].ownerId = null;
        room.properties[key].level = 0;
      }
    });
    appendTycoonLog(room, player.nickname + " 破产出局。" + (reason ? " " + reason : ""), "bankrupt");
    transferTycoonHost(room);
  }

  function advanceTycoonTurn(room, currentPlayerId) {
    var activePlayers = getTycoonActivePlayers(room);
    if (!activePlayers.length) {
      finishTycoonRoom(room, "survivor");
      return;
    }

    if (activePlayers.length === 1) {
      room.currentPlayerId = activePlayers[0].id;
      checkTycoonFinish(room);
      return;
    }

    var currentIndex = activePlayers.findIndex(function (player) {
      return player.id === currentPlayerId;
    });
    var nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % activePlayers.length;
    if (currentIndex >= 0 && nextIndex === 0) {
      room.currentTurn += 1;
    }
    room.currentPlayerId = activePlayers[nextIndex].id;
    room.turnPhase = "roll";
    room.lastDice = null;
    checkTycoonFinish(room);
  }

  function applyTycoonLanding(room, player, oldPosition, dice) {
    var newPosition = (oldPosition + dice) % tycoonMap.length;
    var passedStart = oldPosition + dice >= tycoonMap.length;
    player.position = newPosition;

    if (passedStart) {
      player.cash += TYCOON_PASS_START_REWARD;
      appendTycoonLog(room, player.nickname + " 经过起点，获得 " + formatMoney(TYCOON_PASS_START_REWARD) + "。", "money");
    }

    var cell = getTycoonCell(newPosition);
    appendTycoonLog(room, player.nickname + " 到达 " + cell.name + "。", "move");

    if (cell.type === "bonus") {
      player.cash += Number(cell.bonus || 0);
      appendTycoonLog(room, player.nickname + " 获得旅行奖金 " + formatMoney(cell.bonus) + "。", "money");
      return;
    }

    if (cell.type === "tax") {
      player.cash -= Number(cell.fee || 0);
      appendTycoonLog(room, player.nickname + " 支付 " + cell.name + " " + formatMoney(cell.fee) + "。", "money");
      if (player.cash < 0) bankruptTycoonPlayer(room, player, "现金低于 0。");
      return;
    }

    if (cell.type === "chance") {
      var events = [
        { delta: 18000, text: "旅行短视频爆火，获得奖金" },
        { delta: -12000, text: "行李超重，支付费用" },
        { delta: 10000, text: "朋友请客，现金增加" },
        { delta: -9000, text: "错过航班，重新订票" }
      ];
      var event = events[Math.floor(Math.random() * events.length)];
      player.cash += event.delta;
      appendTycoonLog(room, player.nickname + " 抽到机会：" + event.text + " " + formatMoney(Math.abs(event.delta)) + "。", "chance");
      if (player.cash < 0) bankruptTycoonPlayer(room, player, "现金低于 0。");
      return;
    }

    if (cell.type === "property") {
      var property = getTycoonProperty(room, newPosition);
      if (!property || !property.ownerId) {
        appendTycoonLog(room, cell.name + " 暂无主人，可以购买。", "property");
        return;
      }

      if (property.ownerId === player.id) {
        appendTycoonLog(room, player.nickname + " 来到自己的 " + cell.name + "。", "property");
        return;
      }

      var owner = room.players[property.ownerId];
      var rent = tycoonRent(cell, property.level);
      player.cash -= rent;
      if (owner && owner.status !== "bankrupt") {
        owner.cash += rent;
      }
      appendTycoonLog(room, player.nickname + " 向 " + (owner ? owner.nickname : "银行") + " 支付租金 " + formatMoney(rent) + "。", "money");
      if (player.cash < 0) bankruptTycoonPlayer(room, player, "现金低于 0。");
    }
  }

  function normalizeTycoonRoom(room) {
    room.map = Array.isArray(room.map) && room.map.length === tycoonMap.length ? room.map : tycoonMap.slice();
    room.players = room.players || {};
    room.properties = room.properties || makeTycoonProperties();
    room.logs = Array.isArray(room.logs) ? room.logs : [];
    room.messages = Array.isArray(room.messages) ? room.messages : [];
    return room;
  }

  function normalizeOnlineTycoonRoom(bundle) {
    if (!bundle || !bundle.room) return null;

    var room = {
      id: bundle.room.id,
      code: bundle.room.code,
      hostPlayerId: bundle.room.hostPlayerId || bundle.room.host_player_id,
      status: bundle.room.status || "lobby",
      victoryMode: bundle.room.victoryMode || bundle.room.victory_mode || "survivor",
      turnLimit: Number(bundle.room.turnLimit || bundle.room.turn_limit || 30),
      currentTurn: Number(bundle.room.currentTurn || bundle.room.current_turn || 1),
      currentPlayerId: bundle.room.currentPlayerId || bundle.room.current_player_id || null,
      turnPhase: bundle.room.turnPhase || bundle.room.turn_phase || "roll",
      lastDice: bundle.room.lastDice || bundle.room.last_dice || null,
      finalResults: bundle.room.finalResults || bundle.room.final_results || null,
      createdAt: bundle.room.createdAt || bundle.room.created_at || new Date().toISOString(),
      map: Array.isArray(bundle.room.map) ? bundle.room.map : tycoonMap.slice(),
      players: {},
      properties: {},
      logs: bundle.logs || [],
      messages: bundle.messages || []
    };

    (bundle.players || []).forEach(function (player) {
      room.players[player.id] = {
        id: player.id,
        nickname: player.nickname,
        cash: Number(player.cash || 0),
        position: Number(player.position || 0),
        status: player.status || "waiting",
        createdAt: player.createdAt || player.created_at || new Date().toISOString()
      };
    });

    (bundle.properties || []).forEach(function (property) {
      room.properties[String(property.cellIndex || property.cell_index)] = {
        cellIndex: Number(property.cellIndex || property.cell_index),
        ownerId: property.ownerId || property.owner_player_id || null,
        level: Number(property.level || 0)
      };
    });

    return normalizeTycoonRoom(room);
  }

  function cacheTycoonRoom(room) {
    var state = loadTycoonState();
    Object.keys(state.rooms).forEach(function (id) {
      if (state.rooms[id].code === room.code && id !== room.id) {
        delete state.rooms[id];
      }
    });
    state.rooms[room.id] = normalizeTycoonRoom(room);
    saveTycoonState(state);
    return room;
  }

  async function syncOnlineRoom(code) {
    if (!isSupabaseMode() || !code) return null;

    var identity = getIdentity(String(code).toUpperCase());
    var bundle = await supabaseRpc("qa_get_room", {
      p_room_code: String(code).toUpperCase(),
      p_player_id: getIdentityPlayerId(identity),
      p_player_key: identity && identity.playerKey ? identity.playerKey : null
    });

    var room = normalizeOnlineRoom(bundle);
    if (!room) return null;

    if (bundle.currentPlayerId) {
      saveIdentity(room, {
        playerId: bundle.currentPlayerId,
        playerKey: identity && identity.playerKey ? identity.playerKey : null,
        lastPage: identity && typeof identity.lastPage === "number" ? identity.lastPage : 0
      });
    }

    return cacheRoom(room);
  }

  async function syncOnlineTycoonRoom(code) {
    if (!isSupabaseMode() || !code) return null;

    var identity = getTycoonIdentity(String(code).toUpperCase());
    var bundle = await supabaseRpc("tycoon_get_room", {
      p_room_code: String(code).toUpperCase(),
      p_player_id: getTycoonIdentityPlayerId(identity),
      p_player_key: identity && identity.playerKey ? identity.playerKey : null
    });

    var room = normalizeOnlineTycoonRoom(bundle);
    if (!room) return null;

    if (bundle.currentPlayerId) {
      saveTycoonIdentity(room, {
        playerId: bundle.currentPlayerId,
        playerKey: identity && identity.playerKey ? identity.playerKey : null
      });
    }

    return cacheTycoonRoom(room);
  }

  function setTycoonPolling(code) {
    window.clearTimeout(tycoonPollTimer);
    tycoonPollTimer = null;

    if (!isSupabaseMode() || !code) return;

    tycoonPollTimer = window.setTimeout(async function () {
      if (getTycoonRoomCode().toUpperCase() !== String(code).toUpperCase()) return;

      try {
        await syncOnlineTycoonRoom(code);
        render({ skipOnlineSync: true });
      } catch (error) {
        showToast("Friends Tycoon 暂时没有同步成功，稍后会自动重试。");
        setTycoonPolling(code);
      }
    }, 3500);
  }

  function onlineTycoonErrorMessage() {
    return "Friends Tycoon 线上数据库还没升级，请先在 Supabase SQL Editor 运行最新版 supabase/schema.sql。";
  }

  function getCurrentPage(room, player) {
    var identity = getIdentity(room);
    if (identity && typeof identity === "object" && typeof identity.lastPage === "number") {
      return identity.lastPage;
    }
    return player.lastPage || 0;
  }

  function setCurrentPage(room, player, page) {
    if (isSupabaseMode()) {
      var identity = getIdentity(room);
      if (identity && typeof identity === "object") {
        identity.lastPage = page;
        saveIdentity(room, identity);
      }
      return;
    }

    player.lastPage = page;
  }

  async function render(options) {
    options = options || {};
    await ensureFreshAuthSession();
    var state = loadState();
    var parts = getHashParts();
    var pageName = parts[0] || "home";

    if (!(pageName === "tycoon" && parts[1] === "room")) {
      setTycoonPolling("");
    }

    if (pageName === "qa") {
      if (parts[1] === "export") {
        if (isSupabaseMode() && !options.skipOnlineSync) {
          try {
            await syncOnlineRoom(parts[2]);
            state = loadState();
          } catch (error) {
            showToast("线上房间同步失败，请检查 Supabase 配置。");
          }
        }
        renderQaExportPage(state, parts[2]);
        return;
      }

      if (parts[1] === "room") {
        if (isSupabaseMode() && !options.skipOnlineSync) {
          try {
            await syncOnlineRoom(parts[2]);
            state = loadState();
          } catch (error) {
            showToast("线上房间同步失败，请检查 Supabase 配置。");
          }
        }
        renderRoom(state, parts[2]);
        return;
      }

      if (parts[1] === "create") {
        renderCreateRoom(state);
        return;
      }

      renderQaHome(state);
      return;
    }

    if (pageName === "account") {
      await renderAccountPage();
      return;
    }

    if (pageName === "room") {
      if (isSupabaseMode() && !options.skipOnlineSync) {
        try {
          await syncOnlineRoom(parts[1]);
          state = loadState();
        } catch (error) {
          showToast("线上房间同步失败，请检查 Supabase 配置。");
        }
      }
      renderRoom(state, parts[1]);
      return;
    }

    if (pageName === "create") {
      renderCreateRoom(state);
      return;
    }

    if (pageName === "tycoon") {
      if (parts[1] === "room") {
        var tycoonState = loadTycoonState();
        if (isSupabaseMode() && !options.skipOnlineSync) {
          try {
            await syncOnlineTycoonRoom(parts[2]);
            tycoonState = loadTycoonState();
          } catch (error) {
            showToast(onlineTycoonErrorMessage());
          }
        }
        renderTycoonRoom(tycoonState, parts[2]);
        setTycoonPolling(parts[2]);
        return;
      }

      renderTycoonHome();
      return;
    }

    renderGameLobby();
  }

  function renderGameLobby() {
    document.title = "Friends Games";
    renderShell([
      '<main class="lobby-layout">',
      '  <section class="lobby-intro">',
      '    <h1>Friends Games</h1>',
      '    <p class="lead">给熟人朋友准备的小网页游戏集合，开房间，把链接发给朋友，就能一起玩。</p>',
      '  </section>',
      '  <section class="game-grid" aria-label="选择游戏">',
      games.map(function (game) {
        return [
          '<article class="game-card game-card-' + escapeHtml(game.id) + '">',
          '  <div>',
          '    <span>' + escapeHtml(game.meta) + '</span>',
          '    <h2>' + escapeHtml(game.title) + '</h2>',
          '    <p>' + escapeHtml(game.description) + '</p>',
          '  </div>',
          '  <button class="primary-button" data-action="' + escapeHtml(game.action) + '" type="button">' + escapeHtml(game.cta) + '</button>',
          '</article>'
        ].join("");
      }).join(""),
      '  </section>',
      '</main>'
    ].join(""), "lobby");
  }

  function localAccountRecords() {
    var qaState = loadState();
    var tycoonState = loadTycoonState();
    return {
      qa: Object.keys(qaState.rooms || {}).map(function (id) {
        var room = qaState.rooms[id];
        var player = getCurrentPlayer(room) || getRoomPlayers(room)[0] || null;
        return {
          roomCode: room.code,
          nickname: player ? player.nickname : "本地玩家",
          questionCount: getRoomQuestions(room).length,
          submittedAt: player ? player.submittedAt : null,
          answerCount: player ? answeredCount(player, room) : 0,
          createdAt: room.createdAt
        };
      }),
      tycoon: Object.keys(tycoonState.rooms || {}).map(function (id) {
        var room = normalizeTycoonRoom(tycoonState.rooms[id]);
        var player = getTycoonCurrentPlayer(room) || getTycoonPlayers(room)[0] || null;
        return {
          roomCode: room.code,
          nickname: player ? player.nickname : "本地玩家",
          status: room.status,
          playerStatus: player ? player.status : "",
          cash: player ? player.cash : 0,
          isHost: player ? isTycoonHost(room, player) : false,
          createdAt: room.createdAt
        };
      })
    };
  }

  function collectDeviceBindingPayload() {
    var qaState = loadState();
    var qaPlayers = [];
    var seenQa = {};
    Object.keys(qaState.rooms || {}).forEach(function (id) {
      var room = qaState.rooms[id];
      var identity = getIdentity(room);
      var playerId = getIdentityPlayerId(identity);
      if (!identity || !identity.playerKey || !playerId) return;
      var key = room.code + ":" + playerId;
      if (seenQa[key]) return;
      seenQa[key] = true;
      qaPlayers.push({
        roomCode: room.code,
        playerId: playerId,
        playerKey: identity.playerKey
      });
    });

    var tycoonState = loadTycoonState();
    var tycoonPlayers = [];
    var seenTycoon = {};
    Object.keys(tycoonState.rooms || {}).forEach(function (id) {
      var room = tycoonState.rooms[id];
      var identity = getTycoonIdentity(room);
      var playerId = getTycoonIdentityPlayerId(identity);
      if (!identity || !identity.playerKey || !playerId) return;
      var key = room.code + ":" + playerId;
      if (seenTycoon[key]) return;
      seenTycoon[key] = true;
      tycoonPlayers.push({
        roomCode: room.code,
        playerId: playerId,
        playerKey: identity.playerKey
      });
    });

    return {
      qaPlayers: qaPlayers,
      tycoonPlayers: tycoonPlayers
    };
  }

  async function loadAccountRecords() {
    if (!isSupabaseMode() || !isLoggedIn()) return localAccountRecords();
    if (accountRecordsCache) return accountRecordsCache;
    accountRecordsCache = await supabaseRpc("account_get_records", {});
    return accountRecordsCache || { qa: [], tycoon: [] };
  }

  async function renderAccountPage() {
    document.title = "我的记录 | Friends Games";

    if (!isSupabaseMode()) {
      renderShell([
        '<main class="account-layout">',
        '  <section class="panel account-panel">',
        '    <p class="eyebrow">Account</p>',
        '    <h1>本地模式记录</h1>',
        '    <p class="muted">当前是本地测试模式，登录功能只在线上 Supabase 模式启用。</p>',
        renderAccountRecordLists(localAccountRecords()),
        '  </section>',
        '</main>'
      ].join(""), "account");
      return;
    }

    if (!isLoggedIn()) {
      renderShell([
        '<main class="account-layout">',
        '  <section class="panel account-panel">',
        '    <p class="eyebrow">Account</p>',
        '    <h1>登录或注册</h1>',
        '    <p class="muted">第一版先启用邮箱 + 密码。手机号入口会保留，等短信服务配置好后再打开。</p>',
        '    <div class="account-mode-row">',
        '      <span class="small-status">邮箱可用</span>',
        '      <span class="small-status is-muted">手机号稍后开放</span>',
        '    </div>',
        '    <form class="stack-form account-form" data-action="account-login">',
        '      <label for="account-email">邮箱</label>',
        '      <input id="account-email" name="email" type="email" autocomplete="email" placeholder="you@example.com">',
        '      <label for="account-password">密码</label>',
        '      <input id="account-password" name="password" type="password" autocomplete="current-password" minlength="6" placeholder="至少 6 位">',
        '      <div class="dialog-actions">',
        '        <button class="primary-button" type="submit">登录</button>',
        '        <button class="secondary-button" data-action="account-register" type="button">注册新账号</button>',
        '      </div>',
        '    </form>',
        '  </section>',
        '</main>'
      ].join(""), "account");
      return;
    }

    var records;
    try {
      records = await loadAccountRecords();
    } catch (error) {
      records = { qa: [], tycoon: [] };
      showToast("账号记录暂时读取失败，请确认已运行最新版 Supabase SQL。");
    }

    var bindingPayload = collectDeviceBindingPayload();
    var bindCount = bindingPayload.qaPlayers.length + bindingPayload.tycoonPlayers.length;

    renderShell([
      '<main class="account-layout">',
      '  <section class="panel account-panel">',
      '    <p class="eyebrow">Account</p>',
      '    <h1>我的记录</h1>',
      '    <p class="muted">' + escapeHtml(accountLabel()) + '</p>',
      '    <div class="dialog-actions">',
      bindCount ? '      <button class="primary-button" data-action="account-bind-device" type="button">绑定这台设备里的 ' + bindCount + ' 条匿名记录</button>' : "",
      '      <button class="secondary-button" data-action="account-refresh-records" type="button">刷新记录</button>',
      '      <button class="ghost-button" data-action="account-logout" type="button">退出登录</button>',
      '    </div>',
      renderAccountRecordLists(records),
      '  </section>',
      '</main>'
    ].join(""), "account");
  }

  function renderAccountRecordLists(records) {
    records = records || { qa: [], tycoon: [] };
    return [
      '<section class="account-record-grid">',
      '  <div class="account-record-section">',
      '    <h2>100 Q&As</h2>',
      renderQaAccountRecords(records.qa || []),
      '  </div>',
      '  <div class="account-record-section">',
      '    <h2>Friends Tycoon</h2>',
      renderTycoonAccountRecords(records.tycoon || []),
      '  </div>',
      '</section>'
    ].join("");
  }

  function renderQaAccountRecords(records) {
    if (!records.length) return '<p class="muted">还没有账号下的问答记录。</p>';
    return [
      '<div class="account-record-list">',
      records.map(function (record) {
        return [
          '<article class="account-record-card">',
          '  <div>',
          '    <strong>Room ' + escapeHtml(record.roomCode || record.room_code) + '</strong>',
          '    <p>' + escapeHtml(record.nickname || "未命名") + ' · ' + Number(record.questionCount || record.question_count || 0) + ' 题 · ' + (record.submittedAt || record.submitted_at ? "已提交" : "未提交") + '</p>',
          '  </div>',
          '  <button class="small-button" data-action="open-room" data-code="' + escapeHtml(record.roomCode || record.room_code) + '" type="button">进入</button>',
          '</article>'
        ].join("");
      }).join(""),
      '</div>'
    ].join("");
  }

  function renderTycoonAccountRecords(records) {
    if (!records.length) return '<p class="muted">还没有账号下的大富翁记录。</p>';
    return [
      '<div class="account-record-list">',
      records.map(function (record) {
        return [
          '<article class="account-record-card">',
          '  <div>',
          '    <strong>Room ' + escapeHtml(record.roomCode || record.room_code) + '</strong>',
          '    <p>' + escapeHtml(record.nickname || "未命名") + ' · ' + escapeHtml(tycoonStatusText(record.status)) + ' · ' + escapeHtml(tycoonPlayerStatusText(record.playerStatus || record.player_status)) + '</p>',
          '  </div>',
          '  <button class="small-button" data-action="open-tycoon-room" data-code="' + escapeHtml(record.roomCode || record.room_code) + '" type="button">进入</button>',
          '</article>'
        ].join("");
      }).join(""),
      '</div>'
    ].join("");
  }

  function renderQaHome(state) {
    document.title = "100 Q&As | Friends Games";
    var recentRooms = Object.keys(state.rooms).map(function (id) {
      return state.rooms[id];
    }).sort(function (a, b) {
      return b.createdAt.localeCompare(a.createdAt);
    });

    renderShell([
      '<main class="home-layout">',
      '  <section class="hero-copy">',
      '    <p class="eyebrow">Private friends game</p>',
      '    <h1>100 Q&As</h1>',
      '    <p class="lead">慢慢答完这组问题，提交之后再看朋友们的答案。</p>',
      '    <div class="home-actions">',
      '      <button class="primary-button" data-action="open-create-room">创建房间</button>',
      '      <form class="join-form" data-action="join-code">',
      '        <label for="room-code">输入房间码</label>',
      '        <div class="inline-form">',
      '          <input id="room-code" name="roomCode" type="text" autocomplete="off" maxlength="8" placeholder="例如 Q8M2KA">',
      '          <button type="submit" class="secondary-button">加入</button>',
      '        </div>',
      '      </form>',
      '    </div>',
      recentRooms.length ? renderRecentRooms(recentRooms) : "",
      '  </section>',
      '  <section class="hero-visual" aria-label="100 Q&As visual">',
      '    <img src="assets/question-tabletop.png" alt="">',
      '  </section>',
      '</main>'
    ].join(""), "qa");
  }

  function renderTycoonHome() {
    document.title = "Friends Tycoon | Friends Games";
    var state = loadTycoonState();
    var recentRooms = Object.keys(state.rooms || {}).map(function (id) {
      return state.rooms[id];
    }).sort(function (a, b) {
      return b.createdAt.localeCompare(a.createdAt);
    });

    renderShell([
      '<main class="tycoon-home-layout">',
      '  <section class="tycoon-title-block">',
      '    <h1>Friends Tycoon</h1>',
      '    <p class="lead">文字版线上大富翁。2 到 6 位朋友开房间，轮流掷骰、买地、升级，聊天和游戏记录分开。</p>',
      '  </section>',
      '  <section class="tycoon-setup-grid">',
      '    <section class="panel tycoon-setup-panel">',
      '      <h2>创建房间</h2>',
      '      <form class="stack-form" data-action="tycoon-create-room">',
      '        <label for="tycoon-host-nickname">你的昵称</label>',
      '        <input id="tycoon-host-nickname" name="nickname" maxlength="20" autocomplete="nickname" placeholder="例如 小罗">',
      '        <label for="tycoon-victory-mode">胜利条件</label>',
      '        <select id="tycoon-victory-mode" name="victoryMode">',
      '          <option value="survivor">最后未破产的人获胜</option>',
      '          <option value="turnLimit">达到回合上限后最富有的人获胜</option>',
      '        </select>',
      '        <label for="tycoon-turn-limit">回合上限</label>',
      '        <input id="tycoon-turn-limit" name="turnLimit" type="number" min="10" max="60" step="5" value="30">',
      '        <button class="primary-button" type="submit">创建 Friends Tycoon 房间</button>',
      '      </form>',
      '    </section>',
      '    <section class="panel tycoon-setup-panel">',
      '      <h2>加入房间</h2>',
      '      <form class="stack-form" data-action="tycoon-join-code">',
      '        <label for="tycoon-room-code">房间码</label>',
      '        <input id="tycoon-room-code" name="roomCode" maxlength="8" autocomplete="off" placeholder="例如 T8K2RA">',
      '        <label for="tycoon-nickname">你的昵称</label>',
      '        <input id="tycoon-nickname" name="nickname" maxlength="20" autocomplete="nickname" placeholder="例如 阿Z">',
      '        <button class="secondary-button" type="submit">加入游戏</button>',
      '      </form>',
      recentRooms.length ? renderTycoonRecentRooms(recentRooms) : "",
      '    </section>',
      '    <section class="panel tycoon-setup-panel tycoon-rules-panel">',
      '      <h2>第一版规则</h2>',
      '      <div class="tycoon-rules">',
      '        <div><span>人数</span><strong>2 到 6 人</strong></div>',
      '        <div><span>地图</span><strong>32 格世界旅行</strong></div>',
      '        <div><span>地产</span><strong>购买后最多升到 4 级</strong></div>',
      '        <div><span>退出</span><strong>退出即破产，其他人继续</strong></div>',
      '      </div>',
      '    </section>',
      '</main>'
    ].join(""), "tycoon");
  }

  function renderTycoonRecentRooms(rooms) {
    return [
      '<section class="recent-rooms tycoon-recent-rooms">',
      '  <h2>这个浏览器里的 Tycoon 房间</h2>',
      rooms.slice(0, 4).map(function (room) {
        return [
          '<button class="room-chip" data-action="open-tycoon-room" data-code="' + escapeHtml(room.code) + '">',
          '  <span>' + escapeHtml(room.code) + '</span>',
          '  <small>' + escapeHtml(tycoonStatusText(room.status)) + ' · ' + getTycoonPlayers(room).length + ' 人</small>',
          '</button>'
        ].join("");
      }).join(""),
      '</section>'
    ].join("");
  }

  function renderTycoonRoom(state, code) {
    var room = getTycoonRoomByCode(state, code);
    if (!room) {
      renderTycoonMissingRoom(code);
      return;
    }

    room = normalizeTycoonRoom(room);
    document.title = "Room " + room.code + " | Friends Tycoon";
    var player = getTycoonCurrentPlayer(room);

    renderShell([
      '<main class="tycoon-game-layout">',
      '  <section class="tycoon-game-area">',
      renderTycoonGameHeader(room, player),
      !player && room.status === "lobby" ? renderTycoonJoinPanel(room) : "",
      !player && room.status !== "lobby" ? renderTycoonSpectatorNotice(room) : "",
      '    <section class="tycoon-top-grid">',
      renderTycoonActionPanel(room, player),
      renderTycoonPlayersPanel(room, player),
      '    </section>',
      renderTycoonBoard(room),
      renderTycoonLogPanel(room),
      '  </section>',
      renderTycoonChatPanel(room, player),
      '</main>'
    ].join(""), "tycoon");
  }

  function renderTycoonMissingRoom(code) {
    document.title = "Friends Tycoon | Friends Games";
    renderShell([
      '<main class="narrow-layout">',
      '  <section class="panel">',
      '    <p class="eyebrow">Tycoon room not found</p>',
      '    <h1>没有找到这个房间</h1>',
      '    <p class="muted">房间码 ' + escapeHtml(code || "") + ' 不存在，或线上数据库还没有同步成功。</p>',
      '    <button class="primary-button" data-action="open-tycoon" type="button">回到 Friends Tycoon</button>',
      '  </section>',
      '</main>'
    ].join(""), "tycoon");
  }

  function renderTycoonJoinPanel(room) {
    return [
      '<section class="panel tycoon-inline-join">',
      '  <h2>加入这局 Friends Tycoon</h2>',
      '  <form class="inline-join-form" data-action="tycoon-join-room" data-room-code="' + escapeHtml(room.code) + '">',
      '    <input name="nickname" maxlength="20" autocomplete="nickname" placeholder="填写昵称">',
      '    <button class="primary-button" type="submit">加入</button>',
      '  </form>',
      '</section>'
    ].join("");
  }

  function renderTycoonSpectatorNotice(room) {
    return [
      '<section class="panel tycoon-inline-join">',
      '  <h2>游戏已经开始</h2>',
      '  <p class="muted">这局现在是“' + escapeHtml(tycoonStatusText(room.status)) + '”，未加入的玩家暂时不能中途加入。</p>',
      '</section>'
    ].join("");
  }

  function renderTycoonGameHeader(room, player) {
    var isHost = isTycoonHost(room, player);
    var canStart = isHost && room.status === "lobby" && getTycoonPresentPlayers(room).length >= TYCOON_MIN_PLAYERS;
    var canRestart = isHost && (room.status === "active" || room.status === "finished");
    var canClose = isHost && room.status !== "closed";
    var canExit = player && player.status !== "bankrupt" && (room.status === "lobby" || room.status === "active");
    return [
      '<header class="tycoon-room-header panel">',
      '  <div>',
      '    <p class="eyebrow">Room ' + escapeHtml(room.code) + '</p>',
      '    <h1>Friends Tycoon</h1>',
      '    <p class="muted">' + escapeHtml(tycoonStatusText(room.status)) + ' · 第 ' + Number(room.currentTurn || 1) + ' 回合 · ' + escapeHtml(tycoonVictoryText(room)) + '</p>',
      '  </div>',
      '  <div class="tycoon-room-tools">',
      '    <button class="icon-button" title="复制邀请链接" aria-label="复制邀请链接" data-action="copy-tycoon-link" type="button">↗</button>',
      player && !isSupabaseMode() && room.status === "lobby" ? '    <button class="secondary-button" data-action="new-local-tycoon-player" type="button">本地加朋友</button>' : "",
      canExit ? '    <button class="secondary-button" data-action="tycoon-exit" type="button">退出游戏</button>' : "",
      player && player.status === "bankrupt" ? '    <span class="small-status">已破产</span>' : "",
      canStart ? '    <button class="primary-button" data-action="tycoon-start" type="button">开始游戏</button>' : "",
      isHost && room.status === "lobby" && !canStart ? '    <span class="small-status">至少 2 人开始</span>' : "",
      canRestart ? '    <button class="secondary-button" data-action="tycoon-restart" type="button">重开游戏</button>' : "",
      canClose ? '    <button class="ghost-button" data-action="tycoon-close" type="button">解散房间</button>' : "",
      '  </div>',
      '</header>'
    ].join("");
  }

  function renderTycoonBoard(room) {
    return [
      '<section class="tycoon-board-panel panel" aria-label="Friends Tycoon 地图">',
      '  <div class="tycoon-board">',
      tycoonMap.map(function (cell, index) {
        var property = getTycoonProperty(room, index);
        var playersHere = getTycoonPlayers(room).filter(function (player) {
          return player.position === index && player.status !== "bankrupt";
        });
        var owner = property && property.ownerId ? room.players[property.ownerId] : null;
        return [
          '<div class="tycoon-cell tycoon-cell-' + escapeHtml(cell.type) + '">',
          '  <span>' + index + '</span>',
          '  <strong>' + escapeHtml(cell.name) + '</strong>',
          property ? '  <small>' + (owner ? escapeHtml(owner.nickname) + ' · Lv.' + property.level : '无主 · ' + formatMoney(cell.price)) + '</small>' : renderTycoonCellMeta(cell),
          playersHere.length ? [
          '  <div class="tycoon-tokens">',
          playersHere.map(function (player) {
            return '<b title="' + escapeHtml(player.nickname) + '">' + escapeHtml(player.nickname.slice(0, 1)) + '</b>';
          }).join(""),
          '  </div>'
          ].join("") : "",
          '</div>'
        ].join("");
      }).join(""),
      '  </div>',
      '</section>'
    ].join("");
  }

  function renderTycoonCellMeta(cell) {
    if (cell.type === "bonus") return '  <small>+' + formatMoney(cell.bonus) + '</small>';
    if (cell.type === "tax") return '  <small>-' + formatMoney(cell.fee) + '</small>';
    if (cell.type === "start") return '  <small>经过 +' + formatMoney(TYCOON_PASS_START_REWARD) + '</small>';
    if (cell.type === "chance") return '  <small>随机事件</small>';
    if (cell.type === "airport") return '  <small>交通枢纽</small>';
    return '  <small>休息</small>';
  }

  function renderTycoonActionPanel(room, player) {
    var currentTurnPlayer = room.currentPlayerId ? room.players[room.currentPlayerId] : null;
    var currentCell = player ? getTycoonCell(player.position) : null;
    var currentProperty = player ? getTycoonProperty(room, player.position) : null;
    var isCurrent = Boolean(player && room.currentPlayerId === player.id && player.status === "active");
    var canRoll = room.status === "active" && isCurrent && room.turnPhase === "roll";
    var canAct = room.status === "active" && isCurrent && room.turnPhase === "action";
    var canBuy = canAct && currentCell && currentCell.type === "property" && currentProperty && !currentProperty.ownerId && player.cash >= currentCell.price;
    var canUpgrade = canAct && currentCell && currentCell.type === "property" && currentProperty && currentProperty.ownerId === player.id && currentProperty.level < TYCOON_MAX_LEVEL && player.cash >= currentCell.upgradeCost;
    var waitingCopy = room.status === "lobby"
      ? "等待房主开始。"
      : room.status === "finished"
        ? "游戏已经结束。"
        : currentTurnPlayer
          ? "现在是 " + currentTurnPlayer.nickname + " 的回合。"
          : "等待下一步。";

    return [
      '<section class="tycoon-action-panel panel">',
      '  <div>',
      '    <h2>' + (currentTurnPlayer ? escapeHtml(currentTurnPlayer.nickname) + ' 的回合' : '当前回合') + '</h2>',
      '    <p class="muted">' + escapeHtml(waitingCopy) + '</p>',
      room.lastDice ? '    <div class="dice-result">骰子 ' + Number(room.lastDice) + '</div>' : "",
      player ? '    <p class="tycoon-position">你在：<strong>' + escapeHtml(getTycoonCell(player.position).name) + '</strong></p>' : "",
      '  </div>',
      '  <div class="tycoon-action-buttons">',
      '    <button class="primary-button" data-action="tycoon-roll" type="button" ' + (canRoll ? "" : "disabled") + '>掷骰子</button>',
      '    <button class="secondary-button" data-action="tycoon-buy" type="button" ' + (canBuy ? "" : "disabled") + '>买地</button>',
      '    <button class="secondary-button" data-action="tycoon-upgrade" type="button" ' + (canUpgrade ? "" : "disabled") + '>升级</button>',
      '    <button class="ghost-button" data-action="tycoon-end-turn" type="button" ' + (canAct ? "" : "disabled") + '>结束回合</button>',
      '  </div>',
      player && player.status === "bankrupt" ? '  <p class="submit-hint">你已经破产出局，可以继续看朋友们玩。</p>' : "",
      '</section>'
    ].join("");
  }

  function renderTycoonPlayersPanel(room, currentPlayer) {
    var players = getTycoonPlayers(room);
    return [
      '<section class="tycoon-players-panel panel">',
      '  <h2>玩家</h2>',
      '  <div class="tycoon-player-list">',
      players.map(function (player) {
        var isCurrent = currentPlayer && player.id === currentPlayer.id;
        var isTurn = room.currentPlayerId === player.id;
        return [
          '<div class="tycoon-player-row' + (isCurrent ? " is-current" : "") + (isTurn ? " is-turn" : "") + '">',
          '  <div>',
          '    <strong>' + escapeHtml(player.nickname) + (isTycoonHost(room, player) ? ' <span>房主</span>' : '') + '</strong>',
          '    <small>' + escapeHtml(tycoonPlayerStatusText(player.status)) + ' · 位置 ' + Number(player.position || 0) + '</small>',
          '  </div>',
          '  <div>',
          '    <strong>' + formatMoney(player.cash) + '</strong>',
          '    <small>净值 ' + formatMoney(tycoonNetWorth(room, player)) + '</small>',
          '  </div>',
          isCurrent
            ? '  <span class="small-status">当前</span>'
            : isSupabaseMode()
              ? '  <span class="small-status">朋友</span>'
              : '  <button class="small-button" data-action="switch-tycoon-player" data-player-id="' + escapeHtml(player.id) + '" type="button">切换</button>',
          '</div>'
        ].join("");
      }).join(""),
      '  </div>',
      room.finalResults ? renderTycoonFinalResults(room.finalResults) : "",
      '</section>'
    ].join("");
  }

  function renderTycoonFinalResults(finalResults) {
    return [
      '<section class="tycoon-final-results">',
      '  <h2>最终结果</h2>',
      '  <p class="muted">胜利者：' + escapeHtml(finalResults.winnerName || "暂无") + '</p>',
      '  <ol>',
      (finalResults.results || []).map(function (result) {
        return '<li><strong>' + escapeHtml(result.nickname) + '</strong><span>现金 ' + formatMoney(result.cash) + ' · 净值 ' + formatMoney(result.netWorth) + '</span></li>';
      }).join(""),
      '  </ol>',
      '</section>'
    ].join("");
  }

  function renderTycoonLogPanel(room) {
    var logs = room.logs || [];
    return [
      '<section class="tycoon-log-panel panel">',
      '  <h2>游戏记录</h2>',
      '  <div class="tycoon-log-list">',
      logs.length ? logs.slice(0, 40).map(function (log) {
        return '<p><span>' + escapeHtml(formatTime(log.createdAt)) + '</span>' + escapeHtml(log.message) + '</p>';
      }).join("") : '<p class="muted">还没有游戏记录。</p>',
      '  </div>',
      '</section>'
    ].join("");
  }

  function renderTycoonChatPanel(room, player) {
    var messages = room.messages || [];
    var canChat = Boolean(player && player.status !== "bankrupt" && room.status !== "closed" && room.status !== "finished");
    return [
      '<aside class="tycoon-chat-panel panel">',
      '  <h2>聊天</h2>',
      '  <div class="tycoon-chat-list">',
      messages.length ? messages.map(function (message) {
        return [
          '<div class="tycoon-message' + (player && message.playerId === player.id ? " is-me" : "") + '">',
          '  <strong>' + escapeHtml(message.nickname) + '</strong>',
          '  <p>' + escapeHtml(message.content) + '</p>',
          '</div>'
        ].join("");
      }).join("") : '<p class="muted">聊天只保留当前局最近消息。</p>',
      '  </div>',
      '  <form class="tycoon-chat-form" data-action="tycoon-chat">',
      '    <input name="message" maxlength="180" placeholder="' + (canChat ? "说点什么..." : "当前不能发送聊天") + '" ' + (canChat ? "" : "disabled") + '>',
      '    <button class="primary-button" type="submit" ' + (canChat ? "" : "disabled") + '>发送</button>',
      '  </form>',
      '</aside>'
    ].join("");
  }

  function tycoonStatusText(status) {
    if (status === "lobby") return "等待开始";
    if (status === "active") return "游戏中";
    if (status === "finished") return "已结束";
    if (status === "closed") return "已解散";
    return "未知状态";
  }

  function tycoonPlayerStatusText(status) {
    if (status === "waiting") return "等待中";
    if (status === "active") return "游戏中";
    if (status === "bankrupt") return "已破产";
    return "未知";
  }

  function tycoonVictoryText(room) {
    if (room.victoryMode === "turnLimit") {
      return "回合上限 " + Number(room.turnLimit || 30) + "，最富有者获胜";
    }
    return "最后未破产者获胜";
  }

  function formatTime(value) {
    var date = value ? new Date(value) : new Date();
    if (Number.isNaN(date.getTime())) return "";
    return date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  }

  function renderCreateRoom() {
    var selectedQuestions = getSelectedCreateQuestions();
    var isDefault = createRoomDraft.mode === "default";
    var previewQuestions = selectedQuestions.slice(0, 3);

    renderShell([
      '<main class="narrow-layout">',
      '  <section class="panel create-panel">',
      '    <p class="eyebrow">New room</p>',
      '    <h1>创建房间</h1>',
      '    <form class="stack-form" data-action="create-room">',
      '      <fieldset class="question-source">',
      '        <legend>题库</legend>',
      '        <div class="segmented-control" role="group" aria-label="题库来源">',
      '          <button type="button" class="' + (isDefault ? "is-active" : "") + '" data-action="set-question-mode" data-mode="default">默认 100 题</button>',
      '          <button type="button" class="' + (!isDefault ? "is-active" : "") + '" data-action="set-question-mode" data-mode="custom">自定义题库</button>',
      '        </div>',
      '      </fieldset>',
      isDefault ? "" : [
      '      <section class="question-builder">',
      '        <label for="question-file">上传题库文件</label>',
      '        <input class="file-input" id="question-file" type="file" accept=".txt,.md,.csv,text/plain,text/markdown,text/csv" data-question-file>',
      '        <label for="question-bank">粘贴题目</label>',
      '        <textarea id="question-bank" data-question-bank rows="9" placeholder="1. 晴天 or 雨天?&#10;2. 此时此刻在哪里?">' + escapeHtml(createRoomDraft.rawText) + '</textarea>',
      '      </section>'
      ].join(""),
      '      <section class="question-check">',
      '        <strong data-question-count>' + escapeHtml(questionBankStatus(selectedQuestions)) + '</strong>',
      previewQuestions.length ? [
      '        <ol data-question-preview>',
      previewQuestions.map(function (question) {
        return '          <li>' + escapeHtml(question) + '</li>';
      }).join(""),
      '        </ol>'
      ].join("") : '        <ol data-question-preview></ol>',
      '      </section>',
      '      <div class="dialog-actions">',
      '        <button type="button" class="secondary-button" data-action="open-qa">返回</button>',
      '        <button class="primary-button" type="submit" data-create-submit>生成房间</button>',
      '      </div>',
      '    </form>',
      '  </section>',
      '</main>'
    ].join(""), "qa");
  }

  function renderRecentRooms(rooms) {
    return [
      '<section class="recent-rooms">',
      '  <h2>这个浏览器里的房间</h2>',
      rooms.slice(0, 4).map(function (room) {
        var submitted = Object.keys(room.players).filter(function (id) {
          return room.players[id].submittedAt;
        }).length;
        return [
          '<button class="room-chip" data-action="open-room" data-code="' + escapeHtml(room.code) + '">',
          '  <span>' + escapeHtml(room.code) + '</span>',
          '  <small>' + Object.keys(room.players).length + ' 人加入 · ' + submitted + ' 人提交</small>',
          '</button>'
        ].join("");
      }).join(""),
      '</section>'
    ].join("");
  }

  function renderRoom(state, code) {
    var room = getRoomByCode(state, code);
    if (!room) {
      renderMissingRoom(code);
      return;
    }

    var player = getCurrentPlayer(room);
    if (!player) {
      renderJoinRoom(room);
      return;
    }

    if (player.submittedAt) {
      renderResults(room, player);
      return;
    }

    renderAnswerPage(room, player);
  }

  function renderMissingRoom(code) {
    renderShell([
      '<main class="narrow-layout">',
      '  <section class="panel">',
      '    <p class="eyebrow">Room not found</p>',
      '    <h1>没有找到这个房间</h1>',
      '    <p class="muted">房间码 ' + escapeHtml(code || "") + ' 不存在，或暂时没有同步成功。</p>',
      '    <button class="primary-button" data-action="open-lobby">回到游戏大厅</button>',
      '  </section>',
      '</main>'
    ].join(""), "qa");
  }

  function renderJoinRoom(room) {
    var existingPlayers = getRoomPlayers(room);

    renderShell([
      '<main class="narrow-layout">',
      '  <section class="panel">',
      '    <p class="eyebrow">Room ' + escapeHtml(room.code) + '</p>',
      '    <h1>加入这局 100 Q&As</h1>',
      '    <p class="muted">填写一个朋友们认得出的昵称，就可以开始答题。</p>',
      '    <form class="stack-form" data-action="join-room" data-room-id="' + escapeHtml(room.id) + '">',
      '      <label for="nickname">昵称</label>',
      '      <input id="nickname" name="nickname" type="text" maxlength="20" autocomplete="nickname" placeholder="例如 小罗">',
      '      <button class="primary-button" type="submit">开始答题</button>',
      '    </form>',
      existingPlayers.length ? renderLocalPlayers(room, null) : "",
      '  </section>',
      '</main>'
    ].join(""), "qa");
  }

  function renderAnswerPage(room, player) {
    var roomQuestions = getRoomQuestions(room);
    var page = Math.min(Math.max(getCurrentPage(room, player), 0), Math.ceil(roomQuestions.length / PAGE_SIZE) - 1);
    var start = page * PAGE_SIZE;
    var pageQuestions = roomQuestions.slice(start, start + PAGE_SIZE);
    var done = answeredCount(player, room);
    var canSubmit = done === roomQuestions.length;

    renderShell([
      '<main class="answer-layout">',
      renderRoomHeader(room, player, done),
      renderRoomSummary(room, player),
      '  <section class="question-stack">',
      pageQuestions.map(function (question, offset) {
        var number = start + offset + 1;
        var value = player.answers[String(number)] || "";
        return [
          '<article class="question-card">',
          '  <div class="question-number">Q' + number + '</div>',
          '  <label for="answer-' + number + '">' + escapeHtml(question) + '</label>',
          '  <textarea id="answer-' + number + '" data-question="' + number + '" rows="4" placeholder="写下你的答案">' + escapeHtml(value) + '</textarea>',
          '</article>'
        ].join("");
      }).join(""),
      '  </section>',
      '  <nav class="pager" aria-label="答题分页">',
      '    <button class="secondary-button" data-action="prev-page" ' + (page === 0 ? "disabled" : "") + '>上一页</button>',
      '    <span>第 ' + (page + 1) + ' / ' + Math.ceil(roomQuestions.length / PAGE_SIZE) + ' 页</span>',
      page === Math.ceil(roomQuestions.length / PAGE_SIZE) - 1
        ? '<button class="primary-button" data-action="submit-answers" ' + (canSubmit ? "" : "disabled") + '>提交答案</button>'
        : '<button class="primary-button" data-action="next-page">下一页</button>',
      '  </nav>',
      canSubmit ? "" : '<p class="submit-hint">还差 ' + (roomQuestions.length - done) + ' 题就可以提交。</p>',
      '</main>'
    ].join(""), "qa");
  }

  function renderRoomHeader(room, player, done) {
    var roomQuestions = getRoomQuestions(room);
    var progress = Math.round((done / roomQuestions.length) * 100);
    return [
      '<header class="room-header">',
      '  <div>',
      '    <p class="eyebrow">Room ' + escapeHtml(room.code) + '</p>',
      '    <h1>' + escapeHtml(player.nickname) + ' 的 ' + roomQuestions.length + ' Q&As</h1>',
      '  </div>',
      '  <div class="room-tools">',
      '    <button class="icon-button" title="复制邀请链接" aria-label="复制邀请链接" data-action="copy-link">↗</button>',
      '    <button class="ghost-button" data-action="new-local-player">换个昵称加入</button>',
      '  </div>',
      '  <div class="progress-wrap" aria-label="答题进度">',
      '    <div class="progress-track"><div class="progress-bar" style="width:' + progress + '%"></div></div>',
      '    <span>' + done + ' / ' + roomQuestions.length + ' 已回答</span>',
      '  </div>',
      '  <p class="save-status" id="save-status">草稿会自动保存</p>',
      '</header>'
    ].join("");
  }

  function renderRoomSummary(room, currentPlayer) {
    var players = getRoomPlayers(room);
    var roomQuestions = getRoomQuestions(room);
    return [
      '<section class="room-summary" aria-label="房间进度">',
      '  <div class="summary-stats">',
      '    <div><span>加入</span><strong>' + players.length + ' 人</strong></div>',
      '    <div><span>提交</span><strong>' + submittedCount(room) + ' 人</strong></div>',
      '    <div><span>题库</span><strong>' + roomQuestions.length + ' 题</strong></div>',
      '    <div><span>房间码</span><strong>' + escapeHtml(room.code) + '</strong></div>',
      '  </div>',
      renderLocalPlayers(room, currentPlayer),
      '</section>'
    ].join("");
  }

  function renderLocalPlayers(room, currentPlayer) {
    var players = getRoomPlayers(room);
    var roomQuestions = getRoomQuestions(room);
    if (!players.length) return "";

    return [
      '<section class="local-players">',
      '  <h2>' + (isSupabaseMode() ? "参与者" : "本地玩家") + '</h2>',
      '  <div class="player-list">',
      players.map(function (player) {
        var isCurrent = currentPlayer && player.id === currentPlayer.id;
        var done = answeredCount(player, room);
        var status = player.submittedAt ? "已提交" : "已答 " + done + "/" + roomQuestions.length;
        return [
          '<div class="player-row' + (isCurrent ? " is-current" : "") + '">',
          '  <div>',
          '    <strong>' + escapeHtml(player.nickname) + '</strong>',
          '    <span data-player-status="' + escapeHtml(player.id) + '">' + status + '</span>',
          '  </div>',
          isCurrent
            ? '  <button class="small-button" disabled>当前</button>'
            : isSupabaseMode()
              ? '  <span class="small-status">朋友</span>'
              : '  <button class="small-button" data-action="switch-player" data-player-id="' + escapeHtml(player.id) + '">切换</button>',
          '</div>'
        ].join("");
      }).join(""),
      '  </div>',
      '</section>'
    ].join("");
  }

  function renderResults(room, player) {
    var roomQuestions = getRoomQuestions(room);
    var submittedPlayers = Object.keys(room.players)
      .map(function (id) { return room.players[id]; })
      .filter(function (item) { return Boolean(item.submittedAt); });

    renderShell([
      '<main class="results-layout">',
      '  <header class="room-header">',
      '    <div>',
      '      <p class="eyebrow">Room ' + escapeHtml(room.code) + '</p>',
      '      <h1>大家的答案</h1>',
      '      <p class="muted">按题目查看，当前展示已提交的 ' + submittedPlayers.length + ' 位朋友。你的答案已经锁定。</p>',
      '    </div>',
      '    <div class="room-tools">',
      '      <button class="icon-button" title="复制邀请链接" aria-label="复制邀请链接" data-action="copy-link">↗</button>',
      '      <button class="secondary-button" data-action="open-qa-export" data-code="' + escapeHtml(room.code) + '">导出 PDF</button>',
      '      <button class="secondary-button" data-action="new-local-player">' + (isSupabaseMode() ? "换个昵称加入" : "再加一位本地玩家") + '</button>',
      '    </div>',
      '  </header>',
      renderRoomSummary(room, player),
      '  <section class="result-list">',
      roomQuestions.map(function (question, index) {
        var number = index + 1;
        return [
          '<article class="result-card">',
          '  <div class="result-question">',
          '    <span>Q' + number + '</span>',
          '    <h2>' + escapeHtml(question) + '</h2>',
          '  </div>',
          submittedPlayers.map(function (submittedPlayer) {
            var answer = submittedPlayer.answers[String(number)] || "";
            return [
              '<div class="answer-row">',
              '  <strong>' + escapeHtml(submittedPlayer.nickname) + '</strong>',
              '  <p>' + escapeHtml(answer) + '</p>',
              '</div>'
            ].join("");
          }).join(""),
          '  </article>'
        ].join("");
      }).join(""),
      '  </section>',
      '</main>'
    ].join(""), "qa");
  }

  function renderQaExportPage(state, code) {
    var room = getRoomByCode(state, code);
    if (!room) {
      renderMissingRoom(code);
      return;
    }

    var player = getCurrentPlayer(room);
    var roomQuestions = getRoomQuestions(room);
    var submittedPlayers = getRoomPlayers(room).filter(function (item) {
      return Boolean(item.submittedAt);
    });

    if (!player || !player.submittedAt) {
      renderShell([
        '<main class="narrow-layout">',
        '  <section class="panel">',
        '    <p class="eyebrow">PDF export</p>',
        '    <h1>暂时不能导出</h1>',
        '    <p class="muted">你需要先提交自己的答案，才能导出同一房间里已提交朋友的答案。</p>',
        '    <button class="primary-button" data-action="open-room" data-code="' + escapeHtml(room.code) + '">回到房间</button>',
        '  </section>',
        '</main>'
      ].join(""), "qa");
      return;
    }

    document.title = "Room " + room.code + " PDF | 100 Q&As";
    renderShell([
      '<main class="pdf-export-layout">',
      '  <section class="pdf-toolbar panel">',
      '    <div>',
      '      <p class="eyebrow">PDF export</p>',
      '      <h1>100 Q&As 导出</h1>',
      '      <p class="muted">Room ' + escapeHtml(room.code) + ' · ' + roomQuestions.length + ' 题 · ' + submittedPlayers.length + ' 位已提交玩家</p>',
      '    </div>',
      '    <div class="dialog-actions">',
      '      <button class="secondary-button" data-action="open-room" data-code="' + escapeHtml(room.code) + '">返回结果页</button>',
      '      <button class="primary-button" data-action="print-pdf">打印 / 保存 PDF</button>',
      '    </div>',
      '  </section>',
      '  <article class="pdf-document">',
      '    <header>',
      '      <p>Room ' + escapeHtml(room.code) + '</p>',
      '      <h1>100 Q&As</h1>',
      '      <p>导出范围：所有已提交玩家的答案</p>',
      '    </header>',
      roomQuestions.map(function (question, index) {
        var number = index + 1;
        return [
          '<section class="pdf-question">',
          '  <h2>Q' + number + '. ' + escapeHtml(question) + '</h2>',
          submittedPlayers.map(function (submittedPlayer) {
            return [
              '<div class="pdf-answer">',
              '  <strong>' + escapeHtml(submittedPlayer.nickname) + '</strong>',
              '  <p>' + escapeHtml(submittedPlayer.answers[String(number)] || "") + '</p>',
              '</div>'
            ].join("");
          }).join(""),
          '</section>'
        ].join("");
      }).join(""),
      '  </article>',
      '</main>'
    ].join(""), "qa");
  }

  function authFriendlyError(error) {
    var message = error && error.message ? error.message : "";
    var normalized = message.toLowerCase();
    if (/rate limit|too many|over_email_send_rate_limit|email rate limit/.test(normalized)) return "注册邮件发送太频繁，Supabase 暂时限流了。请稍后再试，或先在 Supabase Auth 里关闭邮箱确认。";
    if (/email.*not.*confirm|confirm.*email|email_not_confirmed/.test(normalized)) return "这个账号还没完成邮箱确认，请先去邮箱里点确认链接再登录。";
    if (/email.*invalid|invalid.*email|email address.*invalid|email_address_invalid/.test(normalized)) return "这个邮箱暂时不能用于注册，请换一个常用邮箱再试。";
    if (/already/i.test(message) || /registered/i.test(message) || /exists/i.test(message)) return "这个邮箱可能已经注册，可以直接登录。";
    if (/password/i.test(message) || /weak_password/i.test(message)) return "密码至少需要 6 位，建议包含字母和数字。";
    if (/invalid/i.test(message) || /credentials/i.test(message)) return "账号或密码不正确。";
    return "账号操作失败，请稍后再试。";
  }

  async function loginAccount(email, password) {
    var safeEmail = normalizeEmail(email);
    if (!safeEmail || !password) {
      showToast("请填写邮箱和密码。");
      return;
    }

    try {
      var result = await authRequest("/token?grant_type=password", {
        email: safeEmail,
        password: String(password || "")
      });
      var session = normalizeAuthSession(result);
      saveAuthSession(session);
      showToast("已登录。");
      render();
    } catch (error) {
      showToast(authFriendlyError(error));
    }
  }

  async function registerAccountFromForm(form) {
    var formData = new FormData(form);
    var safeEmail = normalizeEmail(formData.get("email"));
    var password = String(formData.get("password") || "");
    if (!safeEmail || !password) {
      showToast("请填写邮箱和密码。");
      return;
    }

    try {
      var result = await authRequest("/signup", {
        email: safeEmail,
        password: password
      });
      var session = normalizeAuthSession(result);
      if (session && session.access_token) {
        saveAuthSession(session);
        showToast("注册成功，已登录。");
        render();
      } else {
        showToast("注册成功。若系统要求邮箱确认，请先到邮箱里确认后再登录。");
      }
    } catch (error) {
      showToast(authFriendlyError(error));
    }
  }

  async function logoutAccount() {
    var token = getAuthAccessToken();
    try {
      if (token) {
        await authRequest("/logout", null, {
          accessToken: token
        });
      }
    } catch (error) {
      // Local sign-out should still clear the session if the remote logout call fails.
    }
    clearAuthSession();
    showToast("已退出登录。");
    render();
  }

  async function bindDeviceRecordsToAccount() {
    if (!isLoggedIn()) {
      showToast("请先登录账号。");
      return;
    }

    var payload = collectDeviceBindingPayload();
    var total = payload.qaPlayers.length + payload.tycoonPlayers.length;
    if (!total) {
      showToast("这台设备里没有可绑定的匿名记录。");
      return;
    }

    try {
      var result = await supabaseRpc("account_bind_records", {
        p_qa_players: payload.qaPlayers,
        p_tycoon_players: payload.tycoonPlayers
      });
      accountRecordsCache = null;
      showToast("已绑定 " + (Number(result && result.qaBound || 0) + Number(result && result.tycoonBound || 0)) + " 条记录。");
      render();
    } catch (error) {
      showToast("绑定失败，请确认已运行最新版 Supabase SQL。");
    }
  }

  async function createRoom(roomQuestions) {
    var selectedQuestions = normalizeQuestionArray(roomQuestions);
    var isCustom = createRoomDraft.mode === "custom";

    if (!isQuestionBankReady(selectedQuestions)) {
      showToast(questionBankProblem(selectedQuestions));
      return;
    }

    if (isSupabaseMode()) {
      try {
        var payload = { p_questions: selectedQuestions };
        var bundle;

        try {
          bundle = await supabaseRpc("qa_create_room", payload);
        } catch (error) {
          if (isCustom) {
            throw error;
          }
          bundle = await supabaseRpc("qa_create_room", {});
        }

        var onlineRoom = normalizeOnlineRoom(bundle);
        if (!onlineRoom) throw new Error("Room was not created.");
        cacheRoom(onlineRoom);
        resetCreateRoomDraft();
        setRoute("qa/room/" + onlineRoom.code);
      } catch (error) {
        showToast(isCustom ? "自定义题库线上创建失败，请确认已运行最新版 Supabase SQL。" : "线上房间创建失败，请检查 Supabase 配置。");
      }
      return;
    }

    var state = loadState();
    var code = makeRoomCode();
    while (getRoomByCode(state, code)) {
      code = makeRoomCode();
    }

    var room = {
      id: makeId("room"),
      code: code,
      title: "100 Q&As",
      createdAt: new Date().toISOString(),
      questions: selectedQuestions.slice(),
      players: {}
    };

    state.rooms[room.id] = room;
    saveState(state);
    resetCreateRoomDraft();
    setRoute("qa/room/" + room.code);
  }

  function submitCreateRoom() {
    createRoom(getSelectedCreateQuestions());
  }

  function setQuestionMode(mode) {
    createRoomDraft.mode = mode === "custom" ? "custom" : "default";
    if (createRoomDraft.mode === "default") {
      createRoomDraft.questions = defaultQuestions.slice();
    } else {
      createRoomDraft.questions = parseQuestionText(createRoomDraft.rawText);
    }
    renderCreateRoom();
  }

  function updateCreateQuestionDraft(rawText) {
    createRoomDraft.rawText = rawText;
    createRoomDraft.questions = parseQuestionText(rawText);
    renderCreateQuestionStatus();
  }

  function renderCreateQuestionStatus() {
    var selectedQuestions = getSelectedCreateQuestions();
    var count = document.querySelector("[data-question-count]");
    var preview = document.querySelector("[data-question-preview]");
    var submit = document.querySelector("[data-create-submit]");

    if (count) {
      count.textContent = questionBankStatus(selectedQuestions);
    }

    if (preview) {
      preview.innerHTML = selectedQuestions.slice(0, 3).map(function (question) {
        return "<li>" + escapeHtml(question) + "</li>";
      }).join("");
    }

    if (submit) submit.disabled = false;
  }

  function loadQuestionFile(file) {
    if (!file) return;

    if (file.size > MAX_QUESTION_FILE_BYTES) {
      showToast("题库文件太大，请换成纯文本题库。");
      return;
    }

    var reader = new FileReader();
    reader.onload = function () {
      createRoomDraft.mode = "custom";
      updateCreateQuestionDraft(String(reader.result || ""));
      var textarea = document.querySelector("[data-question-bank]");
      if (textarea) textarea.value = createRoomDraft.rawText;
      showToast("题库文件已读取");
    };
    reader.onerror = function () {
      showToast("题库文件读取失败，请直接粘贴题目。");
    };
    reader.readAsText(file);
  }

  async function joinRoom(roomId, nickname) {
    var state = loadState();
    var room = state.rooms[roomId];
    if (!room) return;

    var trimmed = nickname.trim();
    if (!trimmed) return;

    if (isSupabaseMode()) {
      try {
        var playerKey = makePlayerKey();
        var bundle = await supabaseRpc("qa_join_room", {
          p_room_code: room.code,
          p_nickname: trimmed,
          p_player_key: playerKey
        });
        var onlineRoom = normalizeOnlineRoom(bundle);
        if (!onlineRoom || !bundle.currentPlayerId) throw new Error("Player was not created.");
        cacheRoom(onlineRoom);
        saveIdentity(onlineRoom, {
          playerId: bundle.currentPlayerId,
          playerKey: playerKey,
          lastPage: 0
        });
        render({ skipOnlineSync: true });
      } catch (error) {
        showToast("加入线上房间失败，请稍后再试。");
      }
      return;
    }

    var player = {
      id: makeId("player"),
      nickname: trimmed,
      createdAt: new Date().toISOString(),
      submittedAt: null,
      lastPage: 0,
      answers: {}
    };

    room.players[player.id] = player;
    saveState(state);

    saveIdentity(room, player.id);
    render();
  }

  function updateAnswer(questionNumber, content) {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player || player.submittedAt) return;

    player.answers[String(questionNumber)] = content;
    saveState(state);
    scheduleOnlineAnswerSave(room, player, questionNumber, content);

    var status = document.getElementById("save-status");
    if (status) status.textContent = "正在保存...";
    window.clearTimeout(saveTimer);
    saveTimer = window.setTimeout(function () {
      var latestStatus = document.getElementById("save-status");
      if (latestStatus) latestStatus.textContent = "已保存";
      renderProgressOnly(room.id, player.id);
    }, 250);
  }

  function scheduleOnlineAnswerSave(room, player, questionNumber, content) {
    if (!isSupabaseMode()) return;

    var identity = getIdentity(room);
    if (!identity || getIdentityPlayerId(identity) !== player.id) return;

    var key = room.code + ":" + player.id + ":" + questionNumber;
    window.clearTimeout(remoteAnswerTimers[key]);
    remoteAnswerTimers[key] = window.setTimeout(function () {
      delete remoteAnswerTimers[key];

      var latestState = loadState();
      var latestRoom = getRoomByCode(latestState, room.code);
      var latestPlayer = latestRoom && latestRoom.players[player.id];
      if (!latestPlayer || latestPlayer.submittedAt) return;

      supabaseRpc("qa_save_answer", {
        p_room_code: room.code,
        p_player_id: player.id,
        p_player_key: identity.playerKey || null,
        p_question_index: Number(questionNumber),
        p_content: content
      }).catch(function () {
        showToast("这题暂时没有同步成功，稍后会在提交时再保存。");
      });
    }, 500);
  }

  function clearOnlineAnswerTimers(room, player) {
    if (!room || !player) return;

    var prefix = room.code + ":" + player.id + ":";
    Object.keys(remoteAnswerTimers).forEach(function (key) {
      if (key.indexOf(prefix) === 0) {
        window.clearTimeout(remoteAnswerTimers[key]);
        delete remoteAnswerTimers[key];
      }
    });
  }

  function renderProgressOnly(roomId, playerId) {
    var state = loadState();
    var room = state.rooms[roomId];
    if (!room || !room.players[playerId]) return;
    var roomQuestions = getRoomQuestions(room);
    var done = answeredCount(room.players[playerId], room);
    var progress = Math.round((done / roomQuestions.length) * 100);
    var bar = document.querySelector(".progress-bar");
    var label = document.querySelector(".progress-wrap span");
    var hint = document.querySelector(".submit-hint");
    var submit = document.querySelector('[data-action="submit-answers"]');
    var playerStatus = document.querySelector('[data-player-status="' + playerId + '"]');
    if (bar) bar.style.width = progress + "%";
    if (label) label.textContent = done + " / " + roomQuestions.length + " 已回答";
    if (hint) hint.textContent = done === roomQuestions.length ? "" : "还差 " + (roomQuestions.length - done) + " 题就可以提交。";
    if (submit) submit.disabled = done !== roomQuestions.length;
    if (playerStatus) playerStatus.textContent = "已答 " + done + "/" + roomQuestions.length;
  }

  function changePage(delta) {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player) return;

    var maxPage = Math.ceil(getRoomQuestions(room).length / PAGE_SIZE) - 1;
    var page = Math.min(Math.max(getCurrentPage(room, player) + delta, 0), maxPage);
    setCurrentPage(room, player, page);
    saveState(state);
    render({ skipOnlineSync: true });
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function submitAnswers() {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player) return;
    var roomQuestions = getRoomQuestions(room);

    if (answeredCount(player, room) !== roomQuestions.length) {
      renderProgressOnly(room.id, player.id);
      return;
    }

    showSubmitConfirm(room, player);
  }

  async function finishSubmitAnswers() {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player || player.submittedAt) return;
    var roomQuestions = getRoomQuestions(room);

    if (answeredCount(player, room) !== roomQuestions.length) {
      closeSubmitConfirm();
      renderProgressOnly(room.id, player.id);
      return;
    }

    if (isSupabaseMode()) {
      var identity = getIdentity(room);
      if (!identity || getIdentityPlayerId(identity) !== player.id) {
        showToast("无法确认当前玩家身份，请重新加入房间。");
        return;
      }

      try {
        clearOnlineAnswerTimers(room, player);
        var bundle = await supabaseRpc("qa_submit_player", {
          p_room_code: room.code,
          p_player_id: player.id,
          p_player_key: identity.playerKey || null,
          p_answers: player.answers
        });
        var onlineRoom = normalizeOnlineRoom(bundle);
        if (onlineRoom) cacheRoom(onlineRoom);
        closeSubmitConfirm();
        render({ skipOnlineSync: true });
        window.scrollTo({ top: 0, behavior: "smooth" });
      } catch (error) {
        showToast("提交失败，请确认所有题目都已填写并稍后再试。");
      }
      return;
    }

    player.submittedAt = new Date().toISOString();
    saveState(state);
    closeSubmitConfirm();
    render();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function showSubmitConfirm(room, player) {
    closeSubmitConfirm();
    var total = getRoomQuestions(room).length;

    var overlay = document.createElement("div");
    overlay.className = "modal-backdrop";
    overlay.setAttribute("role", "presentation");
    overlay.innerHTML = [
      '<section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="submit-title">',
      '  <p class="eyebrow">Submit answers</p>',
      '  <h2 id="submit-title">确认提交吗?</h2>',
      '  <p>提交后，' + escapeHtml(player.nickname) + ' 的 ' + total + ' 个答案就会锁定，不能再修改。提交完成后可以查看同一房间里已提交朋友的答案。</p>',
      '  <div class="dialog-actions">',
      '    <button class="secondary-button" data-action="cancel-submit">再检查一下</button>',
      '    <button class="primary-button" data-action="confirm-submit">确认提交</button>',
      '  </div>',
      '</section>'
    ].join("");

    document.body.appendChild(overlay);
    var confirmButton = overlay.querySelector('[data-action="confirm-submit"]');
    if (confirmButton) confirmButton.focus();
  }

  function showTycoonConfirm(title, message, confirmAction, confirmLabel) {
    closeSubmitConfirm();
    var overlay = document.createElement("div");
    overlay.className = "modal-backdrop";
    overlay.setAttribute("role", "presentation");
    overlay.innerHTML = [
      '<section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="tycoon-confirm-title">',
      '  <p class="eyebrow">Friends Tycoon</p>',
      '  <h2 id="tycoon-confirm-title">' + escapeHtml(title) + '</h2>',
      '  <p>' + escapeHtml(message) + '</p>',
      '  <div class="dialog-actions">',
      '    <button class="secondary-button" data-action="cancel-submit" type="button">先不操作</button>',
      '    <button class="primary-button" data-action="' + escapeHtml(confirmAction) + '" type="button">' + escapeHtml(confirmLabel || "确认") + '</button>',
      '  </div>',
      '</section>'
    ].join("");
    document.body.appendChild(overlay);
    var confirmButton = overlay.querySelector('[data-action="' + confirmAction + '"]');
    if (confirmButton) confirmButton.focus();
  }

  function closeSubmitConfirm() {
    var existing = document.querySelector(".modal-backdrop");
    if (existing) existing.remove();
  }

  function copyLink() {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room) return;
    var link = roomLink(room);

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(link).then(function () {
        showToast("邀请链接已复制");
      }).catch(function () {
        showToast(link);
      });
      return;
    }

    showToast(link);
  }

  function showToast(message) {
    var toast = document.createElement("div");
    toast.className = "toast";
    toast.textContent = message;
    document.body.appendChild(toast);
    window.setTimeout(function () {
      toast.remove();
    }, 2600);
  }

  function clearCurrentPlayer() {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room) return;

    var identities = loadIdentities();
    delete identities[room.id];
    delete identities[room.code];
    saveIdentities(identities);
    render();
  }

  function switchPlayer(playerId) {
    var state = loadState();
    var room = getRoomByCode(state, getQaRoomCode());
    if (!room || !room.players[playerId]) return;

    if (isSupabaseMode()) {
      showToast("线上模式不能切换到朋友身份。");
      return;
    }

    saveIdentity(room, playerId);
    render();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function createTycoonRoom(nickname, victoryMode, turnLimit) {
    var trimmed = String(nickname || "").trim();
    if (!trimmed) {
      showToast("先填一个昵称。");
      return;
    }

    var safeVictoryMode = victoryMode === "turnLimit" ? "turnLimit" : "survivor";
    var safeTurnLimit = Math.min(Math.max(Number(turnLimit || 30), 10), 60);

    if (isSupabaseMode()) {
      try {
        var playerKey = makePlayerKey();
        var bundle = await supabaseRpc("tycoon_create_room", {
          p_nickname: trimmed,
          p_player_key: playerKey,
          p_victory_mode: safeVictoryMode,
          p_turn_limit: safeTurnLimit
        });
        var onlineRoom = normalizeOnlineTycoonRoom(bundle);
        if (!onlineRoom || !bundle.currentPlayerId) throw new Error("Tycoon room was not created.");
        cacheTycoonRoom(onlineRoom);
        saveTycoonIdentity(onlineRoom, {
          playerId: bundle.currentPlayerId,
          playerKey: playerKey
        });
        setRoute("tycoon/room/" + onlineRoom.code);
      } catch (error) {
        showToast(onlineTycoonErrorMessage());
      }
      return;
    }

    var state = loadTycoonState();
    var code = makeRoomCode();
    while (getTycoonRoomByCode(state, code)) {
      code = makeRoomCode();
    }

    var host = {
      id: makeId("tycoon-player"),
      nickname: trimmed,
      cash: TYCOON_START_CASH,
      position: 0,
      status: "waiting",
      createdAt: new Date().toISOString()
    };
    var room = {
      id: makeId("tycoon-room"),
      code: code,
      hostPlayerId: host.id,
      status: "lobby",
      victoryMode: safeVictoryMode,
      turnLimit: safeTurnLimit,
      currentTurn: 1,
      currentPlayerId: null,
      turnPhase: "roll",
      lastDice: null,
      finalResults: null,
      createdAt: new Date().toISOString(),
      map: tycoonMap.slice(),
      players: {},
      properties: makeTycoonProperties(),
      logs: [],
      messages: []
    };
    room.players[host.id] = host;
    appendTycoonLog(room, host.nickname + " 创建了房间。", "host");
    state.rooms[room.id] = room;
    saveTycoonState(state);
    saveTycoonIdentity(room, host.id);
    setRoute("tycoon/room/" + room.code);
  }

  async function joinTycoonRoomByCode(code, nickname) {
    var roomCode = String(code || "").trim().toUpperCase();
    var trimmed = String(nickname || "").trim();
    if (!roomCode) {
      showToast("请输入房间码。");
      return;
    }
    if (!trimmed) {
      showToast("先填一个昵称。");
      return;
    }

    if (isSupabaseMode()) {
      try {
        var playerKey = makePlayerKey();
        var bundle = await supabaseRpc("tycoon_join_room", {
          p_room_code: roomCode,
          p_nickname: trimmed,
          p_player_key: playerKey
        });
        var onlineRoom = normalizeOnlineTycoonRoom(bundle);
        if (!onlineRoom || !bundle.currentPlayerId) throw new Error("Tycoon player was not created.");
        cacheTycoonRoom(onlineRoom);
        saveTycoonIdentity(onlineRoom, {
          playerId: bundle.currentPlayerId,
          playerKey: playerKey
        });
        setRoute("tycoon/room/" + onlineRoom.code);
      } catch (error) {
        showToast(onlineTycoonErrorMessage());
      }
      return;
    }

    var state = loadTycoonState();
    var room = getTycoonRoomByCode(state, roomCode);
    if (!room) {
      showToast("没有找到这个 Friends Tycoon 房间。");
      return;
    }
    joinTycoonRoomLocal(state, room, trimmed);
  }

  function joinTycoonRoomLocal(state, room, nickname) {
    room = normalizeTycoonRoom(room);
    if (room.status !== "lobby") {
      showToast("游戏已经开始，暂时不能中途加入。");
      return;
    }

    if (getTycoonPresentPlayers(room).length >= TYCOON_MAX_PLAYERS) {
      showToast("这局已经满 6 人了。");
      return;
    }

    var player = {
      id: makeId("tycoon-player"),
      nickname: nickname,
      cash: TYCOON_START_CASH,
      position: 0,
      status: "waiting",
      createdAt: new Date().toISOString()
    };
    room.players[player.id] = player;
    appendTycoonLog(room, player.nickname + " 加入了游戏。", "join");
    saveTycoonState(state);
    saveTycoonIdentity(room, player.id);
    setRoute("tycoon/room/" + room.code);
    render();
  }

  function getLocalTycoonRoomAndPlayer() {
    var state = loadTycoonState();
    var room = getTycoonRoomByCode(state, getTycoonRoomCode());
    if (!room) return null;
    var player = getTycoonCurrentPlayer(room);
    return {
      state: state,
      room: normalizeTycoonRoom(room),
      player: player
    };
  }

  function saveAndRenderTycoon(state) {
    saveTycoonState(state);
    render({ skipOnlineSync: true });
  }

  async function runTycoonRpc(name, payload) {
    var identity = getTycoonIdentity(getTycoonRoomCode());
    var basePayload = {
      p_room_code: getTycoonRoomCode(),
      p_player_id: getTycoonIdentityPlayerId(identity),
      p_player_key: identity && identity.playerKey ? identity.playerKey : null
    };
    var bundle = await supabaseRpc(name, Object.assign(basePayload, payload || {}));
    var onlineRoom = normalizeOnlineTycoonRoom(bundle);
    if (onlineRoom) cacheTycoonRoom(onlineRoom);
    render({ skipOnlineSync: true });
  }

  async function startTycoonGame() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_start_game");
      } catch (error) {
        showToast(onlineTycoonErrorMessage());
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle || !isTycoonHost(bundle.room, bundle.player)) return;
    var room = bundle.room;
    var readyPlayers = getTycoonPresentPlayers(room);
    if (readyPlayers.length < TYCOON_MIN_PLAYERS) {
      showToast("至少 2 人才能开始。");
      return;
    }

    readyPlayers.forEach(function (player) {
      player.status = "active";
      player.cash = TYCOON_START_CASH;
      player.position = 0;
    });
    room.status = "active";
    room.currentTurn = 1;
    room.currentPlayerId = readyPlayers[0].id;
    room.turnPhase = "roll";
    room.lastDice = null;
    room.finalResults = null;
    room.properties = makeTycoonProperties();
    room.messages = [];
    appendTycoonLog(room, "游戏开始。", "start");
    saveAndRenderTycoon(bundle.state);
  }

  async function rollTycoonDice() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_roll_dice");
      } catch (error) {
        showToast("掷骰失败，请稍后再试。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle) return;
    var room = bundle.room;
    var player = bundle.player;
    if (!player || room.status !== "active" || room.currentPlayerId !== player.id || room.turnPhase !== "roll" || player.status !== "active") return;

    var dice = Math.floor(Math.random() * 6) + 1;
    var oldPosition = player.position;
    room.lastDice = dice;
    appendTycoonLog(room, player.nickname + " 掷出 " + dice + "。", "dice");
    applyTycoonLanding(room, player, oldPosition, dice);
    if (player.status === "bankrupt") {
      advanceTycoonTurn(room, player.id);
    } else {
      room.turnPhase = "action";
      checkTycoonFinish(room);
    }
    saveAndRenderTycoon(bundle.state);
  }

  async function buyTycoonProperty() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_buy_property");
      } catch (error) {
        showToast("买地失败，请检查现金或地块状态。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle) return;
    var room = bundle.room;
    var player = bundle.player;
    var cell = player && getTycoonCell(player.position);
    var property = player && getTycoonProperty(room, player.position);
    if (!player || room.currentPlayerId !== player.id || room.turnPhase !== "action" || !property || property.ownerId || cell.type !== "property") return;
    if (player.cash < cell.price) {
      showToast("现金不够，买不了这块地。");
      return;
    }

    player.cash -= cell.price;
    property.ownerId = player.id;
    property.level = 1;
    appendTycoonLog(room, player.nickname + " 买下 " + cell.name + "，等级 1。", "property");
    saveAndRenderTycoon(bundle.state);
  }

  async function upgradeTycoonProperty() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_upgrade_property");
      } catch (error) {
        showToast("升级失败，请检查现金或等级。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle) return;
    var room = bundle.room;
    var player = bundle.player;
    var cell = player && getTycoonCell(player.position);
    var property = player && getTycoonProperty(room, player.position);
    if (!player || room.currentPlayerId !== player.id || room.turnPhase !== "action" || !property || property.ownerId !== player.id || property.level >= TYCOON_MAX_LEVEL) return;
    if (player.cash < cell.upgradeCost) {
      showToast("现金不够，暂时不能升级。");
      return;
    }

    player.cash -= cell.upgradeCost;
    property.level += 1;
    appendTycoonLog(room, player.nickname + " 将 " + cell.name + " 升到 " + property.level + " 级。", "property");
    saveAndRenderTycoon(bundle.state);
  }

  async function endTycoonTurn() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_end_turn");
      } catch (error) {
        showToast("结束回合失败，请稍后再试。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle) return;
    var room = bundle.room;
    var player = bundle.player;
    if (!player || room.status !== "active" || room.currentPlayerId !== player.id || room.turnPhase !== "action") return;
    advanceTycoonTurn(room, player.id);
    saveAndRenderTycoon(bundle.state);
  }

  async function exitTycoonGame() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_exit_game");
      } catch (error) {
        showToast("退出失败，请稍后再试。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle || !bundle.player || bundle.player.status === "bankrupt") return;
    var room = bundle.room;
    var player = bundle.player;
    if (room.status !== "lobby" && room.status !== "active") {
      showToast("这局已经结束，不能再退出。");
      return;
    }
    var wasCurrent = room.currentPlayerId === player.id;
    bankruptTycoonPlayer(room, player, "玩家主动退出。");

    if (room.status === "active" && wasCurrent) {
      advanceTycoonTurn(room, player.id);
    } else {
      checkTycoonFinish(room);
    }
    saveAndRenderTycoon(bundle.state);
  }

  async function restartTycoonRoom() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_restart_room");
      } catch (error) {
        showToast("重开失败，只有房主可以重开。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle || !isTycoonHost(bundle.room, bundle.player)) return;
    var room = bundle.room;
    getTycoonPresentPlayers(room).forEach(function (player) {
      player.cash = TYCOON_START_CASH;
      player.position = 0;
      player.status = "waiting";
    });
    room.status = "lobby";
    room.currentTurn = 1;
    room.currentPlayerId = null;
    room.turnPhase = "roll";
    room.lastDice = null;
    room.finalResults = null;
    room.properties = makeTycoonProperties();
    room.logs = [];
    room.messages = [];
    appendTycoonLog(room, "房主重开了游戏。", "host");
    saveAndRenderTycoon(bundle.state);
  }

  async function closeTycoonRoom() {
    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_close_room");
        setRoute("tycoon");
      } catch (error) {
        showToast("解散失败，只有房主可以解散。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle || !isTycoonHost(bundle.room, bundle.player)) return;
    var room = bundle.room;
    room.status = "closed";
    room.turnPhase = "closed";
    appendTycoonLog(room, "房主解散了房间。", "host");
    saveTycoonState(bundle.state);
    setRoute("tycoon");
  }

  async function sendTycoonMessage(content) {
    var trimmed = String(content || "").trim();
    if (!trimmed) return;

    if (isSupabaseMode()) {
      try {
        await runTycoonRpc("tycoon_send_message", {
          p_content: trimmed
        });
      } catch (error) {
        showToast("聊天发送失败，请稍后再试。");
      }
      return;
    }

    var bundle = getLocalTycoonRoomAndPlayer();
    if (!bundle || !bundle.player || bundle.player.status === "bankrupt") return;
    appendTycoonMessage(bundle.room, bundle.player, trimmed);
    saveAndRenderTycoon(bundle.state);
  }

  function copyTycoonLink() {
    var state = loadTycoonState();
    var room = getTycoonRoomByCode(state, getTycoonRoomCode());
    if (!room) return;
    var link = tycoonRoomLink(room);

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(link).then(function () {
        showToast("Friends Tycoon 邀请链接已复制");
      }).catch(function () {
        showToast(link);
      });
      return;
    }

    showToast(link);
  }

  function clearCurrentTycoonPlayer() {
    var state = loadTycoonState();
    var room = getTycoonRoomByCode(state, getTycoonRoomCode());
    if (!room) return;

    var identities = loadTycoonIdentities();
    delete identities[room.id];
    delete identities[room.code];
    saveTycoonIdentities(identities);
    render();
  }

  function switchTycoonPlayer(playerId) {
    var state = loadTycoonState();
    var room = getTycoonRoomByCode(state, getTycoonRoomCode());
    if (!room || !room.players[playerId]) return;

    if (isSupabaseMode()) {
      showToast("线上模式不能切换到朋友身份。");
      return;
    }

    saveTycoonIdentity(room, playerId);
    render();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  document.addEventListener("click", function (event) {
    var target = event.target.closest("[data-action]");
    if (!target || target.tagName === "FORM") return;

    var action = target.getAttribute("data-action");
    if (action === "open-lobby") setRoute("home");
    if (action === "open-qa") setRoute("qa");
    if (action === "open-tycoon") setRoute("tycoon");
    if (action === "open-account") setRoute("account");
    if (action === "open-create-room") setRoute("qa/create");
    if (action === "set-question-mode") setQuestionMode(target.getAttribute("data-mode"));
    if (action === "go-home") setRoute("home");
    if (action === "open-room") setRoute("qa/room/" + target.getAttribute("data-code"));
    if (action === "open-qa-export") setRoute("qa/export/" + target.getAttribute("data-code"));
    if (action === "open-tycoon-room") setRoute("tycoon/room/" + target.getAttribute("data-code"));
    if (action === "prev-page") changePage(-1);
    if (action === "next-page") changePage(1);
    if (action === "submit-answers") submitAnswers();
    if (action === "confirm-submit") finishSubmitAnswers();
    if (action === "cancel-submit") closeSubmitConfirm();
    if (action === "copy-link") copyLink();
    if (action === "new-local-player") clearCurrentPlayer();
    if (action === "switch-player") switchPlayer(target.getAttribute("data-player-id"));
    if (action === "copy-tycoon-link") copyTycoonLink();
    if (action === "tycoon-start") startTycoonGame();
    if (action === "tycoon-roll") rollTycoonDice();
    if (action === "tycoon-buy") buyTycoonProperty();
    if (action === "tycoon-upgrade") upgradeTycoonProperty();
    if (action === "tycoon-end-turn") endTycoonTurn();
    if (action === "tycoon-exit") showTycoonConfirm("确认退出吗?", "退出后你的状态会变为破产，其他玩家可以继续正常进行。", "tycoon-confirm-exit", "确认退出");
    if (action === "tycoon-restart") showTycoonConfirm("确认重开吗?", "重开会清空当前地图、聊天和本局记录，未破产玩家回到等待开始。", "tycoon-confirm-restart", "确认重开");
    if (action === "tycoon-close") showTycoonConfirm("确认解散房间吗?", "解散后这局 Friends Tycoon 会结束，朋友们不能继续操作。", "tycoon-confirm-close", "确认解散");
    if (action === "tycoon-confirm-exit") {
      closeSubmitConfirm();
      exitTycoonGame();
    }
    if (action === "tycoon-confirm-restart") {
      closeSubmitConfirm();
      restartTycoonRoom();
    }
    if (action === "tycoon-confirm-close") {
      closeSubmitConfirm();
      closeTycoonRoom();
    }
    if (action === "new-local-tycoon-player") clearCurrentTycoonPlayer();
    if (action === "switch-tycoon-player") switchTycoonPlayer(target.getAttribute("data-player-id"));
    if (action === "account-register") registerAccountFromForm(target.closest("form"));
    if (action === "account-logout") logoutAccount();
    if (action === "account-bind-device") bindDeviceRecordsToAccount();
    if (action === "account-refresh-records") {
      accountRecordsCache = null;
      render();
    }
    if (action === "print-pdf") window.print();
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeSubmitConfirm();
  });

  document.addEventListener("submit", function (event) {
    var form = event.target;
    var action = form.getAttribute("data-action");
    if (!action) return;
    event.preventDefault();

    if (action === "join-code") {
      var formData = new FormData(form);
      var code = String(formData.get("roomCode") || "").trim().toUpperCase();
      if (code) setRoute("qa/room/" + code);
    }

    if (action === "join-room") {
      var roomId = form.getAttribute("data-room-id");
      var nickname = String(new FormData(form).get("nickname") || "");
      joinRoom(roomId, nickname);
    }

    if (action === "create-room") {
      submitCreateRoom();
    }

    if (action === "account-login") {
      var accountData = new FormData(form);
      loginAccount(
        String(accountData.get("email") || ""),
        String(accountData.get("password") || "")
      );
    }

    if (action === "tycoon-create-room") {
      var createData = new FormData(form);
      createTycoonRoom(
        String(createData.get("nickname") || ""),
        String(createData.get("victoryMode") || "survivor"),
        Number(createData.get("turnLimit") || 30)
      );
    }

    if (action === "tycoon-join-code") {
      var joinData = new FormData(form);
      joinTycoonRoomByCode(
        String(joinData.get("roomCode") || ""),
        String(joinData.get("nickname") || "")
      );
    }

    if (action === "tycoon-join-room") {
      joinTycoonRoomByCode(
        form.getAttribute("data-room-code"),
        String(new FormData(form).get("nickname") || "")
      );
    }

    if (action === "tycoon-chat") {
      sendTycoonMessage(String(new FormData(form).get("message") || ""));
    }
  });

  document.addEventListener("input", function (event) {
    if (event.target.matches("textarea[data-question]")) {
      updateAnswer(event.target.getAttribute("data-question"), event.target.value);
    }

    if (event.target.matches("[data-question-bank]")) {
      updateCreateQuestionDraft(event.target.value);
    }
  });

  document.addEventListener("change", function (event) {
    if (!event.target.matches("[data-question-file]")) return;
    loadQuestionFile(event.target.files && event.target.files[0]);
  });

  window.addEventListener("hashchange", render);

  if (!window.location.hash) {
    setRoute("home");
  } else {
    render();
  }
})();
