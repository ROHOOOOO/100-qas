/* Local preview mirrors the SQL RPC transitions. It is not a shared online database. */
(function(root){
 'use strict';
 const fail=message=>{throw new Error(message);},now=()=>new Date().toISOString(),clone=value=>JSON.parse(JSON.stringify(value));
 const terminal=r=>['matched','interrupted'].includes(r.phase);
 const member=(r,a)=>r.hostId===a.id||r.guestId===a.id;
 const wordRow=t=>({round:t.round,word1:t.word1,word2:t.word2,name1:t.name1,name2:t.name2,startedAt:t.startedAt,revealedAt:t.revealedAt});
 function bundle(db,r,a){
  if(!member(r,a))return {isMember:false,room:{code:r.code,title:r.title,joinable:!r.guestId&&!terminal(r)}};
  const current=r.rounds.at(-1),previous=r.rounds.findLast(t=>t.revealedAt),host=r.hostId===a.id;
  return clone({isMember:true,serverNow:now(),room:{code:r.code,title:r.title,phase:r.phase,round:r.round,revision:r.revision,createdAt:r.createdAt,startedAt:r.startedAt,endedAt:r.endedAt},
   players:[r.hostId,r.guestId].map((id,i)=>id?{id,name:db.accounts.find(p=>p.id===id)?.displayName||[r.hostName,r.guestName][i],ready:!!r.ready[i],submitted:r.phase==='writing'&&!!current?.['word'+(i+1)]}:null),
   current:r.phase==='writing'?{round:r.round,startedAt:current.startedAt,ownWord:current['word'+(host?1:2)]||null}:null,
   previous:previous?wordRow(previous):null,revealedCount:r.rounds.filter(t=>t.revealedAt).length});
 }
 function run(db,name,p,a){
  db.wordRooms=db.wordRooms||{};const rooms=Object.values(db.wordRooms);
  if(name==='words_records')return rooms.filter(r=>member(r,a)).sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).slice(0,100).map(r=>({code:r.code,title:r.title,phase:r.phase,rounds:r.rounds.filter(t=>t.revealedAt).length,createdAt:r.createdAt,startedAt:r.startedAt,endedAt:r.endedAt,names:[r.hostName,r.guestName].filter(Boolean)}));
  if(name==='words_create_room'){
   if(!p.p_request_id)fail('Invalid request.');
   const previous=rooms.find(r=>r.hostId===a.id&&r.createId===p.p_request_id);if(previous)return bundle(db,previous,a);
   const title=String(p.p_title||'').trim();if(!title||[...title].length>60)fail('Invalid title.');
   let code;do{code=crypto.randomUUID().replace(/-/g,'').slice(0,6).toUpperCase();}while(db.wordRooms[code]);
   const r={code,title,hostId:a.id,hostName:a.displayName,guestId:null,guestName:null,phase:'waiting',round:0,revision:0,ready:[false,false],rounds:[],requests:[],createdAt:now(),startedAt:null,endedAt:null,createId:p.p_request_id};db.wordRooms[code]=r;return bundle(db,r,a);
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
   if(r.guestId)fail('Room full.');if(terminal(r))fail('Game ended.');
   r.guestId=a.id;r.guestName=a.displayName;r.phase='ready';r.revision++;return bundle(db,r,a);
  }
  if(!member(r,a))fail('Membership required.');
  if(r.requests.some(q=>q.id===p.p_request_id&&q.accountId===a.id))return bundle(db,r,a);
  if(terminal(r))fail('Game ended.');
  if(p.p_round!==r.round)fail('Round changed.');
  const i=r.hostId===a.id?0:1,data=p.p_data||{};
  if(action==='ready'){
   if(!['ready','revealed'].includes(r.phase)||!r.guestId||typeof data.ready!=='boolean')fail('Not ready phase.');
   r.ready[i]=data.ready;
   if(r.ready.every(Boolean)){
    const startedAt=now();r.round++;r.startedAt=r.startedAt||startedAt;r.phase='writing';r.ready=[false,false];
    r.rounds.push({round:r.round,startedAt,revealedAt:null,word1:null,word2:null,key1:null,key2:null,name1:db.accounts.find(p=>p.id===r.hostId).displayName,name2:db.accounts.find(p=>p.id===r.guestId).displayName});
   }
  }else if(action==='submit'){
   if(r.phase!=='writing')fail('Not writing phase.');const t=r.rounds.at(-1);
   if(t['word'+(i+1)])fail('Already submitted.');
   if(typeof data.word!=='string')fail('Invalid word.');
   const word=data.word.trim(),key=root.WordMeet.normalize(word);
   const prior=r.rounds.at(-2);if(prior&&[prior.key1,prior.key2].includes(key))fail('Previous word.');
   t['word'+(i+1)]=word;t['key'+(i+1)]=key;
   if(t.word1&&t.word2){t.revealedAt=now();r.phase=t.key1===t.key2?'matched':'revealed';if(r.phase==='matched')r.endedAt=t.revealedAt;}
  }else if(action==='interrupt'){
   r.phase='interrupted';r.endedAt=now();const t=r.rounds.at(-1);if(t&&!t.revealedAt){t.word1=t.word2=t.key1=t.key2=null;}
  }else fail('Invalid action.');
  r.requests.push({id:p.p_request_id,accountId:a.id});r.revision++;return bundle(db,r,a);
 }
 root.WordMeetLocal={run};
})(globalThis);
