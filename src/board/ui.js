(function(root){
 'use strict';root.createBoardModule=function(api){
  const R=root.BoardRules,V=root.BoardView,e=api.escape,chat=root.createBoardChat(api);
  const titles={gomoku:'五子棋',xiangqi:'中国象棋',chess:'国际象棋',flight:'飞行棋',halma:'跳棋'},levels={easy:'简单',normal:'普通',hard:'困难'};
  const reasons={five:'五子连线',full:'棋盘已满',checkmate:'将死',stalemate:'困毙','stalemate-draw':'无合法走法且未被将军',insufficient:'子力不足',repetition:'重复局面','fifty-moves':'50 回合无吃子或兵移动','perpetual-check':'长将判负',resign:'认输',agreed:'双方同意和棋',interrupted:'对局中断 · 未完成者不计胜负',ranked:'排名已全部确定'};
  let bundle=null,code='',epoch=0,poll,worker=null,aiTimer,aiKey='',busy=false,selected=-1,path=[],promotion=null,confirmationAction='',replay=null,replayIndex=0,playTimer,clockOffset=0;
  const button=(label,action,cls='secondary-button',attrs='')=>'<button type="button" class="'+cls+'" data-board="'+action+'" '+attrs+'>'+label+'</button>';
  const race=kind=>['flight','halma'].includes(kind),sideName=V.sideName;
  function resultText(m){const result=m.state?.result||m.result;if(!result)return '进行中';if(['interrupted','ranked'].includes(result.reason))return reasons[result.reason];return (result.winner?sideName(m.kind,result.winner)+'获胜':'和棋')+' · '+(reasons[result.reason]||result.reason);}
  function message(err){const text=err?.message||'';return [[/Room changed/,'棋局已更新，请重新操作。'],[/Illegal move|Illegal roll/,'这一步不符合规则，请重新选择。'],[/Not your turn/,'当前不能由你操作这个席位。'],[/Players not ready/,'请填满席位，并等待所有真人准备。'],[/Room full|Seat occupied/,'这个席位已有玩家。'],[/Membership|Only host/,'你没有执行此操作的权限。'],[/Login required/,'请重新登录。'],[/Nothing to undo/,'还没有可以撤回的落子。'],[/Undo not available/,'飞行棋不能悔骰或撤回移动。'],[/Request pending|No request/,'请先处理当前请求。'],[/Opponent recently online/,'对方离线尚未满 5 分钟。'],[/Game ended|Game active/,'当前对局状态不允许这项操作。'],[/Room not found/,'找不到这个棋房。'],[/Invalid/,'请检查输入和当前席位状态。']].find(([r])=>r.test(text))?.[1]||'暂时无法完成，请检查网络后重试。';}
  function stopAI(){clearTimeout(aiTimer);worker?.terminate();worker=null;aiKey='';}
  function stop(){epoch++;clearTimeout(poll);clearInterval(playTimer);stopAI();chat.stop();bundle=null;code='';replay=null;selected=-1;path=[];promotion=null;confirmationAction='';busy=false;}
  const pendingKey=()=> 'board-pending:'+(api.account()?.id||'')+':'+code;
  const seat=()=>bundle?.match?.players.find(p=>p.accountId===api.account()?.id);
  const done=side=>(bundle?.match?.state.rankings||[]).includes(side);
  function header(title,lead){return '<header class="board-heading"><p class="eyebrow">A good move. A little company.</p><h1>'+e(title)+'</h1><p class="lead">'+lead+'</p></header>';}
  function rankings(m){const ranks=m.state?.rankings||m.rankings||[];return ranks.length?'<ol class="board-rankings">'+ranks.map((side,i)=>'<li><span>第 '+(i+1)+' 名</span> '+e(m.players.find(p=>p.side===side)?.name||'玩家')+' · '+sideName(m.kind,side)+'</li>').join('')+'</ol>':'';}
  function records(rows){rows=rows||{rooms:[],matches:[]};return '<div class="board-records">'+(rows.rooms.length?'<h3>我的棋房</h3><div class="account-record-list">'+rows.rooms.map(r=>'<article class="account-record-card"><div><strong>'+e(r.title)+'</strong><p>'+titles[r.kind]+' · '+e(r.code)+'</p></div><a class="small-button" href="#board/room/'+e(r.code)+'">进入房间</a></article>').join('')+'</div>':'<p class="muted">还没有棋房，创建一个邀请朋友吧。</p>')+(rows.matches.length?'<h3>对局与棋谱</h3><div class="account-record-list">'+rows.matches.map(m=>'<article class="account-record-card"><div><strong>'+titles[m.kind]+' · 第 '+m.round+' 局</strong><p>'+m.players.map(p=>e(p.name)+(p.bot?' · '+levels[p.level]:'')).join(' / ')+'</p><p>'+e(resultText(m))+' · '+new Date(m.createdAt).toLocaleDateString('zh-CN')+'</p>'+rankings(m)+'</div><a class="small-button" href="#board/replay/'+e(m.id)+'">查看棋谱</a></article>').join('')+'</div>':'')+'</div>';}
  async function home(generation){
   document.title='Board Games | Friends Games';const art={gomoku:'● ○',xiangqi:'帥 將',chess:'♔ ♞',flight:'✈ ⚄',halma:'✦'},description={gomoku:'15×15 · 自由规则',xiangqi:'标准走法 · 休闲重复规则',chess:'易位、吃过路兵与升变',flight:'2–4 人 · 完整排名',halma:'2 / 3 / 4 / 6 人 · 连跳路线'};
   api.shell('<main class="board-layout">'+header('Board Games','摆好棋盘，和朋友下一局。')+'<div class="board-kind-cards">'+Object.keys(titles).map(kind=>'<button class="panel board-kind-card" data-board="pick" data-kind="'+kind+'"><span class="board-kind-art '+kind+'-art">'+art[kind]+'</span><strong>'+titles[kind]+'</strong><p>'+description[kind]+'</p></button>').join('')+'</div><div class="board-home-grid"><section class="panel"><h2>开一间棋房</h2><form class="stack-form" data-board-form="create"><label for="board-kind">棋种</label><select id="board-kind" name="kind">'+Object.entries(titles).map(([v,t])=>'<option value="'+v+'">'+t+'</option>').join('')+'</select><label for="board-capacity">席位数</label><select id="board-capacity" name="capacity"><option value="2">2 人</option></select><label for="board-title">房间名称</label><input id="board-title" name="title" maxlength="60" required value="一起下棋"><label for="board-opponent">其他席位</label><select id="board-opponent" name="opponent"><option value="friend">等待朋友加入</option>'+Object.entries(levels).map(([v,t])=>'<option value="'+v+'">电脑 · '+t+'</option>').join('')+'</select><p class="field-hint">房主可在开局前分别调整每个空席的电脑难度。</p><button class="primary-button" type="submit">创建棋房</button></form></section><aside><section class="panel"><h2>加入朋友的棋房</h2><form class="stack-form" data-board-form="join"><label for="board-code">房间码</label><input id="board-code" name="code" required maxlength="6" placeholder="输入 6 位房间码"><button class="secondary-button" type="submit">加入棋房</button></form></section><div class="board-home-note"><h3>每一步，都有朋友相伴。</h3><p>五种棋都能在房间里聊天。棋谱和聊天会保存下来，下一次还可以继续。</p><p class="muted">飞行棋可手动交给电脑；托管和离开房间是两个独立操作。</p></div></aside></div><section class="panel board-my-records"><h2>我的棋房与对局</h2><div id="board-records"><p class="muted">正在读取…</p></div></section></main>','board');
   try{const rows=await api.rpc('board_records',{});if(epoch===generation)document.getElementById('board-records').innerHTML=records(rows);}catch(err){if(epoch===generation)document.getElementById('board-records').innerHTML='<p>'+e(message(err))+'</p>';}
  }
  function ruleNote(kind){return {gomoku:'黑棋先手 · 连成五子或以上获胜 · 无禁手',xiangqi:'红方先手 · 将死、困毙判负 · 三次重复通常和棋，单方长将判负',chess:'白方先手 · 支持易位、吃过路兵、升变 · 三次重复或 50 回合无进展自动和棋',flight:'6 起飞、再掷 · 同色跳格 · 虚线为飞行捷径 · 终点超出反弹 · 不可悔骰',halma:'相邻移动或隔一子连跳 · 点击结束本步提交 · 完成者棋子留盘'}[kind];}
  function myTurn(){const m=bundle?.match,p=seat();return m?.status==='active'&&p?.side===m.state.turn&&!m.pending&&!m.controls?.[p.side]&&!busy;}
  function paintBoard(){const m=bundle.match,s=m?.state||R.initial(bundle.room.kind,bundle.room.capacity||2,1),p=seat();document.getElementById('board-surface').innerHTML=V.render(s,{side:p?.side||1,interactive:myTurn(),selected,path});
   const controls=document.getElementById('board-move-controls');let html='';
   if(m?.status==='active'&&m.kind==='flight'){
    html='<div class="flight-dice" aria-label="当前骰子">'+(s.dice==null?'⚄':s.dice)+'</div>';
    if(myTurn())html+=s.dice==null?button('掷骰子','roll','primary-button'):'<p>选择一架飞机移动 · 点数 '+s.dice+'</p><div class="flight-token-picker">'+root.BoardRace.flightMoves(s).map(move=>button('飞机 '+(move.token+1),'plane','small-button','data-token="'+move.token+'"')).join('')+'</div>';
   }else if(m?.status==='active'&&m.kind==='halma'&&myTurn())html=button('结束本步','commit-path','primary-button',path.length<2?'disabled':'')+' '+button('重新选择','reset-path','secondary-button')+(!R.list(s).length?' '+button('无可行走法，跳过','pass','secondary-button'):'');
   controls.innerHTML=html;
  }
  function renderRoom(){
   const r=bundle.room,m=bundle.match;document.title=r.title+' | Board Games';selected=-1;path=[];promotion=null;
   if(!bundle.isMember){api.shell('<main class="narrow-layout panel"><p class="eyebrow">Board Games · '+titles[r.kind]+'</p><h1>'+e(r.title)+'</h1><p>'+ruleNote(r.kind)+'</p>'+(r.joinable?button('加入这个棋房','join','primary-button'):'<p>席位已满。</p>')+'<a href="#board">返回棋类大厅</a></main>','board');return;}
   // Only the chess surface and seat controls are replaced on a turn; chat's textarea stays mounted.
   if(!document.getElementById('board-room-header')){
    api.shell('<main class="board-layout"><header id="board-room-header" class="board-room-heading"></header><p id="board-sync-status" class="field-hint" role="status"></p><div class="board-room-grid"><section class="panel board-stage"><div id="board-turn" class="board-turn" role="status"></div><div id="board-surface"></div><div id="board-move-controls"></div><p id="board-rule" class="board-rule-hint"></p><p id="board-last-event" class="field-hint"></p><p id="board-ai-status" class="field-hint" role="status"></p></section><aside class="board-aside"><section id="board-room-seats" class="panel"></section><div id="board-chat-root"></div></aside></div><div id="board-confirm"></div><div id="board-retry"></div></main>','board');
    chat.mount(document.getElementById('board-chat-root'),code);
   }
   document.getElementById('board-room-header').innerHTML='<div><a class="spin-back" href="#board">← Board Games</a><h1>'+e(r.title)+'</h1><p><span class="spin-mode-badge">'+titles[r.kind]+'</span>房间码 '+e(code)+(m?' · 第 '+m.round+' 局':'')+'</p></div><div class="board-room-links">'+button('复制邀请链接','copy')+button('离开房间','ask-leave','ghost-button')+'</div>';
   const mine=seat(),active=m?.status==='active',me=r.members.find(p=>p?.accountId===api.account().id),current=m?.players.find(p=>p.side===m.state.turn),mineDone=done(mine?.side);
   document.getElementById('board-turn').textContent=active?(m.pending?'等待处理对局请求':mineDone?'你已完成 · 第 '+(m.state.rankings.indexOf(mine.side)+1)+' 名':myTurn()?'轮到你 · '+sideName(r.kind,m.state.turn):(current?.name||'对方')+' 正在行动 · '+sideName(r.kind,m.state.turn)):(m?resultText(m):'等待玩家准备');
   document.getElementById('board-rule').textContent=ruleNote(r.kind);document.getElementById('board-last-event').textContent=m?.events.length?'最近：'+eventText(m.events.at(-1),r.kind):'';document.getElementById('board-ai-status').textContent='';document.getElementById('board-sync-status').textContent='';
   let controls='';
   if(!active){controls+='<p class="field-hint">'+(m?(race(r.kind)?'下一局轮换先手。':'下一局交换阵营。'):'准备后由房主开始，不限时。')+'</p>'+button(me.ready?'取消准备':'准备','ready',me.ready?'secondary-button':'primary-button');
    if(r.isHost)controls+=' '+button(m?'开始下一局':'开始对局','start','primary-button',r.members.some(s=>!s||!s.ready)?'disabled':'');
    if(r.kind==='flight'&&r.isHost)controls+='<div class="board-bot-config"><label for="board-takeover-level">临时托管难度</label><select id="board-takeover-level">'+Object.entries(levels).map(([v,t])=>'<option value="'+v+'"'+(r.takeoverLevel===v?' selected':'')+'>'+t+'</option>').join('')+'</select>'+button('保存托管难度','takeover-level','small-button')+'</div>';
   }else{
    if(!mineDone)controls+='<div class="board-actions">'+(r.kind!=='flight'?button('悔棋','ask-undo','secondary-button',!m.state.moves.some(move=>move.side===mine.side)||m.pending?'disabled':''):'')+(!race(r.kind)?button('求和','ask-draw','secondary-button',m.pending?'disabled':'')+button('认输','ask-resign','ghost-button'):'')+'</div>';
    if(r.kind==='flight'&&!mineDone){const delegated=m.controls?.[mine.side];controls+='<div class="board-delegation">'+(delegated?'<p>你的席位由电脑代打 · '+levels[delegated.level]+'</p>'+button(delegated.returnRequested?'等待电脑本回合结束':'接回席位','return','primary-button',delegated.returnRequested?'disabled':''):button('交给电脑','takeover','secondary-button','data-side="'+mine.side+'"'+(m.pending?' disabled':'')))+'<p class="field-hint">手动托管和离开房间是两个独立操作。</p></div>';}
    controls+='<p class="board-presence muted"></p>'+(!mineDone?button('申请结束为中断','ask-interrupt','ghost-button','id="board-interrupt" hidden'):'')+'<div id="board-offline-takeover"></div>';
    if(m.pending){const p=m.pending,label={undo:'悔棋',draw:'和棋',interrupt:'结束为中断'}[p.type],mineAsked=p.by===mine.side,needed=p.required?.includes(mine.side),approved=p.approved?.includes(mine.side);
     controls+='<div class="board-request" role="status"><p>'+sideName(r.kind,p.by)+'申请'+label+'。'+(p.required?'（'+p.approved.length+'/'+p.required.length+' 已同意）':'')+'</p>'+(mineAsked?button('取消申请','cancel','small-button'):(needed&&!approved?button('同意','accept','primary-button')+' ':'')+button('拒绝','reject','secondary-button'))+'</div>';
    }
   }
   const memberCards=r.members.map((s,i)=>{const player=m?.players.find(p=>s?.accountId?p.accountId===s.accountId:p.bot&&p.seat===i),rank=player?(m.state.rankings||[]).indexOf(player.side):-1;
    let html='<div class="board-seat"><span class="board-seat-symbol"'+(race(r.kind)?' style="color:'+V.colors[i]+'"':'')+'>'+(s?(s.bot?'✦':'●'):'○')+'</span><div><strong>'+e(s?.name||'等待朋友加入')+'</strong><p>'+(!s?'空席':rank>=0?'第 '+(rank+1)+' 名':s.bot?'电脑 · '+levels[s.level]:active?sideName(r.kind,player.side)+(m.controls?.[player.side]?' · 电脑代打':''):s.ready?'已准备':'尚未准备')+'</p></div></div>';
    if(r.isHost&&!active&&i>0&&!s?.accountId)html+='<div class="board-seat-config"><select aria-label="席位 '+(i+1)+' 对手" id="board-bot-'+i+'"><option value="">等待好友</option>'+Object.entries(levels).map(([v,t])=>'<option value="'+v+'"'+(s?.level===v?' selected':'')+'>电脑 · '+t+'</option>').join('')+'</select>'+button('保存席位','bot','small-button','data-seat="'+i+'"')+'</div>';return html;
   }).join('');
   document.getElementById('board-room-seats').innerHTML='<h2>对弈席位</h2><div class="board-seats">'+memberCards+'</div>'+controls+(m?rankings(m)+'<p><a href="#board/replay/'+e(m.id)+'">查看本局棋谱 →</a></p>':'');
   paintBoard();confirmation();presence();retryNotice();maybeAI();
  }
  function presence(){if(!bundle?.isMember)return;const m=bundle.match,mine=seat(),node=document.querySelector('.board-presence'),b=document.getElementById('board-interrupt'),takeover=document.getElementById('board-offline-takeover');if(!m||m.status!=='active')return;
   const others=m.players.filter(p=>p.accountId&&p.accountId!==api.account().id&&!done(p.side)).map(p=>({...p,elapsed:Date.now()+clockOffset-Date.parse(bundle.room.members.find(s=>s?.accountId===p.accountId)?.seen)}));
   if(node)node.textContent=others.length?others.map(p=>p.name+'：'+(p.elapsed<45000?'在线':'暂离 '+Math.floor(p.elapsed/60000)+' 分钟')).join(' · '):'人机进度会保存，可随时回来继续';
   const absent=others.filter(p=>p.elapsed>=300000);if(b)b.hidden=!absent.length||Boolean(m.pending);
   if(takeover)takeover.innerHTML=m.kind==='flight'&&!done(mine?.side)&&!m.pending?absent.filter(p=>!m.controls?.[p.side]).map(p=>button('让电脑接管 '+e(p.name),'takeover','small-button','data-side="'+p.side+'"')).join(''):'';
  }
  function confirmation(){const node=document.getElementById('board-confirm');if(!node)return;
   if(promotion){node.innerHTML='<div class="modal-backdrop"><section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="board-promote-title"><h2 id="board-promote-title">选择升变棋子</h2><div class="dialog-actions">'+[[2,'后'],[3,'车'],[4,'象'],[5,'马']].map(([p,t])=>button(t,'promote','primary-button','data-piece="'+p+'"')).join('')+button('取消','dismiss')+'</div></section></div>';return;}
   const text={undo:'退回你最近一次落子之前？其他真人玩家需要全部同意。',draw:'向对方申请和棋？电脑对手会接受。',resign:'确认认输并结束本局？',interrupt:'申请结束整局？其他仍在局的在线真人需要全部同意。已确定的名次保留，其余不排名。',leave:'离开房间后保留进度和席位。飞行棋是否交给电脑，由你单独设置。'}[confirmationAction];
   node.innerHTML=text?'<div class="modal-backdrop"><section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="board-confirm-title"><h2 id="board-confirm-title">确认操作</h2><p>'+text+'</p><div class="dialog-actions">'+button('取消','dismiss')+button('确认','confirm','primary-button')+'</div></section></div>':'';
  }
  function retryNotice(){const node=document.getElementById('board-retry');if(node)node.innerHTML=sessionStorage.getItem(pendingKey())?'<p class="preview-notice">上次操作尚未确认。'+button('重试上次操作','retry','small-button')+'</p>':'';}
  async function sync(generation){const next=await api.rpc('board_get_room',{p_room_code:code});if(generation!==epoch||bundle&&next.room.revision<bundle.room.revision)return;const changed=!bundle||bundle.room.revision!==next.room.revision;bundle=next;if(next.serverNow)clockOffset=Date.parse(next.serverNow)-Date.now();if(changed)renderRoom();else{presence();maybeAI();}}
  async function perform(action,data={},receipt=null,retries=0){
   if(busy)return;const generation=epoch,key=pendingKey();if(!receipt&&sessionStorage.getItem(key)){api.toast('请先重试上次尚未确认的操作。');retryNotice();return;}
   if(action==='reply'&&!receipt)data={...data,requestId:bundle.match?.pending?.id};
   const request=receipt||{p_room_code:code,p_action:action,p_data:data,p_revision:bundle.room.revision,p_request_id:crypto.randomUUID()};sessionStorage.setItem(key,JSON.stringify(request));busy=true;stopAI();const status=document.getElementById('board-sync-status');if(status)status.textContent='正在保存操作…';
   try{const next=await api.rpc('board_action',request);sessionStorage.removeItem(key);if(generation!==epoch)return;bundle=next;confirmationAction='';busy=false;if(action==='leave'){api.route('board');return;}renderRoom();}
   catch(err){if(generation!==epoch)return;
    if(/Room changed/.test(err.message)&&retries<2&&(['ready','join','bot','takeover_level'].includes(action)||action==='reply'&&request.p_data.requestId)){
     sessionStorage.removeItem(key);busy=false;await sync(generation);if(generation!==epoch)return;
     if(action!=='reply'||bundle.match?.pending?.id===request.p_data.requestId)return await perform(action,data,{...request,p_revision:bundle.room.revision},retries+1);
    }
    if(/Room changed|Illegal|Not your turn|Players not ready|Room full|Seat occupied|Membership|Only host|Login required|Nothing to undo|Undo not available|Request pending|No request|Opponent recently online|Game ended|Game active|Invalid/.test(err.message)){sessionStorage.removeItem(key);busy=false;await sync(generation).catch(()=>{});if(bundle)renderRoom();}api.toast(message(err));}
   finally{if(generation===epoch){busy=false;retryNotice();maybeAI();}}
  }
  function maybeAI(){const m=bundle?.match;if(!m||m.status!=='active'||m.pending||bundle.room.driverId!==api.account()?.id||busy||document.hidden||sessionStorage.getItem(pendingKey()))return;
   const p=m.players.find(p=>p.side===m.state.turn),control=m.controls?.[p.side];if(!p.bot&&!control)return;const id=m.id+':'+bundle.room.revision;if(aiKey===id)return;stopAI();aiKey=id;const generation=epoch,started=Date.now(),status=document.getElementById('board-ai-status');if(status)status.textContent='电脑正在思考…';
   const submit=(action,data)=>{aiTimer=setTimeout(()=>{if(generation!==epoch||aiKey!==id)return;if(document.hidden||bundle.room.driverId!==api.account()?.id){stopAI();return;}perform(action,data);},Math.max(0,500-(Date.now()-started)));};
   if(m.kind==='flight'&&m.state.dice==null){submit('bot_roll',{});return;}
   worker=new Worker(new URL('src/board/worker.js',location.href));worker.onmessage=event=>{if(generation!==epoch||id!==aiKey)return;worker?.terminate();worker=null;if(event.data.error||!event.data.move){if(status)status.innerHTML='电脑暂时无法行动。'+button('重新思考','ai-retry','small-button');return;}submit('bot_move',{move:event.data.move});};
   worker.onerror=()=>{worker?.terminate();worker=null;if(generation===epoch&&status)status.innerHTML='电脑暂时无法行动。'+button('重新思考','ai-retry','small-button');};worker.postMessage({id,state:m.state,level:control?.level||p.level});
  }
  function eventText(event,kind){const who=sideName(kind,event.actor),move=event.move;
   if(move){if(kind==='flight')return who+'飞机 '+(move.token+1)+' · 掷出 '+move.dice+' · '+(move.from<0?'起飞':move.to===57?'到达终点':move.to>=52?'进入终点通道第 '+(move.to-51)+' 格':'前进到第 '+(((event.actor-1)*13+move.to)%52+1)+' 格')+(move.captures.length?' · 碰撞 '+move.captures.length+' 枚':'');if(move.pass)return who+'无可行走法，跳过';if(move.path)return who+'：'+move.path.map(i=>V.coordinate(kind,i)).join(' → ');return who+'：'+(move.from>=0?V.coordinate(kind,move.from)+' → ':'')+V.coordinate(kind,move.to)+(move.promote?' · 升变':'');}
   if(event.type.endsWith('roll'))return who+'掷出 '+event.dice+(event.skipped?' · 无可移动棋子，跳过':'');
   if(event.type==='reply')return who+(event.cancelled?' · 离线条件已解除，取消申请':event.accept?'同意':'拒绝')+({undo:'悔棋',draw:'和棋',interrupt:'结束整局'}[event.request?.type]||'申请')+(event.count?' · 撤回 '+event.count+' 步':'');
   if(event.type==='takeover')return sideName(kind,event.target)+'交给电脑代打';if(event.type==='return')return who+(event.waiting?'申请接回，等待当前回合结束':'接回席位');if(event.type==='returned')return who+'已接回席位';
   return who+' · '+({undo:event.count?'撤回 '+event.count+' 步':'申请悔棋',draw:event.result?'同意和棋':'申请和棋',resign:'认输',interrupt:event.result?'结束为中断':'申请结束为中断',cancel:'取消申请'}[event.type]||event.type);
  }
  function replayPaint(){if(!replay)return;const event=replayIndex?replay.events[replayIndex-1]:null,visibleMoves=[];for(const item of replay.events.slice(0,replayIndex)){if(item.move)visibleMoves.push(item.move);if(item.count)visibleMoves.splice(-item.count);}const move=visibleMoves.at(-1);
   const state=event?{...(event.state||{kind:replay.kind,board:event.board,turn:event.turn,result:event.result}),moves:move?[move]:[]}:R.initial(replay.kind,replay.players.length,replay.kind==='flight'||replay.kind==='halma'?(replay.events[0]?.actor||1):1);
   document.getElementById('board-replay-surface').innerHTML=V.render(state,{side:replay.players.find(p=>p.accountId===api.account().id)?.side||1});document.getElementById('board-replay-step').textContent=event?eventText(event,replay.kind):'开局摆法';document.getElementById('board-replay-range').value=replayIndex;document.getElementById('board-replay-count').textContent=replayIndex+' / '+replay.events.length;
   document.querySelectorAll('[data-board="first"],[data-board="prev"]').forEach(b=>b.disabled=replayIndex===0);document.querySelectorAll('[data-board="last"],[data-board="next"]').forEach(b=>b.disabled=replayIndex===replay.events.length);
  }
  async function replayPage(id,generation){const m=await api.rpc('board_get_match',{p_match_id:id});if(generation!==epoch)return;replay=m;replayIndex=0;document.title=titles[m.kind]+'棋谱 | Board Games';
   api.shell('<main class="board-layout"><a href="#board/room/'+e(m.roomCode)+'" class="spin-back">← 返回棋房</a>'+header(titles[m.kind]+' · 第 '+m.round+' 局棋谱',m.players.map(p=>e(p.name)+(p.bot?'（'+levels[p.level]+'）':'')).join(' / '))+'<p>'+e(resultText(m))+'</p>'+rankings(m)+'<div class="board-replay-layout"><section class="panel board-stage"><div id="board-replay-surface"></div><p id="board-replay-step" role="status"></p><div class="board-replay-controls">'+button('开局','first','small-button')+button('上一步','prev','small-button')+button('自动播放','play','small-button',m.events.length?'':'disabled')+button('下一步','next','small-button')+button('最后','last','small-button')+'</div><label for="board-replay-range">回放进度 <span id="board-replay-count"></span></label><input type="range" id="board-replay-range" min="0" max="'+m.events.length+'" value="0"></section><aside class="panel board-event-panel"><h2>完整过程</h2><ol class="board-event-list">'+m.events.map((v,i)=>'<li>'+button(e(eventText(v,m.kind)),'seek','ghost-button','data-step="'+(i+1)+'"')+'</li>').join('')+'</ol><p class="field-hint">走棋、掷骰、申请与托管均按时间记录。</p></aside></div></main>','board');replayPaint();
  }
  async function render(view,id){stop();window.scrollTo(0,0);const generation=epoch;if(!view){await home(generation);return;}code=String(id||'').toUpperCase();api.shell('<main class="narrow-layout panel"><p role="status">正在打开棋局…</p></main>','board');
   try{if(view==='replay'){await replayPage(id,generation);return;}await sync(generation);const tick=async()=>{if(epoch!==generation)return;if(!document.hidden&&!busy){try{await sync(generation);const n=document.getElementById('board-sync-status');if(n)n.textContent='';}catch{const n=document.getElementById('board-sync-status');if(n)n.textContent='同步暂时中断，正在重试…';}}if(epoch===generation)poll=setTimeout(tick,2000);};poll=setTimeout(tick,2000);}
   catch(err){if(epoch===generation)api.shell('<main class="narrow-layout panel"><h1>暂时无法打开棋局</h1><p>'+e(message(err))+'</p><a href="#board">回到棋类大厅</a></main>','board');}
  }
  function capacityOptions(){const k=document.getElementById('board-kind').value;document.getElementById('board-capacity').innerHTML=(k==='flight'?[2,3,4]:k==='halma'?[2,3,4,6]:[2]).map(n=>'<option value="'+n+'">'+n+' 人</option>').join('');}
  document.addEventListener('change',event=>{if(event.target.id==='board-kind')capacityOptions();});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stopAI();else maybeAI();});
  document.addEventListener('click',async event=>{const node=event.target.closest('[data-board]');if(!node||node.disabled)return;const action=node.dataset.board;
   if(action==='pick'){document.getElementById('board-kind').value=node.dataset.kind;capacityOptions();document.getElementById('board-title').value=titles[node.dataset.kind]+' · 朋友棋房';document.getElementById('board-kind').focus();return;}
   if(action==='cell'){
    if(!myTurn())return;const m=bundle.match,i=Number(node.dataset.index),s=m.state,who=seat().side;
    if(m.kind==='gomoku'){if(!s.board[i])await perform('move',{move:{to:i}});}
    else if(m.kind==='halma'){
     if(s.board[i]===who){selected=i;path=[i];paintBoard();}
     else if(path.length&&root.BoardRace.halmaLegal(s,{path:[...path,i]})){path.push(i);paintBoard();}return;
    }else if(Math.sign(s.board[i])===who){selected=selected===i?-1:i;paintBoard();}
    else if(selected>=0){let move={from:selected,to:i};if(m.kind==='chess'&&R.list(s).some(v=>v.from===selected&&v.to===i&&v.promote)){promotion=move;confirmation();}else if(R.valid(s,move))await perform('move',{move});else api.toast('这一步不符合规则，请重新选择。');}return;
   }
   if(action==='promote'){const move={...promotion,promote:Number(node.dataset.piece)};promotion=null;await perform('move',{move});return;}
   if(action==='plane'){if(myTurn())await perform('move',{move:{token:Number(node.dataset.token)}});return;}
   if(action==='commit-path'){if(path.length>1)await perform('move',{move:{path:path.slice()}});return;}
   if(action==='reset-path'){selected=-1;path=[];paintBoard();return;}if(action==='pass'){await perform('move',{move:{pass:true}});return;}
   if(action.startsWith('ask-')){confirmationAction=action.slice(4);confirmation();return;}if(action==='dismiss'){confirmationAction='';promotion=null;confirmation();return;}if(action==='confirm'){await perform(confirmationAction);return;}
   if(action==='copy'){try{await navigator.clipboard.writeText(location.href);api.toast('邀请链接已复制。');}catch{api.toast('请复制地址栏中的房间链接。');}return;}
   if(action==='ready'){const me=bundle.room.members.find(s=>s?.accountId===api.account().id);await perform('ready',{ready:!me.ready});return;}
   if(action==='bot'){const i=Number(node.dataset.seat);await perform('bot',{seat:i,level:document.getElementById('board-bot-'+i).value||null});return;}
   if(action==='takeover-level'){await perform('takeover_level',{level:document.getElementById('board-takeover-level').value});return;}
   if(action==='takeover'){await perform('takeover',{side:Number(node.dataset.side)});return;}
   if(['join','start','cancel','roll','return'].includes(action)){await perform(action);return;}
   if(action==='accept'||action==='reject'){await perform('reply',{accept:action==='accept'});return;}
   if(action==='retry'){const receipt=JSON.parse(sessionStorage.getItem(pendingKey())||'null');if(receipt)await perform(receipt.p_action,receipt.p_data,receipt);return;}
   if(action==='ai-retry'){stopAI();maybeAI();return;}
   if(replay){clearInterval(playTimer);const play=document.querySelector('[data-board="play"]');if(action==='play'&&replay.events.length&&play.textContent==='自动播放'){if(replayIndex===replay.events.length)replayIndex=0;play.textContent='暂停';playTimer=setInterval(()=>{replayIndex=Math.min(replay.events.length,replayIndex+1);replayPaint();if(replayIndex>=replay.events.length){clearInterval(playTimer);play.textContent='自动播放';}},900);return;}
    play.textContent='自动播放';if(action==='first')replayIndex=0;if(action==='last')replayIndex=replay.events.length;if(action==='prev')replayIndex=Math.max(0,replayIndex-1);if(action==='next')replayIndex=Math.min(replay.events.length,replayIndex+1);if(action==='seek')replayIndex=Number(node.dataset.step);replayPaint();
   }
  });
  document.addEventListener('input',event=>{if(event.target.id==='board-replay-range'){clearInterval(playTimer);document.querySelector('[data-board="play"]').textContent='自动播放';replayIndex=Number(event.target.value);replayPaint();}});
  document.addEventListener('submit',async event=>{const form=event.target;if(!form.dataset.boardForm)return;event.preventDefault();const values=new FormData(form),submit=form.querySelector('button[type="submit"]');if(submit.disabled)return;submit.disabled=true;const generation=epoch;
   try{if(form.dataset.boardForm==='join'){api.route('board/room/'+String(values.get('code')).trim().toUpperCase());return;}const opponent=values.get('opponent'),next=await api.rpc('board_create_room',{p_kind:values.get('kind'),p_title:values.get('title'),p_capacity:Number(values.get('capacity')),p_bot_level:opponent==='friend'?null:opponent});if(generation===epoch)api.route('board/room/'+next.room.code);}
   catch(err){api.toast(message(err));}finally{if(submit.isConnected)submit.disabled=false;}
  });return {render,stop,records};
 };
})(globalThis);
