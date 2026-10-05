// Isolated PostgreSQL + local backend parity. Never runs against production.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
const require=createRequire(import.meta.url);
const R=require('../src/board/rules.js');require('../src/board/chess.js');require('../src/board/race.js');require('../src/board/local.js');
const {fixtures}=require('./verify-board-rules.cjs');
const modulePath=process.env.PGLITE_MODULE_PATH||'@electric-sql/pglite';
const {PGlite}=require(modulePath);
const {pgcrypto}=createRequire(require.resolve(modulePath))('@electric-sql/pglite/contrib/pgcrypto');
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create role anon;create role authenticated;create schema extensions;create extension pgcrypto with schema extensions;');
const schema=readFileSync('supabase/schema.sql','utf8');await db.exec(schema);
let checks=0,parity=0;
async function rpc(name,args){
 const keys=Object.keys(args),values=keys.map(k=>k==='p_data'?JSON.stringify(args[k]):args[k]);
 return db.transaction(async tx=>{await tx.exec('set local role anon');return (await tx.query(`select public.${name}(${keys.map((k,i)=>k+' => $'+(i+1)).join(',')}) as value`,values)).rows[0].value;});
}
async function reject(p,pattern){await assert.rejects(p,pattern);checks++;}
for(const {state,move,label} of fixtures){
 const actual=(await db.query('select board_play($1::jsonb,$2::jsonb) as value',[JSON.stringify(state),JSON.stringify(move)])).rows[0].value;
 assert.deepEqual(actual,R.play(state,move),label);parity++;
}
let seed=34;const pick=n=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
for(const kind of ['gomoku','xiangqi']){
 let state=R.initial(kind);
 for(let i=0;i<100&&!state.result;i++){
  const list=R.moves(kind,state.board,state.turn),move=list[pick(list.length)];
  const actual=(await db.query('select board_play($1::jsonb,$2::jsonb) as value',[JSON.stringify(state),JSON.stringify(move)])).rows[0].value;
  state=R.play(state,move);assert.deepEqual(actual,state);parity++;
  if(i%13===12){const actualUndo=(await db.query('select board_undo($1::jsonb,$2) as value',[JSON.stringify(state),-state.turn])).rows[0].value;assert.deepEqual(actualUndo,R.undo(state,-state.turn));parity++;}
 }
}
await reject(db.query('select board_play($1::jsonb,$2::jsonb)',[JSON.stringify(R.initial('gomoku')),JSON.stringify({to:2.5})]),/invalid input|Illegal/);
const accounts=[];
for(let i=0;i<3;i++) accounts.push(await rpc('account_register',{p_username:'board_'+i,p_password:'testing123',p_display_name:['小满','晚风','旁观者'][i],p_security_question:1,p_security_answer:'答案'}));
let localDb={accounts:accounts.map(a=>a.account)};
async function lifecycle(mode){
 const call=async(i,name,data={})=>{
  if(mode==='sql')return rpc(name,{...data,p_account_token:accounts[i].token});
  const draft=structuredClone(localDb),value=globalThis.BoardLocal.run(draft,name,data,draft.accounts[i]);localDb=draft;return value;
 };
 let state=await call(0,'board_create_room',{p_kind:'gomoku',p_title:'好友验证'}),code=state.room.code;
 const act=async(i,action,data={},revision=state.room.revision,id=randomUUID())=>{const next=await call(i,'board_action',{p_room_code:code,p_action:action,p_data:data,p_revision:revision,p_request_id:id});if(next.isMember)state=next;return next;};
 await reject(act(0,'start'),/Players not ready/);
 const publicRoom=await call(2,'board_get_room',{p_room_code:code});assert(!publicRoom.isMember&&!publicRoom.match&&!publicRoom.room.members);checks++;
 await reject(act(2,'move',{move:{to:112}}),/Membership/);
 await act(1,'join');await reject(act(2,'join'),/Room full/);
 await reject(act(1,'bot',{level:'hard'}),/Only host/);
 const id=randomUUID(),rev=state.room.revision;await act(0,'ready',{ready:true},rev,id);const readyRev=state.room.revision;
 await act(0,'ready',{ready:true},rev,id);assert.equal(state.room.revision,readyRev);checks++;
 await reject(act(1,'ready',{ready:true},rev),/Room changed/);
 await act(1,'ready',{ready:true});await reject(act(1,'start'),/Only host/);await act(0,'start');
 const firstSide=state.room.hostSide,firstId=state.match.id;const who=()=>state.match.players.findIndex(p=>p.side===state.match.state.turn);
 const first=who(),second=1-first;
 await reject(act(second,'move',{move:{to:112}}),/Not your turn/);
 await reject(act(0,'bot',{level:'hard'}),/Seat occupied|Game active/);
 await act(first,'move',{move:{to:112}});await reject(act(second,'move',{move:{to:112}}),/Illegal/);
 await act(second,'move',{move:{to:113}});
 await act(first,'undo');await reject(act(first,'reply',{accept:true}),/No request/);
 await reject(act(first,'move',{move:{to:97}}),/Request pending/);
 await act(second,'reply',{accept:false});assert.equal(state.match.state.moves.length,2);checks++;
 await act(first,'undo');await act(second,'reply',{accept:true});assert.equal(state.match.state.moves.length,0);assert.equal(state.match.events.at(-1).count,2);checks++;
 await act(first,'move',{move:{to:112}});await act(first,'undo');await act(second,'reply',{accept:true});assert.equal(state.match.state.moves.length,0);assert.equal(state.match.events.at(-1).count,1);checks++;
 await act(0,'draw');await act(0,'cancel');assert.equal(state.match.pending,null);checks++;
 await act(0,'draw');await act(1,'reply',{accept:true});assert.equal(state.match.status,'finished');assert.deepEqual(state.match.state.result,{winner:0,reason:'agreed'});checks++;
 await reject(act(first,'undo'),/Game ended/);
 await reject(call(2,'board_get_match',{p_match_id:firstId}),/Membership/);
 const replay=await call(1,'board_get_match',{p_match_id:firstId});assert.equal(replay.events.length,13);assert(replay.events.every(v=>v.board.length===225));checks++;
 await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await act(0,'start');assert.notEqual(state.match.id,firstId);assert.equal(state.room.hostSide,-firstSide);checks++;
 await reject(act(0,'interrupt'),/recently online/);
 if(mode==='sql')await db.query("update board_seats set last_seen=clock_timestamp()-interval '299 seconds' where room_code=$1 and seat=1",[code]);else localDb.boardRooms[code].seats[1].seen=new Date(Date.now()-299000).toISOString();
 await reject(act(0,'interrupt'),/recently online/);
 if(mode==='sql')await db.query("update board_seats set last_seen=clock_timestamp()-interval '301 seconds' where room_code=$1 and seat=1",[code]);else localDb.boardRooms[code].seats[1].seen=new Date(Date.now()-301000).toISOString();
 await act(0,'interrupt');assert.equal(state.match.status,'interrupted');assert.equal(state.match.state.result.winner,0);checks++;
 const records=await call(1,'board_records');assert.equal(records.matches.length,2);assert.equal((await call(2,'board_records')).matches.length,0);checks++;
 // Fill a vacant friend room with a bot, validate permissions, undo and resignation.
 state=await call(0,'board_create_room',{p_kind:'xiangqi',p_title:'电脑验证'});code=state.room.code;
 await act(0,'bot',{level:'hard'});await act(0,'ready',{ready:true});await act(0,'start');
 const humanSide=state.match.players[0].side;
 for(let i=0;i<4;i++){const m=R.moves('xiangqi',state.match.state.board,state.match.state.turn)[0];await act(0,state.match.state.turn===humanSide?'move':'bot_move',{move:m});}
 await act(0,'undo');assert.equal(state.match.state.turn,humanSide);checks++;
 await reject(act(0,'bot',{level:'easy'}),/Seat occupied|Game active/);
 await act(0,'resign');assert.deepEqual(state.match.state.result,{winner:-humanSide,reason:'resign'});checks++;
 if(mode==='sql')await rpc('account_update_profile',{p_account_token:accounts[0].token,p_display_name:'新用户名'});else localDb.accounts[0].displayName='新用户名';
 const refreshed=await call(0,'board_get_room',{p_room_code:code});assert.equal(refreshed.room.members[0].name,'新用户名');assert.equal(refreshed.match.players[0].name,'小满');checks++;
 console.log(mode+' lifecycle passed');
}
await lifecycle('local');await lifecycle('sql');
for(const table of ['board_rooms','board_matches','board_requests'])await reject(db.transaction(async tx=>{await tx.exec('set local role anon');await tx.query('select * from '+table);}),/permission denied/);
await reject(rpc('board_initial',{p_kind:'gomoku'}),/permission denied/);
await reject(rpc('board_records',{p_account_token:'invalid'}),/Login required/);
const before=(await db.query('select count(*)::int n from board_matches')).rows;
await db.exec(schema);await db.exec(schema);assert.deepEqual((await db.query('select count(*)::int n from board_matches')).rows,before);checks++;
console.log(JSON.stringify({backendChecks:checks,ruleParityCases:parity,schemaReapplied:true}));await db.close();
