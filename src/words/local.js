/* Local preview mirrors the SQL RPC transitions. It is not a shared online database. */
(function(root){
 'use strict';
 const fail=message=>{throw new Error(message);},now=()=>new Date().toISOString(),clone=value=>JSON.parse(JSON.stringify(value));
 const terminal=r=>['matched','interrupted'].includes(r.phase);
 const member=(r,a)=>r.members.some(m=>m.id===a.id);
 const display=(db,m)=>db.accounts.find(a=>a.id===m.id)?.displayName||m.name;
 // Upgrade saved two-player rooms in place, including unfinished rounds and name snapshots.
 function upgrade(r){
  if(!r.members)r.members=[r.hostId,r.guestId].flatMap((id,i)=>id?[{id,name:[r.hostName,r.guestName][i],ready:!!r.ready[i]}]:[]);
  for(const t of r.rounds)if(!t.words)t.words=r.members.map((m,i)=>({id:m.id,name:t['name'+(i+1)],word:t['word'+(i+1)]||null,key:t['key'+(i+1)]||null}));
  return r;
 }
 const wordRow=t=>({round:t.round,words:t.words.map(({id,name,word})=>({id,name,word})),word1:t.words[0]?.word,word2:t.words[1]?.word,name1:t.words[0]?.name,name2:t.words[1]?.name,startedAt:t.startedAt,revealedAt:t.revealedAt});
 function bundle(db,r,a){
  if(!member(r,a))return {isMember:false,room:{code:r.code,title:r.title,joinable:r.members.length<6&&!r.startedAt&&!terminal(r)}};
  const current=r.rounds.at(-1),previous=r.rounds.findLast(t=>t.revealedAt);
  return clone({isMember:true,serverNow:now(),room:{code:r.code,title:r.title,hostId:r.hostId,capacity:6,phase:r.phase,round:r.round,revision:r.revision,createdAt:r.createdAt,startedAt:r.startedAt,endedAt:r.endedAt},
   players:r.members.map(m=>({id:m.id,name:display(db,m),ready:m.ready,submitted:r.phase==='writing'&&!!current?.words.find(w=>w.id===m.id)?.word})),
   current:r.phase==='writing'?{round:r.round,startedAt:current.startedAt,ownWord:current.words.find(w=>w.id===a.id)?.word||null}:null,
   previous:previous?wordRow(previous):null,revealedCount:r.rounds.filter(t=>t.revealedAt).length});
 }
 function beginRound(db,r){
  const startedAt=now();r.round++;r.startedAt=r.startedAt||startedAt;r.phase='writing';r.members.forEach(m=>m.ready=false);
  r.rounds.push({round:r.round,startedAt,revealedAt:null,words:r.members.map(m=>({id:m.id,name:display(db,m),word:null,key:null}))});
 }
 function run(db,name,p,a){
  db.wordRooms=db.wordRooms||{};const rooms=Object.values(db.wordRooms).map(upgrade);
  if(name==='words_records')return rooms.filter(r=>member(r,a)).sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).slice(0,100).map(r=>({code:r.code,title:r.title,phase:r.phase,rounds:r.rounds.filter(t=>t.revealedAt).length,createdAt:r.createdAt,startedAt:r.startedAt,endedAt:r.endedAt,names:r.members.map(m=>m.name)}));
  if(name==='words_create_room'){
   if(!p.p_request_id)fail('Invalid request.');
   const previous=rooms.find(r=>r.hostId===a.id&&r.createId===p.p_request_id);if(previous)return bundle(db,previous,a);
   const title=String(p.p_title||'').trim();if(!title||[...title].length>60)fail('Invalid title.');
   let code;do{code=crypto.randomUUID().replace(/-/g,'').slice(0,6).toUpperCase();}while(db.wordRooms[code]);
   const r={code,title,hostId:a.id,members:[{id:a.id,name:a.displayName,ready:false}],phase:'waiting',round:0,revision:0,rounds:[],requests:[],createdAt:now(),startedAt:null,endedAt:null,createId:p.p_request_id};db.wordRooms[code]=r;return bundle(db,r,a);
  }
  const r=db.wordRooms[String(p.p_room_code||'').trim().toUpperCase()];if(!r)fail('Room not found.');
  if(name==='words_get_room')return bundle(db,r,a);
  if(name==='words_history'){
   if(!member(r,a))fail('Membership required.');
   return r.rounds.filter(t=>t.revealedAt&&(p.p_before_round==null||t.round<p.p_before_round)).slice(-25).reverse().map(wordRow);
  }
  if(name!=='words_action'||!p.p_request_id)fail('Invalid request.');
  const action=p.p_action;
  if(action==='join'){
   if(member(r,a))return bundle(db,r,a);
   if(terminal(r))fail('Game ended.');if(r.startedAt)fail('Game started.');if(r.members.length>=6)fail('Room full.');
   r.members.push({id:a.id,name:a.displayName,ready:false});r.phase='ready';r.revision++;return bundle(db,r,a);
  }
  if(!member(r,a))fail('Membership required.');
  if(r.requests.some(q=>q.id===p.p_request_id&&q.accountId===a.id))return bundle(db,r,a);
  if(terminal(r))fail('Game ended.');
  if(p.p_round!==r.round)fail('Round changed.');
  const m=r.members.find(m=>m.id===a.id),data=p.p_data||{};
  if(action==='ready'){
   if(!['waiting','ready','revealed'].includes(r.phase)||typeof data.ready!=='boolean')fail('Not ready phase.');
   m.ready=data.ready;
   if(r.phase==='revealed'&&r.members.every(m=>m.ready))beginRound(db,r);
  }else if(action==='start'){
   if(r.hostId!==a.id)fail('Host required.');
   if(r.startedAt||!['waiting','ready'].includes(r.phase))fail('Game started.');
   if(r.members.length<2||!r.members.every(m=>m.ready))fail('Players not ready.');
   beginRound(db,r);
  }else if(action==='submit'){
   if(r.phase!=='writing')fail('Not writing phase.');const t=r.rounds.at(-1),entry=t.words.find(w=>w.id===a.id);
   if(entry.word)fail('Already submitted.');
   if(typeof data.word!=='string')fail('Invalid word.');
   const word=data.word.trim(),key=root.WordMeet.normalize(word);
   const prior=r.rounds.at(-2);if(prior?.words.some(w=>w.key===key))fail('Previous word.');
   entry.word=word;entry.key=key;
   if(t.words.every(w=>w.word)){t.revealedAt=now();r.phase=t.words.every(w=>w.key===key)?'matched':'revealed';if(r.phase==='matched')r.endedAt=t.revealedAt;}
  }else if(action==='interrupt'){
   r.phase='interrupted';r.endedAt=now();for(const t of r.rounds)if(!t.revealedAt){t.words.forEach(w=>{w.word=w.key=null;});t.word1=t.word2=t.key1=t.key2=null;}
  }else fail('Invalid action.');
  r.requests.push({id:p.p_request_id,accountId:a.id});r.revision++;return bundle(db,r,a);
 }
 root.WordMeetLocal={run};
})(globalThis);
