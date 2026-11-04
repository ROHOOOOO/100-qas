(function(root){
 'use strict';
 root.createWordsModule=function(api){
  const I=root.FriendsI18n,e=api.escape,u=I.user;
  const labels={waiting:'等待朋友',ready:'准备开始',writing:'正在联想',revealed:'等待下一轮',matched:'成功相遇',interrupted:'已中断 · 未相遇'};
  let generation=0,code='',bundle=null,poll,clock,busy=false,stageKey='',history=[],hasMore=false,historyBusy=false,offset=0,confirming=false;
  const button=(label,action,cls='secondary-button',extra='')=>'<button type="button" class="'+cls+'" data-words="'+action+'" '+extra+'>'+label+'</button>';
  const finished=()=>bundle&&['matched','interrupted'].includes(bundle.room.phase);
  const key=type=>'word-meet:'+type+':'+api.account().id+':'+code;
  const draftKey=()=>key('draft')+':'+bundle.room.round;
  const mine=()=>bundle?.players?.find(p=>p?.id===api.account()?.id);
  const seconds=(from,to)=>Math.max(0,Math.floor((Date.parse(to||new Date().toISOString())-Date.parse(from))/1000));
  const duration=n=>Math.floor(n/60)+':'+String(n%60).padStart(2,'0');
  function saved(k){try{return localStorage.getItem(k);}catch{return null;}}
  function save(k,value){try{if(value==null)localStorage.removeItem(k);else localStorage.setItem(k,value);}catch{/* The current input remains usable without browser storage. */}}
  function pending(){try{return JSON.parse(saved(key('pending'))||'null');}catch{return null;}}
  function errorText(err){const message=err?.message||'';return [[/Invalid word/,'请输入 2–6 个汉字或 2–15 个英文字母，不要混写或加入标点。'],[/Previous word/,'请换一个新词，不能重复上一轮的任意一个词。'],[/Already submitted/,'你已经提交，本轮的词已锁定。'],[/Round changed|Not writing phase|Not ready phase/,'轮次已更新，请查看当前进度后再操作。'],[/Game started/,'本局已经开始，暂不接受新成员。'],[/Host required/,'只有房主可以开始本局。'],[/Players not ready/,'至少需要两人，且所有成员都准备后才能开始。'],[/Room full/,'这个房间已经有六位玩家。'],[/Game ended/,'本局已经结束，可以查看已揭晓的记录。'],[/Membership/,'只有房间成员可以查看记录和操作。'],[/Room not found/,'没有找到这个房间，请检查房间码。'],[/Login required/,'登录已失效，请重新登录。'],[/Invalid title/,'请填写 1–60 个字的房间名称。']].find(([pattern])=>pattern.test(message))?.[1]||'暂时无法连接，请稍后重试。';}
  const knownError=err=>/Invalid|Previous word|Already submitted|Round changed|Not writing phase|Not ready phase|Room full|Game started|Host required|Players not ready|Game ended|Membership|Room not found|Login required/.test(err?.message||'');
  function stop(){generation++;clearTimeout(poll);clearInterval(clock);code='';bundle=null;history=[];busy=false;historyBusy=false;confirming=false;stageKey='';}
  function records(rows){if(rows==null)return '<p class="muted">同词相遇记录暂时无法读取。</p>';return rows.length?'<div class="account-record-list">'+rows.map(r=>'<article class="account-record-card"><div><strong>'+u(r.title)+'</strong><p>'+r.names.map(u).join(' / ')+'</p><p><span>'+labels[r.phase]+'</span> · <span>'+r.rounds+' 轮已揭晓</span></p>'+I.dateHtml(r.createdAt)+'</div><a class="small-button" href="#words/room/'+e(r.code)+'">查看房间</a></article>').join('')+'</div>':'<p class="muted">还没有相遇记录，邀请朋友们开始吧。</p>';}
  function rules(){return '<details class="words-rules"><summary>玩法与规则</summary><ol><li>第一轮自由选词；之后的新词需要与上轮所有词都有关，关联由你们自己判断。</li><li>每人每轮一个词，提交后锁定，全员提交后才揭晓；所有人同词才算成功。</li><li>中文 2–6 字，英文 2–15 个字母；不支持数字、标点或中英文混写。</li><li>英文忽略大小写，繁简中文视为相同；不能重复上轮的任意一个词。</li><li>每轮 60 秒只作提醒，超时仍可提交，不会自动公开草稿。</li><li>刷新或离开不会结束；任意成员可确认中断，未揭晓的词不公开。</li></ol></details>';}
  async function home(run){
   I.title('同词相遇 | Friends Games');api.shell('<main class="words-layout"><header class="words-heading"><p class="eyebrow">不同的词，一点点靠近</p><h1 translate="no">同词相遇</h1><p class="lead">从不同的词出发，直到你们想到同一个词。</p></header><div class="words-home-grid"><section class="panel words-create"><div class="words-example" aria-hidden="true"><span>大海</span><b>↔</b><span>天空</span><small>蓝色 · 广阔 → 自由</small></div><h2>邀请朋友一起玩</h2><form class="stack-form" data-words-form="create"><label for="words-title">房间名称</label><input id="words-title" name="title" required maxlength="60" value="'+e(I.text('一起寻找同一个词'))+'"><button class="primary-button" type="submit">创建相遇房间</button><p class="words-form-error" role="alert"></p></form></section><aside class="panel"><h2>加入朋友的房间</h2><form class="stack-form" data-words-form="join"><label for="words-code">房间码</label><input id="words-code" name="code" required maxlength="6" autocomplete="off" placeholder="输入 6 位房间码"><button class="secondary-button" type="submit">加入相遇房间</button></form><p class="field-hint">2–6 位真人 · 同时联想 · 每轮 60 秒提醒</p>'+rules()+'</aside></div><section class="panel"><h2>我的相遇记录</h2><div id="words-records">正在读取…</div></section></main>','words');
   try{const rows=await api.rpc('words_records',{});if(run===generation)document.getElementById('words-records').innerHTML=records(rows);}catch{if(run===generation)document.getElementById('words-records').innerHTML=records(null);}
  }
  function pair(t){const words=t.words||[{name:t.name1,word:t.word1},{name:t.name2,word:t.word2}];return '<div class="words-pair">'+words.map(w=>'<article><small>'+u(w.name)+'</small><strong>'+u(w.word)+'</strong></article>').join('')+'</div>';}
  function paintHistory(){const node=document.getElementById('words-history');if(!node)return;node.innerHTML=history.length?history.map(t=>'<article class="words-history-round"><header><strong>第 '+t.round+' 轮</strong><time>'+duration(seconds(t.startedAt,t.revealedAt))+'</time></header>'+pair(t)+'</article>').join(''):'<p class="muted">这里会记录所有成员已揭晓的每一轮。</p>';document.getElementById('words-older').hidden=!hasMore;}
  async function loadHistory(older=false){if(!bundle?.isMember||historyBusy)return;historyBusy=true;const run=generation,roomCode=code;
   try{const rows=await api.rpc('words_history',{p_room_code:roomCode,...(older&&history.length?{p_before_round:history.at(-1).round}:{})});if(run!==generation)return;const merged=new Map(history.map(t=>[t.round,t]));rows.forEach(t=>merged.set(t.round,t));history=[...merged.values()].sort((a,b)=>b.round-a.round);if(older||history.length===rows.length)hasMore=rows.length===25;paintHistory();}catch(err){if(run===generation)api.toast(errorText(err));}finally{if(run===generation)historyBusy=false;}
  }
  function timer(){if(!bundle?.isMember)return;const n=document.getElementById('words-clock'),r=bundle.room;if(n){if(bundle.current){const elapsed=Math.max(0,Math.floor((Date.now()+offset-Date.parse(bundle.current.startedAt))/1000));n.textContent=elapsed<60?'剩余 '+(60-elapsed)+' 秒':'时间到，仍可继续提交';n.classList.toggle('is-late',elapsed>=60);}else n.textContent='';}const total=document.getElementById('words-total');if(total)total.textContent=r.startedAt?'本局用时 '+duration(Math.max(0,Math.floor(((r.endedAt?Date.parse(r.endedAt):Date.now()+offset)-Date.parse(r.startedAt))/1000))):'';}
  function controls(){const node=document.getElementById('words-retry');if(!node)return;const receipt=pending();node.innerHTML=busy?'<p class="field-hint" role="status">正在保存操作…</p>':receipt?'<p class="preview-notice">上次操作尚未确认，内容已保留。 '+button('重试上次操作','retry','small-button')+'</p>':'';const submit=document.querySelector('[data-words-form="word"] button');if(submit)submit.disabled=busy||!!receipt;document.querySelectorAll('[data-words="ready"],[data-words="interrupt"],[data-words="confirm-interrupt"]').forEach(b=>b.disabled=busy||!!receipt);const start=document.querySelector('[data-words="start"]');if(start)start.disabled=busy||!!receipt||bundle.players.length<2||!bundle.players.every(p=>p.ready);}
  function paint(){const r=bundle.room;
   if(!bundle.isMember){api.shell('<main class="narrow-layout panel"><p class="eyebrow" translate="no">同词相遇</p><h1>'+u(r.title)+'</h1><p>加入后，你们将从不同的词出发，一起寻找相同的联想。</p>'+(r.joinable?button('加入这个房间','join','primary-button'):'<p>这个房间已满、已开始或已结束，无法加入。</p>')+'<p><a href="#words">返回同词相遇</a></p><p id="words-public-status" role="status"></p><div id="words-retry"></div></main>','words');controls();return;}
   if(!document.getElementById('words-stage')){api.shell('<main class="words-layout"><header class="words-room-heading"><div><a href="#words" class="spin-back">← 同词相遇</a><h1>'+u(r.title)+'</h1><p>房间码 '+e(r.code)+'</p></div><div class="words-tools">'+button('复制邀请链接','copy')+button('结束本局','interrupt','ghost-button')+'</div></header><p id="words-sync" role="status" class="field-hint"></p><div class="words-room-grid"><section class="panel words-stage-panel"><p id="words-member-count" class="field-hint"></p><div id="words-players" class="words-players"></div><p id="words-progress" class="field-hint" role="status"></p><div class="words-round-heading"><strong id="words-round"></strong><span id="words-clock" role="timer"></span></div><div id="words-stage"></div><p id="words-error" class="words-form-error" role="alert"></p><div id="words-retry"></div><p id="words-total" class="muted"></p>'+rules()+'</section><aside class="panel words-history-panel"><h2>相遇过程</h2><p class="field-hint">只记录全员提交后揭晓的词。</p><div id="words-history"></div>'+button('更早的轮次','older','ghost-button','id="words-older" hidden')+'</aside></div><div id="words-confirm"></div></main>','words');stageKey='';paintHistory();}
   if(finished()){confirming=false;document.getElementById('words-confirm').innerHTML='';}
   I.title(r.title+' | 同词相遇',true);document.querySelector('[data-words="interrupt"]').hidden=finished();
   document.getElementById('words-member-count').textContent='房间人数：'+bundle.players.length+' / 6';
   document.getElementById('words-players').innerHTML=bundle.players.map((p,i)=>'<div><span class="words-avatar" aria-hidden="true">'+(i+1)+'</span><strong>'+u(p.name)+(p.id===r.hostId?' <span class="words-host">房主</span>':'')+'</strong><small>'+(r.phase==='writing'?(p.submitted?'已提交':'正在联想'):finished()?'本局结束':p.ready?'已准备':'尚未准备')+'</small></div>').join('');
   document.getElementById('words-progress').textContent=r.phase==='writing'?'已提交 '+bundle.players.filter(p=>p.submitted).length+' / '+bundle.players.length+' 人':!finished()?'已准备 '+bundle.players.filter(p=>p.ready).length+' / '+bundle.players.length+' 人':'';
   document.getElementById('words-round').textContent=r.round?'第 '+r.round+' 轮':'准备相遇';
   const nextKey=[r.phase,r.round,!!bundle.current?.ownWord].join(':');
   if(nextKey!==stageKey){let html='';
    if(['waiting','ready'].includes(r.phase))html='<div class="words-waiting"><span aria-hidden="true">↔</span><h2>准备好，遇见同一个词</h2><p>第一轮自由选词，不用提前商量。</p>'+'<p>邀请 2–6 人，全员准备后由房主开始；开局后不再加入新成员。</p>'+ '</div>';
    if(r.phase==='writing')html=(bundle.previous?'<div class="words-previous"><p class="field-hint">想一个与上轮所有词都有关的新词</p>'+pair(bundle.previous)+'</div>':'<h2>想到什么，就从什么开始</h2>')+(bundle.current.ownWord?'<div class="words-locked"><p>你的词已锁定，等待其他成员提交。</p><strong>'+u(bundle.current.ownWord)+'</strong><p class="muted">全员提交前，其他成员看不到你的词。</p></div>':'<form class="stack-form words-word-form" data-words-form="word"><label for="words-word">你的新词</label><input id="words-word" name="word" type="text" inputmode="text" maxlength="64" required autocomplete="off" spellcheck="false" autocapitalize="off" aria-describedby="words-word-hint" placeholder="写下此刻的联想" value="'+e(saved(draftKey())||'')+'"><p id="words-word-hint" class="field-hint">中文 2–6 字 / 英文 2–15 个字母</p><button class="primary-button" type="submit">锁定并提交</button></form>');
    if(r.phase==='revealed')html='<h2>这一次，还差一点默契</h2>'+pair(bundle.previous)+'<p class="muted">下一轮，从这些词继续靠近。</p>';
    if(r.phase==='matched')html='<div class="words-success"><span aria-hidden="true">✦</span><h2>你们想到一起了！</h2>'+pair(bundle.previous)+'<p>相遇不止一个答案，谢谢你陪我联想。</p><a class="primary-button" href="#words">再建一局</a></div>';
    if(r.phase==='interrupted')html='<div class="words-waiting"><h2>本局已中断</h2><p>已揭晓的过程会保留，尚未揭晓的词不会公开。</p><a class="primary-button" href="#words">再建一局</a></div>';
    if(['waiting','ready','revealed'].includes(r.phase))html+='<div id="words-ready-control"></div>';
    document.getElementById('words-stage').innerHTML=html;stageKey=nextKey;
    if(r.phase!=='writing'||bundle.current?.ownWord)save(draftKey(),null);
   }
   const ready=document.getElementById('words-ready-control');if(ready){
    ready.innerHTML=button(mine().ready?'取消准备':r.round?'准备下一轮':'准备开始','ready',mine().ready?'secondary-button':'primary-button');
    if(!r.startedAt)ready.innerHTML+=(r.hostId===api.account().id?button('开始联想','start','primary-button'):'')+'<p class="field-hint">全员准备后，等待房主开始。</p>';
    else if(mine().ready)ready.innerHTML+='<p class="field-hint">等待其他成员准备，全员准备后进入下一轮。</p>';
   }
   if(bundle.previous&&!history.some(t=>t.round===bundle.previous.round)){history.unshift(bundle.previous);history.sort((a,b)=>b.round-a.round);paintHistory();}
   timer();controls();
  }
  async function sync(run){const next=await api.rpc('words_get_room',{p_room_code:code});if(run!==generation)return;
   if(bundle?.isMember&&next.isMember&&next.room.revision<bundle.room.revision)return;
   const changed=!bundle||bundle.isMember!==next.isMember||JSON.stringify(bundle.players)!==JSON.stringify(next.players)||bundle.room.revision!==next.room.revision;
   bundle=next;if(next.serverNow)offset=Date.parse(next.serverNow)-Date.now();if(changed)paint();else timer();
  }
  async function action(kind,data={},receipt=null){if(busy||!bundle)return;const run=generation,storageKey=key('pending');if(!receipt&&pending()){controls();return;}
   const request=receipt||{p_room_code:code,p_action:kind,p_round:bundle.room.round||0,p_request_id:crypto.randomUUID(),p_data:data};save(storageKey,JSON.stringify(request));busy=true;controls();
   try{const next=await api.rpc('words_action',request);save(storageKey,null);if(run!==generation)return;const wasMember=bundle.isMember;if(!wasMember||next.room.revision>=bundle.room.revision)bundle=next;if(next.serverNow)offset=Date.parse(next.serverNow)-Date.now();busy=false;confirming=false;paint();document.getElementById('words-confirm').innerHTML='';document.getElementById('words-error').textContent='';if(!wasMember)await loadHistory();}
   catch(err){if(knownError(err))save(storageKey,null);if(run!==generation)return;const node=document.getElementById('words-error')||document.getElementById('words-public-status');if(node)node.textContent=errorText(err);if(knownError(err))await sync(run).catch(()=>{});}
   finally{if(run===generation){busy=false;controls();}}
  }
  async function render(view,id){stop();const run=generation;if(view!=='room'){await home(run);return;}code=String(id||'').trim().toUpperCase();api.shell('<main class="narrow-layout panel"><p>正在打开相遇房间…</p></main>','words');
   try{await sync(run);if(run!==generation)return;await loadHistory();const tick=async()=>{if(run!==generation)return;try{if(!document.hidden&&!busy){await sync(run);if(run===generation){const n=document.getElementById('words-sync');if(n)n.textContent='';}}}catch{if(run===generation){const n=document.getElementById('words-sync');if(n)n.textContent='连接暂时中断，正在重试；输入内容会保留。';}}if(run===generation)poll=setTimeout(tick,1500);};if(run===generation){poll=setTimeout(tick,1500);clock=setInterval(timer,1000);}}
   catch(err){if(run===generation)api.shell('<main class="narrow-layout panel"><h1>暂时无法打开房间</h1><p>'+e(errorText(err))+'</p>'+button('重新打开','reload')+'<p><a href="#words">返回同词相遇</a></p></main>','words');}
  }
  document.addEventListener('input',event=>{if(event.target.id==='words-word'&&bundle?.current&&!bundle.current.ownWord)save(draftKey(),event.target.value);});
  document.addEventListener('submit',async event=>{
   const form=event.target,kind=form.dataset.wordsForm;if(!kind)return;event.preventDefault();const values=new FormData(form);
   if(kind==='word'){try{root.WordMeet.normalize(values.get('word'));await action('submit',{word:values.get('word')});}catch(err){document.getElementById('words-error').textContent=errorText(err);}return;}
   if(kind==='join'){api.route('words/room/'+String(values.get('code')).trim().toUpperCase());return;}
   if(kind==='create'){const submit=form.querySelector('[type="submit"]');if(submit.disabled)return;submit.disabled=true;const run=generation;
    // Retain the same receipt after an uncertain create response.
    const request=form._request||(form._request={p_title:values.get('title'),p_request_id:crypto.randomUUID()});
    try{const next=await api.rpc('words_create_room',request);if(run===generation)api.route('words/room/'+next.room.code);}catch(err){if(knownError(err))form._request=null;if(run===generation)form.querySelector('.words-form-error').textContent=errorText(err);}finally{if(submit.isConnected)submit.disabled=false;}
   }
  });
  document.addEventListener('click',async event=>{
   const node=event.target.closest('[data-words]');if(!node||node.disabled)return;const kind=node.dataset.words;
   if(kind==='reload'){await render('room',code);return;}
   if(kind==='copy'){try{await navigator.clipboard.writeText(location.href);api.toast('邀请链接已复制。');}catch{api.toast('请复制地址栏中的房间链接。');}return;}
   if(kind==='older'){await loadHistory(true);return;}
   if(kind==='retry'){await action('',{},pending());return;}
   if(kind==='join'){if(busy)return;node.disabled=true;await action('join');if(node.isConnected)node.disabled=false;return;}
   if(kind==='start'){await action('start');return;}
   if(kind==='ready'){await action('ready',{ready:!mine().ready});return;}
   if(kind==='interrupt'){confirming=true;document.getElementById('words-confirm').innerHTML='<div class="modal-backdrop"><section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="words-end-title"><h2 id="words-end-title">确认结束本局？</h2><p>本局将记为中断，保留已揭晓的过程，当前未揭晓的词不会公开。</p><div class="dialog-actions">'+button('继续联想','cancel-interrupt')+button('确认结束','confirm-interrupt','primary-button')+'</div></section></div>';return;}
   if(kind==='cancel-interrupt'){confirming=false;document.getElementById('words-confirm').innerHTML='';return;}
   if(kind==='confirm-interrupt'&&confirming)await action('interrupt');
  });
  return {render,stop,records};
 };
})(window);
