/* Offline preview only. Production accounts and permissions are enforced by SQL RPCs. */
(function () {
  var KEY = 'friends-games-local-accounts-v1';
  var queue = Promise.resolve();
  function read() { return JSON.parse(localStorage.getItem(KEY) || '{"accounts":[],"sessions":{},"rooms":{},"nextId":1}'); }
  function id() { return crypto.randomUUID(); }
  function now() { return new Date().toISOString(); }
  function expiry() { return new Date(Date.now() + 90 * 86400000).toISOString(); }
  function fail(message) { throw new Error(message); }
  async function hash(password, salt) {
    var key = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']);
    var bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: new TextEncoder().encode(salt), iterations: 120000, hash: 'SHA-256' }, key, 256);
    return Array.from(new Uint8Array(bits), function (v) { return v.toString(16).padStart(2, '0'); }).join('');
  }
  function session(db, token) {
    var s = db.sessions[token];
    if (!s || Date.parse(s.expiresAt) <= Date.now()) fail('Login required.');
    s.expiresAt = expiry();
    return db.accounts.find(function (a) { return a.id === s.accountId; });
  }
  function payload(db, token, account) { return { token: token, expiresAt: db.sessions[token].expiresAt, account: { id: account.id, username: account.username, displayName: account.displayName } }; }
  function options(value) {
    if (!Array.isArray(value) || value.length < 2 || value.length > 50) fail('Use 2 to 50 options.');
    var result = value.map(function (v) { return String(v || '').trim(); });
    if (result.some(function (v) { return !v || Array.from(v).length > 60; })) fail('Each option must contain 1 to 60 characters.');
    if (new Set(result).size !== result.length) fail('Options must be unique.');
    return result;
  }
  function config(p) {
    if (!String(p.p_title || '').trim() || Array.from(p.p_title.trim()).length > 60) fail('Room title is required (1 to 60 characters).');
    if (p.p_mode !== 'shared' && p.p_mode !== 'individual') fail('Invalid mode.');
    return { title: p.p_title.trim(), options: options(p.p_options), mode: p.p_mode };
  }
  function bundle(room, account, db) {
    var member = room.members.some(function (m) { return m.id === account.id; });
    if (!member) return { isMember: false, room: { code: room.code, title: room.title } };
    return { isMember: true, serverNow: now(), room: { code: room.code, title: room.title, options: room.options, mode: room.mode, version: room.version, isHost: room.owner === account.id },
      members: room.members.map(function (m) { return (db.accounts.find(function (a) { return a.id === m.id; }) || {}).displayName || '玩家'; }),
      activeUntil: room.history.length ? room.history[0].endsAt : null,
      lastShared: room.history.find(function (d) { return d.mode === 'shared'; }) || null,
      lastPersonal: room.history.find(function (d) { return d.mode === 'individual' && d.accountId === account.id; }) || null,
      history: room.history.slice(0, 25) };
  }
  function normalizedAnswer(value) { return String(value || '').replace(/^ +| +$/g, '').toLowerCase(); }
  function validateName(value) {
    if (!String(value || '').trim() || Array.from(value.trim()).length > 20) fail('Invalid display name.');
  }
  function validatePassword(value) {
    if (Array.from(String(value || '')).length < 4) fail('Password is too short.');
    if (new TextEncoder().encode(value).length > 72) fail('Password is too long.');
  }
  async function tokenHash(value) {
    var bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
    return Array.from(new Uint8Array(bytes), function (v) { return v.toString(16).padStart(2, '0'); }).join('');
  }
  async function recover(db, name, p) {
    var account = db.accounts.find(function (a) { return a.username.toLowerCase() === String(p.p_username || '').trim().toLowerCase(); });
    if (name === 'account_recovery_question') return { questionId: account && account.securityQuestion || 1 };
    if (name === 'account_verify_recovery') {
      var answer = normalizedAnswer(p.p_answer);
      if (!answer || Array.from(answer).length > 100) return { ok: false, error: 'Recovery verification failed.' };
      if (!account || !account.answerHash) {
        await hash(answer, 'missing-account'); return { ok: false, error: 'Recovery verification failed.' };
      }
      if (account.recoveryBlockedUntil > Date.now()) return { ok: false, error: 'Recovery temporarily blocked.', retryAfter: Math.ceil((account.recoveryBlockedUntil-Date.now())/1000) };
      if (account.answerHash !== await hash(answer, account.answerSalt)) {
        account.recoveryFailures = account.recoveryWindow > Date.now()-900000 ? account.recoveryFailures+1 : 1;
        if (account.recoveryFailures === 1) account.recoveryWindow = Date.now();
        account.recoveryBlockedUntil = account.recoveryFailures >= 5 ? Date.now()+900000 : 0;
        localStorage.setItem(KEY, JSON.stringify(db));
        return { ok: false, error: account.recoveryBlockedUntil ? 'Recovery temporarily blocked.' : 'Recovery verification failed.', retryAfter: account.recoveryBlockedUntil ? 900 : 0 };
      }
      var token = id()+id(), expiresAt = new Date(Date.now()+600000).toISOString();
      db.recoveries = db.recoveries || {};
      db.recoveries[account.id] = { tokenHash: await tokenHash(token), expiresAt: expiresAt };
      account.recoveryFailures=0; account.recoveryWindow=0; account.recoveryBlockedUntil=0;
      localStorage.setItem(KEY, JSON.stringify(db));
      return { ok: true, resetToken: token, expiresAt: expiresAt };
    }
    validatePassword(p.p_password);
    var digest = await tokenHash(String(p.p_reset_token || ''));
    var accountId = Object.keys(db.recoveries || {}).find(function (id) { return db.recoveries[id].tokenHash === digest && Date.parse(db.recoveries[id].expiresAt) > Date.now(); });
    if (!accountId) return { ok: false, error: 'Reset token expired or used.' };
    account = db.accounts.find(function (a) { return a.id === accountId; });
    account.salt = id(); account.passwordHash = await hash(p.p_password, account.salt);
    account.recoveryFailures=0; account.recoveryWindow=0; account.recoveryBlockedUntil=0;
    delete db.recoveries[accountId];
    Object.keys(db.sessions).forEach(function (token) { if (db.sessions[token].accountId === accountId) delete db.sessions[token]; });
    localStorage.setItem(KEY, JSON.stringify(db));
    return { ok: true };
  }
  async function run(name, p) {
    var db = read(), account, token;
    if (['account_recovery_question','account_verify_recovery','account_reset_password'].includes(name)) return recover(db, name, p);
    if (name === 'account_register' || name === 'account_login') {
      var username = String(p.p_username || '').trim();
      account = db.accounts.find(function (a) { return a.username.toLowerCase() === username.toLowerCase(); });
      if (name === 'account_register') {
        if (!/^[0-9A-Za-z_一-龥]{2,20}$/.test(username)) fail('Invalid username.');
        validatePassword(p.p_password);
        validateName(p.p_display_name);
        if (!Number.isInteger(p.p_security_question) || p.p_security_question < 1 || p.p_security_question > 5) fail('Invalid security question.');
        if (!normalizedAnswer(p.p_security_answer) || Array.from(normalizedAnswer(p.p_security_answer)).length > 100) fail('Invalid security answer.');
        if (account) fail('Username already exists.');
        var salt = id();
        account = { id: id(), username: username, displayName: p.p_display_name.trim(), salt: salt, passwordHash: await hash(p.p_password, salt),
          securityQuestion: p.p_security_question, answerSalt: id(), recoveryFailures: 0 };
        account.answerHash = await hash(normalizedAnswer(p.p_security_answer), account.answerSalt);
        db.accounts.push(account);
      } else if (!account || account.passwordHash !== await hash(String(p.p_password || ''), account.salt)) {
        fail('Invalid username or password.');
      }
      token = id(); db.sessions[token] = { accountId: account.id, expiresAt: expiry() };
      localStorage.setItem(KEY, JSON.stringify(db));
      return payload(db, token, account);
    }
    if (name === 'account_logout') {
      delete db.sessions[p.p_account_token]; localStorage.setItem(KEY, JSON.stringify(db)); return { ok: true };
    }
    account = session(db, p.p_account_token);
    var result;
    if (name.startsWith('board_')) result = window.BoardLocal.run(db, name, p, account);
    else if (name === 'account_refresh') result = payload(db, p.p_account_token, account);
    else if (name === 'account_update_profile') { validateName(p.p_display_name); account.displayName=p.p_display_name.trim(); result=payload(db,p.p_account_token,account); }
    else if (name === 'spin_records') result = Object.values(db.rooms).filter(function (r) { return r.members.some(function (m) { return m.id === account.id; }); }).map(function (r) { return { roomCode: r.code, title: r.title, mode: r.mode, isHost: r.owner === account.id }; });
    else if (name === 'spin_create_room') {
      var c = config(p), code;
      do { code = id().replace(/-/g, '').slice(0, 6).toUpperCase(); } while (db.rooms[code]);
      var created = Object.assign(c, { code: code, owner: account.id, version: 1, members: [{ id: account.id }], history: [] });
      db.rooms[code] = created; result = bundle(created, account, db);
    } else {
      var room = db.rooms[String(p.p_room_code || '').trim().toUpperCase()];
      if (!room) fail('Room not found.');
      var isMember = room.members.some(function (m) { return m.id === account.id; });
      if (name === 'spin_join_room') {
        if (!isMember) room.members.push({ id: account.id });
        result = bundle(room, account, db);
      } else if (name === 'spin_get_room') result = bundle(room, account, db);
      else {
        if (!isMember) fail('Room membership required.');
        if (name === 'spin_update_room') {
          if (room.owner !== account.id) fail('Only host can edit.');
          if (p.p_version !== room.version) fail('Room changed. Reload before saving.');
          if (room.history.some(function (d) { return Date.parse(d.endsAt) > Date.now(); })) fail('Spin in progress.');
          Object.assign(room, config(p)); room.version += 1; result = bundle(room, account, db);
        } else if (name === 'spin_get_history') {
          result = room.history.filter(function (d) { return p.p_before_id == null || Number(d.id) < Number(p.p_before_id); }).slice(0, 25);
        } else if (name === 'spin_draw') {
          var previous = room.history.find(function (d) { return d.requestId === p.p_request_id && d.accountId === account.id; });
          if (previous) result = { draw: previous, serverNow: now() };
          else {
            if (room.history.some(function (d) { return Date.parse(d.endsAt) > Date.now() && (room.mode === 'shared' || d.accountId === account.id); })) fail('Spin in progress.');
            var count = room.options.length, number = new Uint32Array(1), limit = Math.floor(4294967296 / count) * count;
            do { crypto.getRandomValues(number); } while (number[0] >= limit);
            var index = number[0] % count;
            var draw = { id: String(db.nextId++), requestId: p.p_request_id, accountId: account.id, actor: account.displayName, mode: room.mode,
              options: room.options.slice(), index: index, result: room.options[index], startedAt: now(), endsAt: new Date(Date.now() + 4000).toISOString() };
            room.history.unshift(draw); result = { draw: draw, serverNow: now() };
          }
        } else fail('Unknown local operation.');
      }
    }
    localStorage.setItem(KEY, JSON.stringify(db)); return result;
  }
  window.LocalGames = { displayNames: function () {
    var result={}; read().accounts.forEach(function(a){ result[a.id]=a.displayName || '玩家'; }); return result;
  }, rpc: function (name, payload) {
    var work = function () { return run(name, payload); };
    if (navigator.locks) return navigator.locks.request(KEY, work);
    var pending = queue.then(work); queue = pending.catch(function () {}); return pending;
  }};
})();
