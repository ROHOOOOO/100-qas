// Run in isolated PGlite only. Exercises public RPCs as anon and compares rules to the browser.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const require=createRequire(import.meta.url),R=require('../src/board/rules.js');require('../src/board/chess.js');const G=require('../src/board/race.js');require('../src/board/local.js');
const {fixtures,halmaFinish}=require('./verify-board-expanded.cjs');
const modulePath=process.env.PGLITE_MODULE_PATH||'@electric-sql/pglite', {PGlite}=require(modulePath),{pgcrypto}=createRequire(require.resolve(modulePath))('@electric-sql/pglite/contrib/pgcrypto');
const db=new PGlite({extensions:{pgcrypto}});let parity=0,checks=0;
const schema=readFileSync('supabase/schema.sql','utf8');
async function rpc(name,args){const keys=Object.keys(args);return db.transaction(async tx=>{await tx.exec('set local role anon');return (await tx.query(`select ${name}(${keys.map((k,i)=>k+' => $'+(i+1)).join(',')}) value`,keys.map(k=>k==='p_data'?JSON.stringify(args[k]):args[k]))).rows[0].value;});}
async function transition(s,m,label){let actual;try{actual=(await db.query('select board_play_game($1::jsonb,$2::jsonb) value',[JSON.stringify(s),JSON.stringify(m)])).rows[0].value;}catch(e){e.message=label+': '+e.message;throw e;}const next=R.play(s,m);assert.deepEqual(actual,next,label);parity++;return next;}
async function roll(s,die){const next=G.roll(s,die),actual=(await db.query('select board_flight_roll($1::jsonb,$2) value',[JSON.stringify(s),die])).rows[0].value;assert.deepEqual(actual,next);parity++;return next;}
const reject=async(p,re)=>{await assert.rejects(p,re);checks++;};
try{
 await db.exec('create role anon; create role authenticated;create schema extensions;create extension pgcrypto with schema extensions;');await db.exec(schema);
 for(const f of fixtures)await transition(f.state,f.move,f.label);
 let seed=17;const pick=n=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
 for(const [kind,count]of [['chess',2],['halma',2],['halma',3],['halma',4],['halma',6],['flight',2],['flight',3],['flight',4]]){
  let s=R.initial(kind,count);const initial=(await db.query('select board_initial_game($1,$2,1) value',[kind,count])).rows[0].value;assert.deepEqual(initial,s);checks++;
  for(let i=0;i<80&&!s.result;i++){
   if(kind==='flight'){s=await roll(s,1+pick(6));if(!s.dice)continue;}
   const list=R.list(s),m=list[pick(list.length)]||{pass:true};s=await transition(s,m,kind+' random '+i);
   if(kind!=='flight'&&!s.result&&i%17===16){const who=s.moves.at(-1).side,actual=(await db.query('select board_expanded_undo($1::jsonb,$2) value',[JSON.stringify(s),who])).rows[0].value;assert.deepEqual(actual,R.undo(s,who));parity++;}
  }
 }
 console.log('Expanded rules match PostgreSQL:',parity);
 const accounts=[];for(let i=0;i<7;i++)accounts.push(await rpc('account_register',{p_username:'extra_'+i,p_password:'testing123',p_display_name:'棋友'+i,p_security_question:1,p_security_answer:'中文答案'}));
 let local={accounts:accounts.map(a=>a.account)};
 async function lifecycle(mode){
  const call=async(i,name,p={})=>{if(mode==='sql')return rpc(name,{...p,p_account_token:accounts[i].token});const draft=structuredClone(local);const result=globalThis.BoardLocal.run(draft,name,p,draft.accounts[i]);local=draft;return result;};
  let state,code;
  const act=async(i,action,data={},revision=state.room.revision,id=randomUUID())=>{const next=await call(i,'board_action',{p_room_code:code,p_action:action,p_data:data,p_revision:revision,p_request_id:id});state=next;return next;};
  const refresh=async(i=0)=>state=await call(i,'board_get_room',{p_room_code:code});
  const setState=async(s)=>{if(mode==='sql')await db.query('update board_matches set state=$1::jsonb where id=$2',[JSON.stringify(s),state.match.id]);else local.boardMatches[state.match.id].state=structuredClone(s);await refresh();};
  const age=async(i,seconds)=>{if(mode==='sql')await db.query("update board_seats set last_seen=clock_timestamp()-$1*interval '1 second' where room_code=$2 and account_id=$3",[seconds,code,accounts[i].account.id]);else local.boardRooms[code].seats.find(s=>s?.accountId===accounts[i].account.id).seen=new Date(Date.now()-seconds*1000).toISOString();};
  const create=async(kind,count,humans=count)=>{state=await call(0,'board_create_room',{p_kind:kind,p_capacity:count,p_title:'多人与聊天'});code=state.room.code;for(let i=1;i<humans;i++)await act(i,'join');for(let i=humans;i<count;i++)await act(0,'bot',{seat:i,level:['easy','normal','hard'][i%3]});for(let i=0;i<humans;i++)await act(i,'ready',{ready:true});await act(0,'start');assert.equal(state.match.players.length,count);checks++;};
  for(const [kind,count]of [['chess',3],['flight',6],['halma',5]])await reject(call(0,'board_create_room',{p_kind:kind,p_capacity:count,p_title:'invalid'}),/Invalid/);
  await create('flight',4,3);
  await reject(act(0,'takeover',{side:2}),/recently online/);await reject(act(0,'undo'),/Undo not available/);
  await reject(call(6,'board_chat_list',{p_room_code:code}),/Membership/);await reject(call(6,'board_chat_send',{p_room_code:code,p_text:'no',p_request_id:randomUUID()}),/Membership/);
  const first=await call(0,'board_chat_send',{p_room_code:code,p_text:'中文 English 👋 <img src=x>\n下一局见',p_request_id:randomUUID()});
  assert.equal(first.text,'中文 English 👋 <img src=x>\n下一局见');
  const duplicate=await call(0,'board_chat_send',{p_room_code:code,p_text:'duplicate',p_request_id:first.requestId});assert.equal(duplicate.id,first.id);assert.equal(duplicate.text,first.text);checks++;
  for(let i=0;i<54;i++)await call(1,'board_chat_send',{p_room_code:code,p_text:'历史 '+i,p_request_id:randomUUID()});
  const latest=await call(2,'board_chat_list',{p_room_code:code}),older=await call(0,'board_chat_list',{p_room_code:code,p_before_id:latest[0].id});assert.equal(latest.length,50);assert.equal(older.length,5);assert.equal(older[0].text,first.text);assert.equal((await call(0,'board_chat_list',{p_room_code:code,p_after_id:latest.at(-1).id})).length,0);checks++;
  await reject(call(0,'board_chat_send',{p_room_code:code,p_text:'字'.repeat(1001),p_request_id:randomUUID()}),/Invalid message/);
  let s=G.initial('flight',4,1);s.dice=6;await setState(s);
  await act(0,'takeover',{side:1});await act(0,'leave');assert.equal(state.match.controls[1].mode,'manual');await refresh();assert(state.match.controls[1]);checks++;
  await act(0,'return');assert(state.match.controls[1].returnRequested);assert.equal(state.match.state.dice,6);
  await reject(act(0,'move',{move:{token:0}}),/Not your turn/);
  await act(0,'bot_move',{move:{token:0}});assert(state.match.controls[1]);assert.equal(state.match.state.turn,1);checks++;
  s=structuredClone(state.match.state);s.dice=1;await setState(s);await act(0,'bot_move',{move:{token:0}});assert(!state.match.controls[1]);assert.equal(state.match.events.at(-1).type,'returned');checks++;
  await age(1,301);await act(0,'takeover',{side:2});await refresh(1);assert.equal(state.match.controls[2].mode,'offline');await act(1,'return');assert(state.match.controls[2].returnRequested);checks++;
  // Only the elected, recently present browser may advance bots; no online humans means no progress.
  await age(0,60);s=structuredClone(state.match.state);s.dice=6;await setState(s);await age(0,60);await reject(act(0,'bot_move',{move:{token:0}}),/Not your turn/);await act(1,'bot_move',{move:{token:0}});checks++;
  for(let i=0;i<3;i++)await age(i,60);await reject(act(2,'bot_roll'),/Not your turn/);await refresh(2);await act(2,'bot_roll');checks++;
  // Idempotent dice retry never generates a second result.
  await refresh(0);s=G.initial('flight',4,1);await setState(s);const rev=state.room.revision,id=randomUUID();await act(0,'roll',{},rev,id);const rolled=structuredClone(state.match.state),events=state.match.events.length;await act(0,'roll',{},rev,id);assert.deepEqual(state.match.state,rolled);assert.equal(state.match.events.length,events);checks++;
  // Offline end requires each unfinished online human; rejoining removes the reason to end.
  await age(1,301);await refresh(2);await act(0,'interrupt');assert.deepEqual(state.match.pending.required,[3]);await refresh(1);await act(2,'reply',{accept:true});assert.equal(state.match.status,'active');assert.equal(state.match.pending,null);checks++;
  await age(1,301);await act(0,'interrupt');await act(2,'reply',{accept:true});assert.equal(state.match.status,'interrupted');checks++;
  const replay=await call(1,'board_get_match',{p_match_id:state.match.id});assert(replay.events.every(v=>v.state));assert(replay.events.some(v=>v.type==='returned'));checks++;
  for(let i=0;i<3;i++)await act(i,'ready',{ready:true});await act(0,'start');assert.equal((await call(0,'board_chat_list',{p_room_code:code})).length,50);checks++;
  // Halma votes include all other humans and restore a complete path atomically.
  await create('halma',6,3);let move=R.list(state.match.state)[0],side=state.match.state.turn;await act(side<=3?side-1:0,side<=3?'move':'bot_move',{move});
  if(side>3){s={...state.match.state,turn:1};await setState(s);move=R.list(s)[0];await act(0,'move',{move});side=1;}
  await act(side-1,'undo');assert.equal(state.match.pending.required.length,2);for(const other of [1,2,3].filter(n=>n!==side)){await act(other-1,'reply',{accept:true});}assert.equal(state.match.state.turn,side);assert.equal(state.match.pending,null);checks++;
  await reject(act(0,'takeover',{side:1}),/Invalid action/);
  // Completed players stay spectators; the remaining two determine their final positions.
  const f=halmaFinish(3);await create('halma',3);await setState(f.state);await act(0,'move',{move:f.move});assert.deepEqual(state.match.state.rankings,[1]);await reject(act(0,'move',{move:f.move}),/Not your turn/);
  const end=halmaFinish(3,2);end.state.rankings=[1];await setState(end.state);await act(1,'move',{move:end.move});assert.deepEqual(state.match.state.rankings,[1,2,3]);assert.equal(state.match.status,'finished');checks++;
  const saved=await call(0,'board_records');assert(saved.matches.some(m=>m.id===state.match.id&&m.rankings.length===3));checks++;
  // Chess promotion travels through the same validated room action and replay.
  await create('chess',2);const c=R.initial('chess');c.board.fill(0);c.board[60]=1;c.board[7]=-1;c.board[8]=6;c.castling=0;await setState(c);const white=state.match.players.findIndex(p=>p.side===1);await act(white,'move',{move:{from:8,to:0,promote:5}});assert.equal(state.match.state.board[0],5);assert.equal(state.match.events.at(-1).move.promote,5);checks++;
  console.log(mode+' expanded lifecycle passed');
 }
 await lifecycle('local');await lifecycle('sql');
 for(const table of ['board_seats','board_messages','board_halma_geometry'])await reject(db.transaction(async tx=>{await tx.exec('set local role anon');await tx.query('select * from '+table);}),/permission denied/);
 await reject(rpc('board_initial_game',{kind:'chess'}),/permission denied|does not exist/);
 const before=(await db.query('select count(*)::int n from board_messages')).rows;await db.exec(schema);await db.exec(schema);assert.deepEqual((await db.query('select count(*)::int n from board_messages')).rows,before);checks++;
 console.log(JSON.stringify({expandedDatabaseChecks:checks,expandedRuleParityCases:parity,schemaReapplied:true}));
}catch(e){console.error('FAILED',e.message,e.where||'',e.internalQuery||'');process.exitCode=1;}finally{await db.close();}
