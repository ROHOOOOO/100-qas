(function () {
  var STORAGE_KEY = "hundred-qas-state-v1";
  var IDENTITY_KEY = "hundred-qas-current-players-v1";
  var PAGE_SIZE = 5;
  var questions = window.QA_QUESTIONS || [];
  var app = document.getElementById("app");
  var saveTimer = null;
  var remoteAnswerTimers = {};

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

  function supabaseHeaders() {
    var config = getConfig();
    return {
      apikey: config.supabaseAnonKey,
      Authorization: "Bearer " + config.supabaseAnonKey,
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

  function getHashParts() {
    var raw = window.location.hash.replace(/^#\/?/, "");
    return raw ? raw.split("/") : ["home"];
  }

  function setRoute(path) {
    window.location.hash = path;
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

  function answeredCount(player) {
    return questions.reduce(function (count, _, index) {
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
    return base + "#room/" + room.code;
  }

  function normalizeOnlineRoom(bundle) {
    if (!bundle || !bundle.room) return null;

    var room = {
      id: bundle.room.id,
      code: bundle.room.code,
      title: bundle.room.title || "100 Q&As",
      createdAt: bundle.room.createdAt || bundle.room.created_at || new Date().toISOString(),
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

    if (identity && bundle.currentPlayerId) {
      saveIdentity(room, {
        playerId: bundle.currentPlayerId,
        playerKey: identity.playerKey,
        lastPage: identity.lastPage || 0
      });
    }

    return cacheRoom(room);
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
    var state = loadState();
    var parts = getHashParts();
    var pageName = parts[0] || "home";

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

    renderHome(state);
  }

  function renderHome(state) {
    var recentRooms = Object.keys(state.rooms).map(function (id) {
      return state.rooms[id];
    }).sort(function (a, b) {
      return b.createdAt.localeCompare(a.createdAt);
    });

    app.innerHTML = [
      '<main class="home-layout">',
      '  <section class="hero-copy">',
      '    <p class="eyebrow">Private friends game</p>',
      '    <h1>100 Q&As</h1>',
      '    <p class="lead">慢慢答完 100 个问题，提交之后再看朋友们的答案。</p>',
      '    <div class="home-actions">',
      '      <button class="primary-button" data-action="create-room">创建房间</button>',
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
    ].join("");
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
    app.innerHTML = [
      '<main class="narrow-layout">',
      '  <section class="panel">',
      '    <p class="eyebrow">Room not found</p>',
      '    <h1>没有找到这个房间</h1>',
      '    <p class="muted">房间码 ' + escapeHtml(code || "") + ' 在这个本地原型里不存在。</p>',
      '    <button class="primary-button" data-action="go-home">回到首页</button>',
      '  </section>',
      '</main>'
    ].join("");
  }

  function renderJoinRoom(room) {
    var existingPlayers = getRoomPlayers(room);

    app.innerHTML = [
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
    ].join("");
  }

  function renderAnswerPage(room, player) {
    var page = Math.min(Math.max(getCurrentPage(room, player), 0), Math.ceil(questions.length / PAGE_SIZE) - 1);
    var start = page * PAGE_SIZE;
    var pageQuestions = questions.slice(start, start + PAGE_SIZE);
    var done = answeredCount(player);
    var canSubmit = done === questions.length;

    app.innerHTML = [
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
      '    <span>第 ' + (page + 1) + ' / ' + Math.ceil(questions.length / PAGE_SIZE) + ' 页</span>',
      page === Math.ceil(questions.length / PAGE_SIZE) - 1
        ? '<button class="primary-button" data-action="submit-answers" ' + (canSubmit ? "" : "disabled") + '>提交答案</button>'
        : '<button class="primary-button" data-action="next-page">下一页</button>',
      '  </nav>',
      canSubmit ? "" : '<p class="submit-hint">还差 ' + (questions.length - done) + ' 题就可以提交。</p>',
      '</main>'
    ].join("");
  }

  function renderRoomHeader(room, player, done) {
    var progress = Math.round((done / questions.length) * 100);
    return [
      '<header class="room-header">',
      '  <div>',
      '    <p class="eyebrow">Room ' + escapeHtml(room.code) + '</p>',
      '    <h1>' + escapeHtml(player.nickname) + ' 的 100 Q&As</h1>',
      '  </div>',
      '  <div class="room-tools">',
      '    <button class="icon-button" title="复制邀请链接" aria-label="复制邀请链接" data-action="copy-link">↗</button>',
      '    <button class="ghost-button" data-action="new-local-player">换个昵称加入</button>',
      '  </div>',
      '  <div class="progress-wrap" aria-label="答题进度">',
      '    <div class="progress-track"><div class="progress-bar" style="width:' + progress + '%"></div></div>',
      '    <span>' + done + ' / ' + questions.length + ' 已回答</span>',
      '  </div>',
      '  <p class="save-status" id="save-status">草稿会自动保存</p>',
      '</header>'
    ].join("");
  }

  function renderRoomSummary(room, currentPlayer) {
    var players = getRoomPlayers(room);
    return [
      '<section class="room-summary" aria-label="房间进度">',
      '  <div class="summary-stats">',
      '    <div><span>加入</span><strong>' + players.length + ' 人</strong></div>',
      '    <div><span>提交</span><strong>' + submittedCount(room) + ' 人</strong></div>',
      '    <div><span>房间码</span><strong>' + escapeHtml(room.code) + '</strong></div>',
      '  </div>',
      renderLocalPlayers(room, currentPlayer),
      '</section>'
    ].join("");
  }

  function renderLocalPlayers(room, currentPlayer) {
    var players = getRoomPlayers(room);
    if (!players.length) return "";

    return [
      '<section class="local-players">',
      '  <h2>' + (isSupabaseMode() ? "参与者" : "本地玩家") + '</h2>',
      '  <div class="player-list">',
      players.map(function (player) {
        var isCurrent = currentPlayer && player.id === currentPlayer.id;
        var done = answeredCount(player);
        var status = player.submittedAt ? "已提交" : "已答 " + done + "/" + questions.length;
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
    var submittedPlayers = Object.keys(room.players)
      .map(function (id) { return room.players[id]; })
      .filter(function (item) { return Boolean(item.submittedAt); });

    app.innerHTML = [
      '<main class="results-layout">',
      '  <header class="room-header">',
      '    <div>',
      '      <p class="eyebrow">Room ' + escapeHtml(room.code) + '</p>',
      '      <h1>大家的答案</h1>',
      '      <p class="muted">按题目查看，当前展示已提交的 ' + submittedPlayers.length + ' 位朋友。你的答案已经锁定。</p>',
      '    </div>',
      '    <div class="room-tools">',
      '      <button class="icon-button" title="复制邀请链接" aria-label="复制邀请链接" data-action="copy-link">↗</button>',
      '      <button class="secondary-button" data-action="new-local-player">' + (isSupabaseMode() ? "换个昵称加入" : "再加一位本地玩家") + '</button>',
      '    </div>',
      '  </header>',
      renderRoomSummary(room, player),
      '  <section class="result-list">',
      questions.map(function (question, index) {
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
    ].join("");
  }

  async function createRoom() {
    if (isSupabaseMode()) {
      try {
        var bundle = await supabaseRpc("qa_create_room", {});
        var onlineRoom = normalizeOnlineRoom(bundle);
        if (!onlineRoom) throw new Error("Room was not created.");
        cacheRoom(onlineRoom);
        setRoute("room/" + onlineRoom.code);
      } catch (error) {
        showToast("线上房间创建失败，请检查 Supabase 配置。");
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
      players: {}
    };

    state.rooms[room.id] = room;
    saveState(state);
    setRoute("room/" + room.code);
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
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
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
    if (!identity || !identity.playerKey || getIdentityPlayerId(identity) !== player.id) return;

    var key = room.code + ":" + player.id + ":" + questionNumber;
    window.clearTimeout(remoteAnswerTimers[key]);
    remoteAnswerTimers[key] = window.setTimeout(function () {
      supabaseRpc("qa_save_answer", {
        p_room_code: room.code,
        p_player_id: player.id,
        p_player_key: identity.playerKey,
        p_question_index: Number(questionNumber),
        p_content: content
      }).catch(function () {
        showToast("这题暂时没有同步成功，稍后会在提交时再保存。");
      });
    }, 500);
  }

  function renderProgressOnly(roomId, playerId) {
    var state = loadState();
    var room = state.rooms[roomId];
    if (!room || !room.players[playerId]) return;
    var done = answeredCount(room.players[playerId]);
    var progress = Math.round((done / questions.length) * 100);
    var bar = document.querySelector(".progress-bar");
    var label = document.querySelector(".progress-wrap span");
    var hint = document.querySelector(".submit-hint");
    var submit = document.querySelector('[data-action="submit-answers"]');
    var playerStatus = document.querySelector('[data-player-status="' + playerId + '"]');
    if (bar) bar.style.width = progress + "%";
    if (label) label.textContent = done + " / " + questions.length + " 已回答";
    if (hint) hint.textContent = done === questions.length ? "" : "还差 " + (questions.length - done) + " 题就可以提交。";
    if (submit) submit.disabled = done !== questions.length;
    if (playerStatus) playerStatus.textContent = "已答 " + done + "/" + questions.length;
  }

  function changePage(delta) {
    var state = loadState();
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player) return;

    var maxPage = Math.ceil(questions.length / PAGE_SIZE) - 1;
    var page = Math.min(Math.max(getCurrentPage(room, player) + delta, 0), maxPage);
    setCurrentPage(room, player, page);
    saveState(state);
    render({ skipOnlineSync: true });
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function submitAnswers() {
    var state = loadState();
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player) return;

    if (answeredCount(player) !== questions.length) {
      renderProgressOnly(room.id, player.id);
      return;
    }

    showSubmitConfirm(player);
  }

  async function finishSubmitAnswers() {
    var state = loadState();
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
    if (!room) return;
    var player = getCurrentPlayer(room);
    if (!player || player.submittedAt) return;

    if (answeredCount(player) !== questions.length) {
      closeSubmitConfirm();
      renderProgressOnly(room.id, player.id);
      return;
    }

    if (isSupabaseMode()) {
      var identity = getIdentity(room);
      if (!identity || !identity.playerKey || getIdentityPlayerId(identity) !== player.id) {
        showToast("无法确认当前玩家身份，请重新加入房间。");
        return;
      }

      try {
        var bundle = await supabaseRpc("qa_submit_player", {
          p_room_code: room.code,
          p_player_id: player.id,
          p_player_key: identity.playerKey,
          p_answers: player.answers
        });
        var onlineRoom = normalizeOnlineRoom(bundle);
        if (onlineRoom) cacheRoom(onlineRoom);
        closeSubmitConfirm();
        render({ skipOnlineSync: true });
        window.scrollTo({ top: 0, behavior: "smooth" });
      } catch (error) {
        showToast("提交失败，请确认 100 题都已填写并稍后再试。");
      }
      return;
    }

    player.submittedAt = new Date().toISOString();
    saveState(state);
    closeSubmitConfirm();
    render();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function showSubmitConfirm(player) {
    closeSubmitConfirm();

    var overlay = document.createElement("div");
    overlay.className = "modal-backdrop";
    overlay.setAttribute("role", "presentation");
    overlay.innerHTML = [
      '<section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="submit-title">',
      '  <p class="eyebrow">Submit answers</p>',
      '  <h2 id="submit-title">确认提交吗?</h2>',
      '  <p>提交后，' + escapeHtml(player.nickname) + ' 的 100 个答案就会锁定，不能再修改。提交完成后可以查看同一房间里已提交朋友的答案。</p>',
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

  function closeSubmitConfirm() {
    var existing = document.querySelector(".modal-backdrop");
    if (existing) existing.remove();
  }

  function copyLink() {
    var state = loadState();
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
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
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
    if (!room) return;

    var identities = loadIdentities();
    delete identities[room.id];
    delete identities[room.code];
    saveIdentities(identities);
    render();
  }

  function switchPlayer(playerId) {
    var state = loadState();
    var parts = getHashParts();
    var room = getRoomByCode(state, parts[1]);
    if (!room || !room.players[playerId]) return;

    if (isSupabaseMode()) {
      showToast("线上模式不能切换到朋友身份。");
      return;
    }

    saveIdentity(room, playerId);
    render();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  document.addEventListener("click", function (event) {
    var target = event.target.closest("[data-action]");
    if (!target) return;

    var action = target.getAttribute("data-action");
    if (action === "create-room") createRoom();
    if (action === "go-home") setRoute("home");
    if (action === "open-room") setRoute("room/" + target.getAttribute("data-code"));
    if (action === "prev-page") changePage(-1);
    if (action === "next-page") changePage(1);
    if (action === "submit-answers") submitAnswers();
    if (action === "confirm-submit") finishSubmitAnswers();
    if (action === "cancel-submit") closeSubmitConfirm();
    if (action === "copy-link") copyLink();
    if (action === "new-local-player") clearCurrentPlayer();
    if (action === "switch-player") switchPlayer(target.getAttribute("data-player-id"));
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
      if (code) setRoute("room/" + code);
    }

    if (action === "join-room") {
      var roomId = form.getAttribute("data-room-id");
      var nickname = String(new FormData(form).get("nickname") || "");
      joinRoom(roomId, nickname);
    }
  });

  document.addEventListener("input", function (event) {
    if (!event.target.matches("textarea[data-question]")) return;
    updateAnswer(event.target.getAttribute("data-question"), event.target.value);
  });

  window.addEventListener("hashchange", render);

  if (!window.location.hash) {
    setRoute("home");
  } else {
    render();
  }
})();
