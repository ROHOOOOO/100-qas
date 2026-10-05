(function(root){
 'use strict';root.createBoardChat=function(api){
  let generation=0,timer,code='',node=null,rows=[],hasOlder=true,busy=false,unread=0;const e=api.escape;
  const key=type=>'board-chat-'+type+':'+api.account().id+':'+code;
  const opened=()=>node?.open;const nearBottom=()=>{const list=node?.querySelector('.board-chat-list');return list&&list.scrollHeight-list.scrollTop-list.clientHeight<50;};
  function markRead(){unread=0;localStorage.setItem(key('read'),String(rows.at(-1)?.id||0));badge();}
  function badge(){if(node)node.querySelector('.board-chat-unread').textContent=unread?' · '+unread+' 条未读':'';}
  function paint(older=false){if(!node)return;const list=node.querySelector('.board-chat-list'),bottom=nearBottom(),height=list.scrollHeight,top=list.scrollTop;
   list.innerHTML=rows.length?rows.map(m=>'<article class="board-chat-message '+(m.accountId===api.account().id?'mine':'')+'"><header><strong>'+e(m.name)+'</strong><time>'+e(new Date(m.createdAt).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'}))+'</time></header><p>'+e(m.text)+'</p></article>').join(''):'<p class="muted">发一句话，和朋友聊聊吧。</p>';
   node.querySelector('[data-chat="older"]').hidden=!hasOlder||!rows.length;
   if(older)list.scrollTop=top+list.scrollHeight-height;else if(bottom&&opened()){list.scrollTop=list.scrollHeight;markRead();}
   badge();
  }
  function merge(incoming,initial=false,older=false){if(!initial&&!older&&!incoming.length)return;const ids=new Set(rows.map(m=>m.id));if(!initial&&!older)unread+=incoming.filter(m=>!ids.has(m.id)&&m.accountId!==api.account().id).length;rows=[...rows,...incoming.filter(m=>!ids.has(m.id))].sort((a,b)=>a.id-b.id);
   if(initial){const last=Number(localStorage.getItem(key('read'))||0);unread=rows.filter(m=>m.id>last&&m.accountId!==api.account().id).length;}paint(older);
  }
  function stop(){generation++;clearTimeout(timer);node=null;rows=[];code='';busy=false;}
  async function mount(target,roomCode){stop();code=roomCode;const run= generation;hasOlder=true;unread=0;
   const saved=localStorage.getItem(key('open')),open=saved==null?!matchMedia('(max-width: 800px)').matches:saved==='true';
   target.innerHTML='<details class="panel board-chat" '+(open?'open':'')+'><summary><strong>房间聊天<span class="board-chat-unread"></span></strong><span>展开 / 收起</span></summary><button type="button" class="small-button" data-chat="older">更早的消息</button><div class="board-chat-list" role="log" aria-label="房间消息" aria-live="polite"></div><button type="button" class="ghost-button" data-chat="latest">回到最新消息 ↓</button><form class="board-chat-form"><label for="board-chat-text">发送消息</label><textarea id="board-chat-text" rows="3" maxlength="1000" placeholder="中文、English、表情都可以"></textarea><div class="board-chat-footer"><small>Ctrl / ⌘ + Enter 发送</small><button type="submit" class="primary-button">发送</button></div><p class="field-hint board-chat-status" role="status"></p></form></details>';
   node=target.querySelector('details');const input=node.querySelector('textarea');input.value=sessionStorage.getItem(key('draft'))||'';
   const status=node.querySelector('.board-chat-status');if(sessionStorage.getItem(key('pending')))status.textContent='有一条消息待确认，点击发送可重试。';
   input.addEventListener('input',()=>sessionStorage.setItem(key('draft'),input.value));input.addEventListener('keydown',event=>{if(event.key==='Enter'&&(event.ctrlKey||event.metaKey)&&!event.isComposing){event.preventDefault();input.form.requestSubmit();}});
   node.querySelector('summary').addEventListener('click',()=>{if(run===generation&&node.isConnected)localStorage.setItem(key('open'),String(!node.open));});
   node.addEventListener('toggle',()=>{if(run!==generation||!node.isConnected)return;localStorage.setItem(key('open'),String(node.open));if(node.open&&nearBottom())markRead();});
   node.querySelector('.board-chat-list').addEventListener('scroll',()=>{if(opened()&&nearBottom())markRead();});
   node.querySelector('[data-chat="latest"]').addEventListener('click',()=>{node.querySelector('.board-chat-list').scrollTop=1e9;markRead();});
   node.querySelector('[data-chat="older"]').addEventListener('click',async event=>{const button=event.currentTarget;button.disabled=true;try{const older=await api.rpc('board_chat_list',{p_room_code:code,p_before_id:rows[0]?.id});if(run!==generation)return;hasOlder=older.length===50;merge(older,false,true);}catch{if(run===generation)status.textContent='历史消息暂时读取失败，请重试。';}finally{button.disabled=false;}});
   input.form.addEventListener('submit',async event=>{event.preventDefault();if(busy)return;const pendingKey=key('pending'),draftKey=key('draft');let receipt=JSON.parse(sessionStorage.getItem(pendingKey)||'null');const text=input.value.trim();if(!receipt&&!text)return;
    if(!receipt){receipt={p_room_code:code,p_text:text,p_request_id:crypto.randomUUID()};sessionStorage.setItem(pendingKey,JSON.stringify(receipt));}busy=true;const button=input.form.querySelector('[type="submit"]');button.disabled=true;status.textContent='正在发送…';
    try{const message=await api.rpc('board_chat_send',receipt);sessionStorage.removeItem(pendingKey);if(run!==generation)return;if(input.value.trim()===receipt.p_text){input.value='';sessionStorage.removeItem(draftKey);}status.textContent='';merge([message]);node.querySelector('.board-chat-list').scrollTop=1e9;markRead();}
    catch(error){if(run===generation)status.textContent=/Invalid message/.test(error.message)?'消息需为 1–1000 个字符。':'发送尚未确认，内容已保留；点击发送重试。';if(/Invalid message/.test(error.message))sessionStorage.removeItem(pendingKey);}
    finally{if(run===generation){busy=false;button.disabled=false;}}
   });
   async function tick(initial=false){if(run!==generation)return;try{if(!document.hidden){const batch=await api.rpc('board_chat_list',{p_room_code:roomCode,...(!initial&&rows.length?{p_after_id:rows.at(-1).id}:{})});if(run!==generation)return;if(initial)hasOlder=batch.length===50;merge(batch,initial);}}catch{if(run===generation&&!busy)status.textContent='消息同步暂时中断，正在重试…';}if(run===generation)timer=setTimeout(()=>tick(),2000);}
   await tick(true);
  }
  return {mount,stop};
 };
})(globalThis);
