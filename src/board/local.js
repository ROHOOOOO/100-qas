/* Offline preview; the SQL RPCs enforce the same transitions in shared rooms. */
(function(root){
 'use strict';const R=root.BoardRules,copy=v=>JSON.parse(JSON.stringify(v)),now=()=>new Date().toISOString(),fail=m=>{throw Error(m);};
 const kinds=['gomoku','xiangqi','chess','flight','halma'],levels=['easy','normal','hard'],race=k=>['flight','halma'].includes(k);
 const validCount=(k,n)=>k==='flight'?[2,3,4].includes(n):k==='halma'?[2,3,4,6].includes(n):n===2;
 const name=(db,id)=>db.accounts.find(a=>a.id===id)?.displayName||'玩家';
 function migrate(r){if(!r.seats)r.seats=[{accountId:r.ownerId,bot:false,ready:r.hostReady,seen:r.hostSeen},r.guestId?{accountId:r.guestId,bot:false,ready:r.guestReady,seen:r.guestSeen}:r.botLevel?{accountId:null,bot:true,level:r.botLevel,ready:true}:null];r.capacity=r.capacity||2;r.takeoverLevel=r.takeoverLevel||'normal';}
 const member=(r,id)=>r.seats.some(s=>s?.accountId===id),online=s=>s?.accountId&&Date.now()-Date.parse(s.seen)<45000;
 function seats(db,r){return r.seats.map((s,i)=>s?{...s,seat:i,name:s.bot?'电脑':name(db,s.accountId)}:null);}
 function bundle(db,r,id){
  if(!member(r,id))return {isMember:false,room:{code:r.code,kind:r.kind,title:r.title,revision:r.revision,capacity:r.capacity,joinable:r.seats.some(s=>!s)}};
  const m=r.matchId?db.boardMatches[r.matchId]:null;if(m)m.controls=m.controls||{};
  return copy({isMember:true,serverNow:now(),room:{...r,seats:undefined,requests:undefined,isHost:r.ownerId===id,members:seats(db,r),driverId:r.seats.find(online)?.accountId||null,guestId:r.seats[1]?.accountId||null,botLevel:r.seats[1]?.level||null},match:m});
 }
 const snapshot=s=>{const {moves,positions,...rest}=s;return copy(rest);};
 function record(m,event){m.events.push({...event,at:now(),board:m.state.board.slice(),turn:m.state.turn,result:copy(m.state.result),state:snapshot(m.state)});}
 function finish(m){if(m.state.result){m.status=m.state.result.reason==='interrupted'?'interrupted':'finished';m.endedAt=now();m.pending=null;}}
 function dice(){const a=new Uint8Array(1);do{crypto.getRandomValues(a);}while(a[0]>=252);return a[0]%6+1;}
 function run(db,rpc,p,a){
  db.boardRooms=db.boardRooms||{};db.boardMatches=db.boardMatches||{};db.boardMessages=db.boardMessages||{};Object.values(db.boardRooms).forEach(migrate);
  for(const m of Object.values(db.boardMatches))if(m.pending&&!Array.isArray(m.pending.required)){m.pending.required=m.players.filter(s=>s.accountId&&s.side!==m.pending.by).map(s=>s.side);m.pending.approved=[];}
  if(rpc==='board_records')return {rooms:Object.values(db.boardRooms).filter(r=>member(r,a.id)).map(r=>({code:r.code,title:r.title,kind:r.kind})),matches:Object.values(db.boardMatches).filter(m=>m.players.some(s=>s.accountId===a.id)).sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).map(m=>({id:m.id,roomCode:m.roomCode,kind:m.kind,round:m.round,status:m.status,result:m.state.result,rankings:m.state.rankings||[],players:m.players,createdAt:m.createdAt}))};
  if(rpc==='board_get_match'){const m=db.boardMatches[p.p_match_id];if(!m||!m.players.some(s=>s.accountId===a.id))fail('Membership required.');return copy(m);}
  if(rpc==='board_create_room'){
   const n=p.p_capacity||2;if(!kinds.includes(p.p_kind)||!validCount(p.p_kind,n)||!String(p.p_title||'').trim()||[...p.p_title.trim()].length>60)fail('Invalid room.');
   if(p.p_bot_level&&!levels.includes(p.p_bot_level)||p.p_takeover_level&&!levels.includes(p.p_takeover_level))fail('Invalid difficulty.');
   let code;do{code=crypto.randomUUID().replace(/-/g,'').slice(0,6).toUpperCase();}while(db.boardRooms[code]);
   const r={code,kind:p.p_kind,title:p.p_title.trim(),ownerId:a.id,capacity:n,takeoverLevel:p.p_takeover_level||'normal',seats:[{accountId:a.id,bot:false,ready:false,seen:now()},...Array.from({length:n-1},()=>p.p_bot_level?{accountId:null,bot:true,ready:true,level:p.p_bot_level}:null)],hostSide:0,round:0,revision:0,matchId:null,requests:[]};db.boardRooms[code]=r;return bundle(db,r,a.id);
  }
  const r=db.boardRooms[String(p.p_room_code||'').trim().toUpperCase()];if(!r)fail('Room not found.');const me=r.seats.find(s=>s?.accountId===a.id);
  if(rpc==='board_get_room'){if(me)me.seen=now();return bundle(db,r,a.id);}
  if(rpc.startsWith('board_chat_')){
   if(!me)fail('Membership required.');const rows=db.boardMessages[r.code]||(db.boardMessages[r.code]=[]);
   if(rpc==='board_chat_list'){let list=rows.filter(m=>(p.p_before_id==null||m.id<p.p_before_id)&&(p.p_after_id==null||m.id>p.p_after_id));return copy(p.p_after_id!=null?list.slice(0,50):list.slice(-50));}
   if(rpc!=='board_chat_send')fail('Invalid action.');if(!p.p_request_id)fail('Request id required.');const previous=rows.find(m=>m.requestId===p.p_request_id&&m.accountId===a.id);if(previous)return copy(previous);
   const text=String(p.p_text||'').trim();if(!text||[...text].length>1000)fail('Invalid message.');db.boardMessageId=(db.boardMessageId||0)+1;
   const m={id:db.boardMessageId,accountId:a.id,name:name(db,a.id),text,createdAt:now(),requestId:p.p_request_id};rows.push(m);return copy(m);
  }
  if(rpc!=='board_action')fail('Invalid action.');const action=p.p_action,d=p.p_data||{};
  if(action!=='join'&&!me)fail('Membership required.');if(!p.p_request_id)fail('Request id required.');
  if(r.requests.some(q=>q.id===p.p_request_id&&q.account===a.id))return bundle(db,r,a.id);if(p.p_revision!==r.revision)fail('Room changed.');
  let m=r.matchId?db.boardMatches[r.matchId]:null,active=m?.status==='active';if(m)m.controls=m.controls||{};
  if(action==='join'){
   if(!me){const i=r.seats.findIndex(s=>!s);if(i<0||active)fail('Room full.');r.seats[i]={accountId:a.id,bot:false,ready:false,seen:now()};}
  }else if(action==='leave'){if(me)me.ready=false;}
  else if(action==='ready'){if(active)fail('Game active.');me.ready=Boolean(d.ready);}
  else if(action==='bot'||action==='takeover_level'){
   if(r.ownerId!==a.id)fail('Only host.');if(active)fail('Game active.');
   if(action==='takeover_level'){if(r.kind!=='flight'||!levels.includes(d.level))fail('Invalid difficulty.');r.takeoverLevel=d.level;}
   else{const i=d.seat??1;if(!Number.isInteger(i)||i<1||i>=r.capacity||r.seats[i]?.accountId)fail('Seat occupied.');if(d.level&&!levels.includes(d.level))fail('Invalid difficulty.');r.seats[i]=d.level?{accountId:null,bot:true,ready:true,level:d.level}:null;}
   r.seats[0].ready=false;
  }else if(action==='start'){
   if(r.ownerId!==a.id)fail('Only host.');if(active||r.seats.some(s=>!s||!s.ready))fail('Players not ready.');
   r.hostSide=race(r.kind)?(r.round?r.hostSide%r.capacity+1:crypto.getRandomValues(new Uint8Array(1))[0]%r.capacity+1):(r.round?-r.hostSide:crypto.getRandomValues(new Uint8Array(1))[0]%2?1:-1);r.round++;
   m={id:crypto.randomUUID(),roomCode:r.code,kind:r.kind,round:r.round,players:seats(db,r).map((s,i)=>({...s,side:race(r.kind)?i+1:i?-r.hostSide:r.hostSide})),state:R.initial(r.kind,r.capacity,race(r.kind)?r.hostSide:1),controls:{},pending:null,events:[],status:'active',createdAt:now(),endedAt:null};
   db.boardMatches[m.id]=m;r.matchId=m.id;r.seats.forEach(s=>{if(!s.bot)s.ready=false;});
  }else{
   if(!active)fail('Game ended.');const actor=m.players.find(s=>s.accountId===a.id);if(!actor)fail('Membership required.');const who=actor.side,done=side=>(m.state.rankings||[]).includes(side),event={type:action,actor:who};
   const human=s=>s.accountId&&!done(s.side),seatOf=s=>r.seats.find(v=>v?.accountId===s.accountId);
   const absent=()=>m.players.some(s=>human(s)&&Date.now()-Date.parse(seatOf(s)?.seen)>=300000);
   if(m.pending&&!['reply','cancel','resign','return'].includes(action))fail('Request pending.');
   if(action==='move'||action==='bot_move'||action==='roll'||action==='bot_roll'){
    const botAction=action.startsWith('bot_'),turn=m.players.find(s=>s.side===m.state.turn),delegated=turn.bot||m.controls[turn.side];
    if(botAction){if(!delegated||r.seats.find(online)?.accountId!==a.id)fail('Not your turn.');}else if(m.state.turn!==who||delegated)fail('Not your turn.');
    event.actor=turn.side;const beforeTurn=m.state.turn,beforeSerial=m.state.turnSerial;
    if(action.endsWith('roll')){const value=dice();m.state=root.BoardRace.roll(m.state,value);event.dice=value;event.skipped=m.state.dice==null;}
    else{m.state=R.play(m.state,d.move);event.move=m.state.moves.at(-1);}
    record(m,event);
    if(m.controls[beforeTurn]?.returnRequested&&(m.state.turn!==beforeTurn||m.state.turnSerial!==beforeSerial||m.state.result)){delete m.controls[beforeTurn];record(m,{type:'returned',actor:beforeTurn});}
   }else if(action==='takeover'||action==='return'){
    if(r.kind!=='flight'||done(who))fail('Invalid action.');
    if(action==='takeover'){const target=d.side??who,player=m.players.find(s=>s.side===target);if(!player||player.bot||done(target)||m.controls[target])fail('Invalid action.');
     if(target!==who&&Date.now()-Date.parse(seatOf(player)?.seen)<300000)fail('Opponent recently online.');m.controls[target]={mode:target===who?'manual':'offline',level:r.takeoverLevel,returnRequested:false};event.target=target;
    }else{if(!m.controls[who])fail('Invalid action.');if(m.state.turn===who)m.controls[who].returnRequested=true;else delete m.controls[who];event.waiting=Boolean(m.controls[who]);}
    record(m,event);
   }else if(action==='resign'){
    if(race(r.kind))fail('Invalid action.');m.state.result={winner:-who,reason:'resign'};record(m,event);
   }else if(['undo','draw','interrupt'].includes(action)){
    if(done(who))fail('Invalid action.');if(action==='undo')R.undo(m.state,who);if(action==='draw'&&race(r.kind))fail('Invalid action.');if(action==='interrupt'&&!absent())fail('Opponent recently online.');
    const required=m.players.filter(s=>s.accountId&&s.side!==who&&(action!=='interrupt'||human(s)&&online(seatOf(s)))).map(s=>s.side);
    if(required.length)m.pending={id:p.p_request_id,type:action,by:who,required,approved:[]};
    else if(action==='undo'){const count=m.state.moves.length;m.state=R.undo(m.state,who);event.count=count-m.state.moves.length;}
    else m.state.result={winner:0,reason:action==='draw'?'agreed':'interrupted'};record(m,event);
   }else if(action==='reply'){
    if(!m.pending||m.pending.by===who)fail('No request.');event.request=copy(m.pending);event.accept=Boolean(d.accept);
    if(!d.accept)m.pending=null;
    else{if(!m.pending.required.includes(who)||m.pending.approved.includes(who))fail('No request.');m.pending.approved.push(who);
     if(m.pending.type==='interrupt'&&!absent()){m.pending=null;event.cancelled=true;}
     else if(m.pending.required.every(s=>m.pending.approved.includes(s))){if(m.pending.type==='undo'){const count=m.state.moves.length;m.state=R.undo(m.state,m.pending.by);event.count=count-m.state.moves.length;}else m.state.result={winner:0,reason:m.pending.type==='draw'?'agreed':'interrupted'};m.pending=null;}
    }record(m,event);
   }else if(action==='cancel'){if(!m.pending||m.pending.by!==who)fail('No request.');m.pending=null;record(m,event);}
   else fail('Invalid action.');finish(m);
  }
  r.revision++;r.requests.push({id:p.p_request_id,account:a.id});const current=r.seats.find(s=>s?.accountId===a.id);if(current)current.seen=now();return bundle(db,r,a.id);
 }
 root.BoardLocal={run};
})(globalThis);
