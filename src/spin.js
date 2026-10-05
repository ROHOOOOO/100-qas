(function () {
  window.createSpinModule = function (api) {
    var data = null, code = '', history = [], olderCursor = null, more = false;
    var epoch = 0, pollTimer, tickTimer, pending = false, offset = 0, wheelKey = '', historyKey = '';
    var e = api.escape, wheelState = null;
    var colors = ['#d9ebe3', '#f5d5c8', '#f4e6b8', '#dce8f1', '#e5dff0', '#f4dedf'];
    function mode(value) { return value === 'shared' ? '共同抽取' : '各自抽取'; }
    function time(value) { return new Date(value).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
    function serverTime() { return Date.now() + offset; }
    function selectedDraw() { return data && data.isMember ? (data.room.mode === 'shared' ? data.lastShared : data.lastPersonal) : null; }
    function spinning(draw) { return draw && Date.parse(draw.endsAt) > serverTime(); }
    function anySpinning() { return data && Date.parse(data.activeUntil || '') > serverTime(); }
    function pendingKey() { return 'whats-next-pending:' + (api.account() || {}).id + ':' + code; }
    function message(error) {
      var text = error && error.message || '';
      if (/Login required/i.test(text)) return '登录已失效，请重新登录。';
      if (/Only host/i.test(text)) return '只有房主可以修改转盘。';
      if (/Spin in progress/i.test(text)) return '还有转盘正在旋转，稍等一下再试。';
      if (/Room changed/i.test(text)) return '配置已在其他页面更新，请重新打开房间设置后再保存。';
      if (/Room not found/i.test(text)) return '没有找到这个房间，请检查房间码。';
      if (/membership/i.test(text)) return '请先加入这个房间。';
      if (/unique/i.test(text)) return '选项不能重复，避免影响抽取概率。';
      if (/2 to 50/i.test(text)) return '请填写 2 到 50 个选项，每行一个。';
      if (/1 to 60|title/i.test(text)) return '房间名称和每个选项需要 1 到 60 个字。';
      return '暂时未能完成，请检查网络后重试。';
    }
    function inputs(room) {
      return '<label for="spin-title">房间名称</label><input id="spin-title" name="title" maxlength="60" required placeholder="例如：今天吃什么" value="' + e(room.title || '') + '">' +
        '<label for="spin-options">转盘选项</label><textarea id="spin-options" name="options" rows="6" required placeholder="每行一个，例如：&#10;火锅&#10;烧烤&#10;日料">' + e((room.options || []).join('\n')) + '</textarea>' +
        '<p class="field-hint">2–50 个不重复选项，每项最多 60 个字。每项概率相同，允许重复抽中。</p>' +
        '<label for="spin-mode">抽取模式</label><select id="spin-mode" name="mode"><option value="shared"' + (room.mode !== 'individual' ? ' selected' : '') + '>共同抽取 · 大家共享一次结果</option><option value="individual"' + (room.mode === 'individual' ? ' selected' : '') + '>各自抽取 · 各转各的，历史共享</option></select>';
    }
    function records(rows) {
      if (!rows.length) return '<p class="muted">还没有转盘房间，去创建一个吧。</p>';
      return '<div class="account-record-list">' + rows.map(function (r) {
        return '<article class="account-record-card"><div><strong>' + e(r.title) + '</strong><p>' + e(r.roomCode) + ' · ' + mode(r.mode) + (r.isHost ? ' · 房主' : '') + '</p></div><button class="small-button" data-spin="open" data-code="' + e(r.roomCode) + '">进入</button></article>';
      }).join('') + '</div>';
    }
    function home() {
      document.title = 'What’s Next? | Friends Games';
      api.shell('<main class="spin-layout"><header class="spin-intro"><p class="eyebrow">A little chance. A good time.</p><h1>What’s Next?</h1><p class="lead">把纠结写下来，把下一步交给转盘。</p></header>' +
        '<div class="spin-setup"><section class="panel"><h2>创建一个转盘</h2><form class="stack-form" data-spin="create">' + inputs({}) + '<button class="primary-button" type="submit">创建转盘房间</button></form></section>' +
        '<aside class="spin-aside"><section class="panel"><h2>朋友已经开好房间？</h2><form class="stack-form" data-spin="join-code"><label for="spin-code">房间码</label><input id="spin-code" name="code" required maxlength="6" autocomplete="off" placeholder="输入 6 位房间码"><button class="secondary-button" type="submit">加入房间</button></form></section>' +
        '<section class="spin-note"><span class="spin-note-symbol" aria-hidden="true">↗</span><h2>下一次，也能接着用。</h2><p>房间保存在你的账号下。每一次抽取都有记录，房间里的朋友都可以查看。</p><button class="ghost-button" data-action="open-account">查看我的记录 →</button></section></aside></div></main>', 'spin');
    }
    function merge(rows) {
      var map = new Map(history.map(function (d) { return [d.id, d]; }));
      rows.forEach(function (d) { map.set(d.id, d); });
      history = Array.from(map.values()).sort(function (a,b) { return BigInt(a.id) > BigInt(b.id) ? -1 : 1; });
    }
    function accept(next, initial) {
      if (!initial && data && data.serverNow && next.serverNow && Date.parse(next.serverNow) < Date.parse(data.serverNow)) return;
      data = next;
      if (next.serverNow) offset = Date.parse(next.serverNow) - Date.now();
      if (next.isMember) {
        merge(next.history || []);
        if (initial) { var rows = next.history || []; olderCursor = rows.length ? rows[rows.length - 1].id : null; more = rows.length === 25; }
      }
    }
    function panelKey() { return 'whats-next-panels:' + (api.account() || {}).id + ':' + code; }
    function panelState() {
      try { var state = JSON.parse(localStorage.getItem(panelKey()) || '{}'); return state && typeof state === 'object' && !Array.isArray(state) ? state : {}; }
      catch (error) { return {}; }
    }
    function savePanel(panel, isOpen) {
      if (!panel.dataset.spinPanel || !panel.isConnected || panel.dataset.room !== code) return;
      var state = panelState(); state[panel.dataset.spinPanel] = isOpen;
      try { localStorage.setItem(panelKey(), JSON.stringify(state)); } catch (error) { /* Folding still works when storage is unavailable. */ }
    }
    function panelStart(name, title) {
      return '<details id="spin-' + name + '-panel" class="spin-fold" data-spin-panel="' + name + '" data-room="' + e(code) + '"' + (panelState()[name] === true ? ' open' : '') +
        '><summary><span class="spin-fold-label">' + title + '</span><span class="spin-fold-action" aria-hidden="true"><span class="when-closed">展开</span><span class="when-open">收起</span><span class="spin-fold-chevron">⌄</span></span></summary>';
    }
    function roomShell() {
      document.title = data.room.title + ' | What’s Next?';
      if (!data.isMember) {
        api.shell('<main class="narrow-layout"><section class="panel"><p class="eyebrow">What’s Next? · ' + e(code) + '</p><h1>' + e(data.room.title) + '</h1><p>加入后就能一起转盘，查看这个房间的抽取历史。</p><button class="primary-button" data-spin="join">加入这个房间</button></section></main>', 'spin'); return;
      }
      api.shell('<main class="spin-layout spin-room"><header class="spin-room-header"><div><a href="#spin" class="spin-back">← What’s Next?</a><h1 id="spin-room-title"></h1><p><span class="spin-mode-badge" id="spin-mode-label"></span> <span class="muted">房间码 ' + e(code) + '</span></p></div><button class="secondary-button" data-spin="copy">复制邀请链接</button></header>' +
        '<p id="spin-sync-status" class="field-hint" role="status"></p><div class="spin-room-grid"><section class="panel spin-stage"><p class="eyebrow">Let chance choose</p><div class="spin-wheel-wrap"><span class="spin-pointer" aria-hidden="true"></span><div id="spin-wheel"></div><span class="spin-wheel-center" aria-hidden="true">✦</span></div>' +
        '<div id="spin-result" class="spin-result" aria-live="polite"></div><button id="spin-draw-button" class="primary-button spin-draw-button" data-spin="draw">旋转转盘</button><p id="spin-explainer" class="field-hint"></p>' + panelStart('options', '所有选项 <span id="spin-option-count" class="muted"></span>') + '<ul id="spin-option-list" class="spin-options-list"></ul></details></section>' +
        '<aside class="spin-aside"><section class="panel spin-history-panel">' + panelStart('history', '抽取历史 <span class="muted">全员可见</span>') + '<p class="field-hint">记录每次选择，也记录一起犹豫的时刻。</p><div id="spin-history"></div><button id="spin-more" class="ghost-button" data-spin="more">加载更早的记录</button></details></section>' +
        '<section class="panel"><h2>房间成员</h2><p id="spin-members" class="muted"></p>' + (data.room.isHost ? '<details id="spin-settings"><summary>房间设置 · 仅房主可编辑</summary><form class="stack-form" data-spin="save" data-version="' + data.room.version + '"><fieldset id="spin-edit-fields">' + inputs(data.room) + '<button class="secondary-button" type="submit">保存设置</button></fieldset><p id="spin-edit-hint" class="field-hint"></p></form></details>' : '<p class="field-hint">选项和模式由房主修改。</p>') + '</section></aside></div></main>', 'spin');
      wheelKey = ''; historyKey = ''; paint();
    }
    function wheelMotion(draw, count) {
      // Cosmetic only: derive a stable landing point from this saved draw so all viewers agree.
      // The selected option still comes exclusively from the backend's random draw.
      var seed = String(draw.id) + ':' + draw.startedAt, hash = 2166136261;
      for (var i = 0; i < seed.length; i++) hash = Math.imul(hash ^ seed.charCodeAt(i), 16777619);
      var fraction = .2 + .6 * ((hash >>> 0) / 4294967296);
      return { angle: 360 - (draw.index + fraction) * (360 / count), turns: 4 + ((hash >>> 0) % 3) };
    }
    function wheel(options, draw) {
      var step = 360 / options.length, svg = '<svg viewBox="0 0 400 400" role="img" aria-label="随机转盘">';
      function point(angle,r) { var rad = (angle - 90)*Math.PI/180; return [200+r*Math.cos(rad),200+r*Math.sin(rad)]; }
      options.forEach(function (text,i) {
        var a = point(i*step,196), b = point((i+1)*step,196), center = point((i+.5)*step,128);
        svg += '<path d="M200 200 L' + a.join(' ') + ' A196 196 0 ' + (step > 180 ? 1 : 0) + ' 1 ' + b.join(' ') + ' Z" fill="' + colors[i%colors.length] + '" stroke="#fff" stroke-width="2"/>';
        var label = options.length > 14 ? String(i+1) : Array.from(text).slice(0,8).join('') + (Array.from(text).length > 8 ? '…' : '');
        svg += '<text x="' + center[0] + '" y="' + center[1] + '" text-anchor="middle" dominant-baseline="middle" font-size="' + (options.length > 10 ? 12 : 15) + '" font-weight="650" fill="#263c33" transform="rotate(' + ((i+.5)*step) + ' ' + center.join(' ') + ')"><title>' + e(text) + '</title>' + e(label) + '</text>';
      });
      document.getElementById('spin-wheel').innerHTML = '<div class="spin-disc">' + svg + '</svg></div>';
      if (draw && draw.options.join('\n') === options.join('\n')) {
        var node = document.querySelector('.spin-disc'), motion = wheelMotion(draw, options.length), from = 0;
        var optionsKey = JSON.stringify(options);
        if (wheelState && wheelState.optionsKey === optionsKey && wheelState.id !== draw.id) from = wheelState.angle;
        else {
          // Reconstruct the preceding angle when joining or reloading during a spin.
          var previous = history.find(function (entry) {
            return BigInt(entry.id) < BigInt(draw.id) && entry.mode === draw.mode &&
              (draw.mode === 'shared' || entry.accountId === draw.accountId);
          });
          if (previous && JSON.stringify(previous.options) === optionsKey) from = wheelMotion(previous, options.length).angle;
        }
        var target = from + motion.turns * 360 + (motion.angle - from + 360) % 360;
        var elapsed = Math.max(0,serverTime()-Date.parse(draw.startedAt)), duration = Date.parse(draw.endsAt)-Date.parse(draw.startedAt);
        node.style.transform = 'rotate(' + motion.angle + 'deg)';
        if (spinning(draw) && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
          var animation = node.animate([{ transform:'rotate('+from+'deg)' },{ transform:'rotate('+target+'deg)' }], { duration:duration, easing:'cubic-bezier(.12,.7,.15,1)' });
          animation.currentTime = Math.min(elapsed,duration);
        }
        wheelState = { optionsKey: optionsKey, id: draw.id, angle: motion.angle };
      } else wheelState = null;
    }
    function paint() {
      if (!data || !data.isMember || !document.getElementById('spin-result')) return;
      var draw = selectedDraw(), busy = spinning(draw), options = busy ? draw.options : data.room.options;
      var key = JSON.stringify([options,draw && draw.id]);
      if (wheelKey !== key) { wheel(options,draw); wheelKey = key; }
      document.getElementById('spin-room-title').textContent = data.room.title;
      document.getElementById('spin-mode-label').textContent = mode(data.room.mode);
      document.getElementById('spin-members').textContent = (data.members || []).join(' · ');
      document.getElementById('spin-result').innerHTML = busy ? '<span>正在转动，让惊喜再等一下…</span>' : draw ? '<span>' + (data.room.mode === 'shared' ? e(draw.actor) + ' 抽中了' : '你抽中了') + '</span><strong>' + e(draw.result) + '</strong>' : '<span>下一步会是什么？</span><strong>转一下，揭晓答案</strong>';
      var button = document.getElementById('spin-draw-button'); button.disabled = Boolean(busy || pending); button.textContent = busy ? '旋转中…' : pending ? '正在保存抽取…' : sessionStorage.getItem(pendingKey()) ? '重试这次抽取' : '旋转转盘';
      document.getElementById('spin-explainer').textContent = data.room.mode === 'shared' ? '一人发起，大家共享这一次结果。' : '各自旋转，所有结果都保存在共享历史中。';
      document.getElementById('spin-option-count').textContent = '（' + data.room.options.length + '）';
      var list = document.getElementById('spin-option-list'), listKey = JSON.stringify(data.room.options);
      if (list.dataset.key !== listKey) { list.innerHTML = data.room.options.map(function (text,i) { return '<li><span style="background:'+colors[i%colors.length]+'">'+(i+1)+'</span>'+e(text)+'</li>'; }).join(''); list.dataset.key = listKey; }
      var visible = history.filter(function (d) { return !spinning(d); }), nextKey = JSON.stringify(visible);
      if (historyKey !== nextKey) {
        var opened = Array.from(document.querySelectorAll('#spin-history details[open]')).map(function (n) { return n.dataset.id; });
        document.getElementById('spin-history').innerHTML = visible.length ? visible.map(function (d) {
          return '<article class="spin-history-item"><span class="spin-history-dot" aria-hidden="true"></span><div><strong>' + e(d.result) + '</strong><p>' + e(d.actor) + ' · ' + mode(d.mode) + '</p><time datetime="' + e(d.startedAt) + '">' + e(time(d.startedAt)) + '</time><details data-id="' + e(d.id) + '"' + (opened.includes(d.id) ? ' open' : '') + '><summary>当时的选项</summary><p>' + d.options.map(e).join(' · ') + '</p></details></div></article>';
        }).join('') : '<p class="spin-empty">还没有完成的抽取。<br>转动一次，留下第一个选择。</p>';
        historyKey = nextKey;
      }
      document.getElementById('spin-more').hidden = !more;
      var fields = document.getElementById('spin-edit-fields');
      if (fields) { fields.disabled = Boolean(anySpinning() || pending); document.getElementById('spin-edit-hint').textContent = anySpinning() ? '有人正在旋转，结束后即可修改。' : '修改配置会保留以前的抽取历史。'; }
    }
    async function sync(generation) {
      var next = await api.rpc('spin_get_room',{p_room_code:code});
      if (generation !== epoch) return;
      accept(next,false); paint();
    }
    function stop() { epoch++; clearTimeout(pollTimer); clearInterval(tickTimer); data = null; code = ''; pending = false; wheelState = null; }
    async function render(roomCode) {
      stop(); var generation = epoch;
      if (!roomCode) { home(); return; }
      code = roomCode.toUpperCase(); history=[]; more=false; olderCursor=null;
      api.shell('<main class="narrow-layout panel"><p role="status">正在打开转盘房间…</p></main>','spin');
      try {
        var next = await api.rpc('spin_get_room',{p_room_code:code});
        if (generation !== epoch) return;
        accept(next,true); roomShell();
        if (next.isMember) {
          tickTimer = setInterval(paint,200);
          var poll = async function () {
            if (generation !== epoch) return;
            if (!document.hidden && !pending) {
              try { await sync(generation); var status = document.getElementById('spin-sync-status'); if (status) status.textContent = ''; }
              catch (error) { var status = document.getElementById('spin-sync-status'); if (status) status.textContent = '同步暂时中断，正在重试…'; }
            }
            if (generation === epoch) pollTimer=setTimeout(poll,1500);
          };
          pollTimer=setTimeout(poll,1500);
        }
      } catch (error) {
        if (generation !== epoch) return;
        api.shell('<main class="narrow-layout panel"><h1>暂时无法打开房间</h1><p>'+e(message(error))+'</p><button class="secondary-button" data-spin="retry">重新打开</button> <a href="#spin">回到 What’s Next?</a></main>','spin');
      }
    }
    async function draw() {
      if (pending || !data || spinning(selectedDraw())) return;
      var generation=epoch, key=pendingKey(), request=sessionStorage.getItem(key) || crypto.randomUUID();
      sessionStorage.setItem(key,request); pending=true; paint();
      try {
        var response=await api.rpc('spin_draw',{p_room_code:code,p_request_id:request});
        sessionStorage.removeItem(key);
        if (generation!==epoch) return;
        data.serverNow=response.serverNow;
        offset=Date.parse(response.serverNow)-Date.now();
        if (response.draw.mode==='shared') data.lastShared=response.draw; else data.lastPersonal=response.draw;
        data.activeUntil=response.draw.endsAt; merge([response.draw]); paint();
        await sync(generation).catch(function () { if (generation===epoch) api.toast('抽取已保存，房间同步稍后自动重试。'); });
      } catch(error) {
        if (/Spin in progress/i.test(error.message)) { sessionStorage.removeItem(key); await sync(generation).catch(function(){}); }
        if (generation===epoch) api.toast(message(error));
      } finally { if (generation===epoch) { pending=false; paint(); } }
    }
    async function action(button) {
      var kind=button.dataset.spin;
      if (kind==='open') { api.route('spin/room/'+button.dataset.code); return; }
      if (!api.account()) { api.route('account'); return; }
      if (kind==='draw') { await draw(); return; }
      if (kind==='retry') { await render(code); return; }
      if (kind==='copy') {
        try { await navigator.clipboard.writeText(location.href.split('#')[0]+'#spin/room/'+code); api.toast('邀请链接已复制。'); }
        catch(error) { api.toast('请复制浏览器地址栏中的房间链接。'); } return;
      }
      var generation=epoch;
      try {
        button.disabled=true;
        if (kind==='join') { await api.rpc('spin_join_room',{p_room_code:code}); if(generation===epoch) await render(code); }
        if (kind==='more') {
          var rows=await api.rpc('spin_get_history',{p_room_code:code,p_before_id:olderCursor});
          if(generation!==epoch) return;
          merge(rows); if(rows.length) olderCursor=rows[rows.length-1].id; more=rows.length===25; paint();
        }
      } catch(error) { api.toast(message(error)); } finally { button.disabled=false; }
    }
    document.addEventListener('click',function(event){
      var target=event.target.closest('button[data-spin]'); if(target) action(target);
      var summary=event.target.closest('summary');
      // Native toggle events are queued; persist a user's intent before an immediate reload/navigation.
      if(summary && !event.defaultPrevented) savePanel(summary.parentElement, !summary.parentElement.open);
    });
    document.addEventListener('toggle',function(event){
      var panel = event.target;
      savePanel(panel, panel.open);
      if(event.target.id==='spin-settings' && event.target.open && data) {
        var form=event.target.querySelector('form');
        if (form.dataset.version === String(data.room.version)) return;
        form.dataset.version=data.room.version;
        form.elements.title.value=data.room.title; form.elements.options.value=data.room.options.join('\n'); form.elements.mode.value=data.room.mode;
      }
    },true);
    document.addEventListener('submit',async function(event){
      var form=event.target, kind=form.dataset.spin; if(!kind) return; event.preventDefault();
      if (!api.account()) { api.route('account'); return; }
      var generation=epoch, values=new FormData(form), button=form.querySelector('button[type="submit"]');
      if (button.disabled) return;
      button.disabled=true;
      try {
        if(kind==='join-code') {
          var roomCode=String(values.get('code')||'').trim().toUpperCase();
          await api.rpc('spin_join_room',{p_room_code:roomCode}); if(generation===epoch) api.route('spin/room/'+roomCode);
        } else {
          var options=String(values.get('options')||'').split(/\r?\n/).map(function(v){return v.trim();}).filter(Boolean);
          var args={p_title:values.get('title'),p_options:options,p_mode:values.get('mode')};
          if(kind==='save') { args.p_room_code=code; args.p_version=Number(form.dataset.version); }
          var next=await api.rpc(kind==='save'?'spin_update_room':'spin_create_room',args);
          if(generation!==epoch) return;
          if(kind==='save') { accept(next,false); roomShell(); api.toast('房间设置已保存。'); }
          else api.route('spin/room/'+next.room.code);
        }
      } catch(error) { if(generation===epoch) api.toast(message(error)); } finally { button.disabled=false; }
    });
    return { render:render,stop:stop,records:records };
  };
})();
