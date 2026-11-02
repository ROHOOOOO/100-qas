// Runs against an isolated PostgreSQL engine and the local model. Never production.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const require=createRequire(import.meta.url),modulePath=process.env.PGLITE_MODULE_PATH||'@electric-sql/pglite';
const {PGlite}=require(modulePath),{pgcrypto}=createRequire(require.resolve(modulePath))('@electric-sql/pglite/contrib/pgcrypto');
require('../src/words/normalize.js');require('../src/words/local.js');
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create role anon;create role authenticated;create schema extensions;create extension pgcrypto with schema extensions;');
const schema=readFileSync('supabase/schema.sql','utf8'),migration=readFileSync('supabase/words.sql','utf8');await db.exec(schema);
const names=['登录','天空','旁观者'];const users=[];let checks=0;
const check=(value,message)=>{assert(value,message);checks++;};
async function rpc(name,args){const keys=Object.keys(args);return db.transaction(async tx=>{await tx.exec('set local role anon');return (await tx.query(`select public.${name}(${keys.map((k,i)=>k+' => $'+(i+1)).join(',')}) result`,keys.map(k=>k==='p_data'?JSON.stringify(args[k]):args[k]))).rows[0].result;});}
const reject=async(value,re)=>{await assert.rejects(value,re);checks++;};
for(let i=0;i<3;i++)users.push(await rpc('account_register',{p_username:'word_test_'+i,p_display_name:names[i],p_password:'testpass123',p_security_question:1,p_security_answer:'中文答案'}));
await reject(rpc('words_records',{p_account_token:'invalid'}),/Login required/);
let local={accounts:users.map(x=>x.account)};
for(const mode of ['local','sql']){
 const call=async(i,name,data={})=>{if(mode==='sql')return rpc(name,{...data,p_account_token:users[i].token});const draft=structuredClone(local),result=WordMeetLocal.run(draft,name,data,draft.accounts[i]);local=draft;return result;};
 const createId=randomUUID();let state=await call(0,'words_create_room',{p_title:'互相联想',p_request_id:createId}),code=state.room.code;
 check((await call(0,'words_create_room',{p_title:'changed',p_request_id:createId})).room.code===code,'Create retry must not create another room');
 const act=async(i,action,data={},round=state.room.round,id=randomUUID())=>{const next=await call(i,'words_action',{p_room_code:code,p_action:action,p_data:data,p_round:round,p_request_id:id});if(next.isMember)state=next;return next;};
 check((await call(2,'words_get_room',{p_room_code:code})).isMember===false,'Nonmembers receive no game');
 await reject(call(2,'words_history',{p_room_code:code}),/Membership/);
 await reject(act(2,'interrupt'),/Membership/);
 await reject(act(0,'ready',{ready:true}),/Not ready/);
 await act(1,'join');await reject(act(2,'join'),/Room full/);check(state.room.phase==='ready');
 const readyId=randomUUID();await act(0,'ready',{ready:true},0,readyId);await act(0,'ready',{ready:true},0,readyId);check(state.room.round===0);
 await act(0,'ready',{ready:false});check(!state.players[0].ready);
 await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});check(state.room.phase==='writing'&&state.room.round===1);
 check((await call(0,'words_get_room',{p_room_code:code})).current.startedAt===(await call(1,'words_get_room',{p_room_code:code})).current.startedAt,'Shared clock');
 await reject(act(0,'ready',{ready:true},0),/Round changed/);
 for(const word of ['字','一二三四五六七','a','abcdefghijklmnop','abc中','hello world','test1','苹果!','😀😀','',true,null,123])await reject(act(0,'submit',{word}),/Invalid word/);
 const receipt=randomUUID();await act(0,'submit',{word:'秘密'},1,receipt);
 const other=await call(1,'words_get_room',{p_room_code:code});check(!JSON.stringify(other).includes('秘密'),'Other player must not receive secret word');check(other.players[0].submitted&&other.current.ownWord===null);
 check((await call(0,'words_get_room',{p_room_code:code})).current.ownWord==='秘密');
 check((await call(1,'words_history',{p_room_code:code})).length===0);
 await act(0,'submit',{word:'秘密'},1,receipt);await reject(act(0,'submit',{word:'改变'}),/Already submitted/);
 await act(1,'submit',{word:'天空'});check(state.room.phase==='revealed');check(state.previous.word1==='秘密'&&state.previous.word2==='天空');
 await act(0,'submit',{word:'秘密'},1,receipt);check(state.room.round===1,'Late retry cannot advance');
 await act(0,'ready',{ready:true});check(state.room.phase==='revealed');await act(1,'ready',{ready:true});check(state.room.round===2&&state.room.phase==='writing');
 await reject(act(0,'submit',{word:'秘密'},1),/Round changed/);
 for(const word of ['秘密','天空'])await reject(act(0,'submit',{word}),/Previous word/);
 // Passing the reminder never locks the round or reveals anything.
 if(mode==='sql')await db.query("update words_rounds set started_at=clock_timestamp()-interval '90 seconds' where room_code=$1 and round_no=2",[code]);else local.wordRooms[code].rounds[1].startedAt=new Date(Date.now()-90000).toISOString();
 await act(0,'submit',{word:' 蘋果 '});check(state.room.phase==='writing');await act(1,'submit',{word:'苹果'});check(state.room.phase==='matched'&&!!state.room.endedAt);check(state.previous.word1==='蘋果'&&state.previous.word2==='苹果','Preserve original spelling');
 await reject(act(0,'interrupt'),/Game ended/);
 check((await call(0,'words_history',{p_room_code:code})).length===2);check((await call(1,'words_records')).some(r=>r.code===code&&r.phase==='matched'));check(!(await call(2,'words_records')).some(r=>r.code===code));
 const doneCode=code;
 state=await call(0,'words_create_room',{p_title:'中断验证',p_request_id:randomUUID()});code=state.room.code;await act(1,'join');await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await act(0,'submit',{word:'隐藏'});const stopId=randomUUID();await act(1,'interrupt',{},1,stopId);check(state.room.phase==='interrupted');check(!JSON.stringify(state).includes('隐藏'));check((await call(0,'words_history',{p_room_code:code})).length===0);check(!JSON.stringify(await call(0,'words_get_room',{p_room_code:code})).includes('隐藏'));await act(1,'interrupt',{},1,stopId);
 if(mode==='sql')check((await db.query('select word1,word2,key1,key2 from words_rounds where room_code=$1',[code])).rows.every(t=>Object.values(t).every(v=>v===null)),'Interrupted secrets erased');else check(local.wordRooms[code].rounds.every(t=>!t.word1&&!t.word2&&!t.key1&&!t.key2));
 state=await call(0,'words_create_room',{p_title:'英文验证',p_request_id:randomUUID()});code=state.room.code;await act(1,'join');await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await act(0,'submit',{word:'Abcdefghijklmno'});await act(1,'submit',{word:'天空'});await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await reject(act(1,'submit',{word:'abcdefghijklmno'}),/Previous word/);await act(0,'submit',{word:'蘋果'});await act(1,'submit',{word:'cloud'});await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await reject(act(0,'submit',{word:'苹果'}),/Previous word/);await act(0,'submit',{word:'Abcdefghijklmno'});await act(1,'submit',{word:'abcdefghijklmno'});check(state.room.phase==='matched','Case-insensitive match; words older than the previous round may be reused');
 // History is paged newest-first; all old rounds remain accessible.
 state=await call(0,'words_create_room',{p_title:'长局验证',p_request_id:randomUUID()});code=state.room.code;await act(1,'join');
 for(let n=0;n<28;n++){await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await act(0,'submit',{word:n%2?'树木':'太阳'});await act(1,'submit',{word:n%2?'森林':'月亮'});}
 const latest=await call(1,'words_history',{p_room_code:code});check(latest.length===25&&latest[0].round===28&&latest.at(-1).round===4);const early=await call(1,'words_history',{p_room_code:code,p_before_round:4});check(early.length===3&&early.at(-1).round===1);
 await act(0,'interrupt');check((await call(1,'words_history',{p_room_code:code})).length===25);check((await call(0,'words_get_room',{p_room_code:doneCode})).room.phase==='matched');
 console.log(mode+' lifecycle, privacy, history and retries: PASS');
}
for(const w of ['苹果','蘋果','頭髮','头发','自由自在无忧','AbCdefghijklmno','  SKY\t','𠀀𠀁'])check((await db.query('select words_key($1) k',[w])).rows[0].k===WordMeet.normalize(w),'Normalization parity: '+w);
for(const table of ['words_rooms','words_rounds','words_requests'])await reject(db.transaction(async tx=>{await tx.exec('set local role anon');await tx.query('select * from '+table);}),/permission denied/);
for(const role of ['anon','authenticated'])await reject(db.transaction(async tx=>{await tx.exec('set local role '+role);await tx.query("select words_key('蘋果')");}),/permission denied/);
await reject(rpc('words_bundle',{p_room_code:'ABCDEF',p_account_id:users[0].account.id}),/permission denied/);
const before=(await db.query('select count(*)::int n from words_rounds')).rows;await db.exec(migration);await db.exec(schema);assert.deepEqual((await db.query('select count(*)::int n from words_rounds')).rows,before);checks++;
console.log(JSON.stringify({checks,fullSchemaAndIncrementalMigrationReapplied:true}));await db.close();
