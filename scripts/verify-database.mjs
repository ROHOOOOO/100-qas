// Run against an isolated in-memory PostgreSQL database, never a live Supabase project.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const require=createRequire(import.meta.url);
const modulePath=process.env.PGLITE_MODULE_PATH || '@electric-sql/pglite';
const {PGlite}=require(modulePath);
const {pgcrypto}=createRequire(require.resolve(modulePath))('@electric-sql/pglite/contrib/pgcrypto');
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create role anon; create role authenticated; create schema extensions; create extension pgcrypto with schema extensions;');
const schema=readFileSync(resolve('supabase/schema.sql'),'utf8');
await db.exec(schema);
let checks=0;
async function rpc(name,args){
  const keys=Object.keys(args), values=keys.map(k=>['p_questions','p_answers','p_qa_players','p_tycoon_players'].includes(k)&&args[k]!=null?JSON.stringify(args[k]):args[k]);
  return db.transaction(async tx=>{
    await tx.exec('set local role anon');
    const r=await tx.query(`select public.${name}(${keys.map((k,i)=>`${k} => $${i+1}`).join(',')}) as value`,values);
    return r.rows[0].value;
  });
}
async function sql(query){return db.query(query);}
async function deny(name,args,pattern){await assert.rejects(rpc(name,args),pattern);checks++;}
async function extraChecks(a,b,c,code,qaCode,qaPlayerId){
  // A valid session near expiry is renewed. An expired session stays invalid.
  await db.query("update game_account_sessions set expires_at=now()+interval '1 hour' where account_id=$1",[a.account.id]);
  const renewed=await rpc('account_refresh',{p_account_token:a.token});
  assert(Date.parse(renewed.expiresAt)>Date.now()+89.99*86400000);checks++;
  const expired=await rpc('account_login',{p_username:c.account.username,p_password:'testing123'});
  await db.query("update game_account_sessions set expires_at=now()-interval '1 second' where account_id=$1",[c.account.id]);
  await deny('account_refresh',{p_account_token:expired.token},/Login required/);
  // A new login restores room ownership and past draws without player keys.
  const another=await rpc('account_login',{p_username:a.account.username,p_password:'testing123'});
  const restored=await rpc('spin_get_room',{p_room_code:code,p_account_token:another.token});
  assert(restored.room.isHost);assert.equal(restored.history.length,3);checks++;
  const qaEmpty=await rpc('qa_create_room',{p_questions:['x'],p_account_token:a.token});
  const records=await rpc('account_get_records',{p_account_token:a.token});
  assert(records.qa.some(r=>r.roomCode===qaEmpty.room.code));checks++;
  // Old anonymous records can be claimed once with their original device secret.
  const legacyId=randomUUID();
  await db.query("insert into qa_players(id,room_id,nickname,player_key) select $1,id,'legacy','legacy-secret' from qa_rooms where code=$2",[legacyId,qaCode]);
  const binding={p_qa_players:[{roomCode:qaCode,playerId:legacyId,playerKey:'legacy-secret'}],p_tycoon_players:[]};
  let bound=await rpc('account_bind_records',{...binding,p_account_token:b.token});assert.equal(bound.qaBound,1);
  bound=await rpc('account_bind_records',{...binding,p_account_token:a.token});assert.equal(bound.qaBound,0);checks++;
  const wrongKey=await rpc('qa_get_room',{p_room_code:qaCode,p_player_id:qaPlayerId,p_player_key:'legacy-key',p_account_token:b.token});
  assert.notEqual(wrongKey.currentPlayerId,qaPlayerId);checks++;
  // More than one page: each draw is reachable exactly once, in descending ID order.
  await db.query(`insert into spin_draws(room_id,account_id,request_id,actor_name,mode,options_snapshot,result_index,result,started_at,ends_at)
    select r.id,$1,gen_random_uuid(),'pagination','individual',array['one','two'],0,'one',now()-interval '2 seconds',now()-interval '1 second'
    from spin_rooms r cross join generate_series(1,52) where r.code=$2`,[a.account.id,code]);
  let cursor=null,ids=[];
  do {const rows=await rpc('spin_get_history',{p_room_code:code,p_account_token:b.token,p_before_id:cursor});ids.push(...rows.map(r=>r.id));cursor=rows.length===25?rows.at(-1).id:null;} while(cursor);
  assert.equal(ids.length,55);assert.equal(new Set(ids).size,55);checks++;
  await deny('spin_create_room',{p_account_token:a.token,p_title:'duplicates',p_mode:'shared',p_options:['x','x']},/unique/);
  await deny('spin_create_room',{p_account_token:a.token,p_title:'empty',p_mode:'shared',p_options:['x',' ']},/1 to 60/);
  // Anonymous DB clients cannot read base tables or call internal helpers directly.
  await assert.rejects(db.transaction(async tx=>{await tx.exec('set local role anon');await tx.query('select * from spin_draws');}),/permission denied/);checks++;
  await assert.rejects(rpc('spin_validate_options',{p_options:['x','y']}),/permission denied/);checks++;
  // Re-applying the full upgrade preserves users, old anonymous records, and all draws.
  await db.exec(schema);await db.exec(schema);
  const persisted=await db.query('select count(*)::int as n from spin_draws');assert.equal(persisted.rows[0].n,55);
  const legacy=await db.query('select account_id from qa_players where id=$1',[legacyId]);assert.equal(legacy.rows[0].account_id,b.account.id);checks++;
}
async function accountChecks() {
  const suffix=Date.now().toString().slice(-8), registration={p_username:'profile_'+suffix,p_password:'testing123',p_display_name:'小满',p_security_question:2,p_security_answer:'  蓝色列车Train7  '};
  const a=await rpc('account_register',registration), b=await rpc('account_register',{...registration,p_username:'friend_'+suffix});
  assert.equal(a.account.displayName,b.account.displayName);assert.notEqual(a.account.id,b.account.id);checks++;
  await deny('account_register',registration,/already exists/);
  await deny('account_register',{...registration,p_username:'empty_'+suffix,p_display_name:' '},/display name/);
  await deny('account_register',{...registration,p_username:'empty_'+suffix,p_security_answer:' '},/security answer/);
  await deny('account_register',{p_username:'bypass_'+suffix,p_password:'testing123'},/does not exist/);
  const question=await rpc('account_recovery_question',{p_username:registration.p_username});assert.deepEqual(question,{questionId:2});checks++;
  const record=(await db.query('select security_answer_hash,password_hash from game_accounts where id=$1',[a.account.id])).rows[0];
  assert(!Object.values(record).some(v=>v.includes('蓝色列车Train7')||v.includes('testing123')));checks++;
  // The server derives game names from the account, even if a caller supplies another nickname.
  const qa=await rpc('qa_create_room',{p_questions:['名字测试'],p_account_token:a.token});
  const joined=await rpc('qa_join_room',{p_room_code:qa.room.code,p_nickname:'伪造昵称',p_player_key:randomUUID(),p_account_token:a.token});
  assert.equal(joined.players[0].nickname,'小满');checks++;
  await rpc('qa_submit_player',{p_room_code:qa.room.code,p_player_id:joined.currentPlayerId,p_player_key:'',p_answers:{1:'你好'},p_account_token:a.token});
  const tycoon=await rpc('tycoon_create_room',{p_nickname:'伪造昵称',p_player_key:randomUUID(),p_account_token:a.token});
  assert.equal(tycoon.players[0].nickname,'小满');checks++;
  const spin=await rpc('spin_create_room',{p_title:'名字测试',p_options:['一','二'],p_mode:'individual',p_account_token:a.token});
  const draw=await rpc('spin_draw',{p_room_code:spin.room.code,p_request_id:randomUUID(),p_account_token:a.token});
  await rpc('account_update_profile',{p_account_token:a.token,p_display_name:'新名字'});
  const qaAfter=await rpc('qa_get_room',{p_room_code:qa.room.code,p_account_token:a.token});
  assert.equal(qaAfter.players[0].nickname,'新名字');assert.equal(qaAfter.players[0].submittedName,'小满');checks++;
  const tAfter=await rpc('tycoon_get_room',{p_room_code:tycoon.room.code,p_account_token:a.token});
  assert.equal(tAfter.players[0].nickname,'新名字');assert(tAfter.logs.some(l=>JSON.stringify(l).includes('小满')));checks++;
  const sAfter=await rpc('spin_get_room',{p_room_code:spin.room.code,p_account_token:a.token});
  assert.deepEqual(sAfter.members,['新名字']);assert.equal(sAfter.history[0].actor,'小满');checks++;
  assert(!JSON.stringify([qaAfter,tAfter,sAfter]).includes(registration.p_username));checks++;
  const otherDevice=await rpc('account_login',{p_username:registration.p_username,p_password:registration.p_password});
  assert.equal(otherDevice.account.displayName,'新名字');checks++;
  // Failed attempts persist across separate RPC transactions and block even a correct answer.
  for(let i=0;i<5;i++){const r=await rpc('account_verify_recovery',{p_username:registration.p_username,p_answer:'wrong'});assert.equal(r.ok,false);}
  let verified=await rpc('account_verify_recovery',{p_username:registration.p_username,p_answer:'蓝色列车train7'});
  assert.equal(verified.ok,false);assert.match(verified.error,/blocked/);checks++;
  await rpc('account_login',{p_username:registration.p_username,p_password:registration.p_password});checks++;
  await db.query("update game_accounts set recovery_blocked_until=now()-interval '1 second',recovery_window_started_at=now()-interval '16 minutes' where id=$1",[a.account.id]);
  verified=await rpc('account_verify_recovery',{p_username:registration.p_username,p_answer:'  蓝色列车TRAIN7 '});assert(verified.ok);checks++;
  const stored=(await db.query('select token_hash from game_account_recoveries where account_id=$1',[a.account.id])).rows[0];assert.notEqual(stored.token_hash,verified.resetToken);checks++;
  await db.query("update game_account_recoveries set expires_at=now()-interval '1 second' where account_id=$1",[a.account.id]);
  let reset=await rpc('account_reset_password',{p_reset_token:verified.resetToken,p_password:'newPassword123'});assert.equal(reset.ok,false);checks++;
  const first=await rpc('account_verify_recovery',{p_username:registration.p_username,p_answer:'蓝色列车Train7'});
  const second=await rpc('account_verify_recovery',{p_username:registration.p_username,p_answer:'蓝色列车Train7'});
  reset=await rpc('account_reset_password',{p_reset_token:first.resetToken,p_password:'newPassword123'});assert.equal(reset.ok,false);checks++;
  reset=await rpc('account_reset_password',{p_reset_token:second.resetToken,p_password:'newPassword123'});assert(reset.ok);checks++;
  reset=await rpc('account_reset_password',{p_reset_token:second.resetToken,p_password:'anotherPassword'});assert.equal(reset.ok,false);checks++;
  await deny('account_login',{p_username:registration.p_username,p_password:registration.p_password},/Invalid username or password/);
  for(const token of[a.token,otherDevice.token]) await deny('account_refresh',{p_account_token:token},/Login required/);
  const relogin=await rpc('account_login',{p_username:registration.p_username,p_password:'newPassword123'});assert.equal(relogin.account.id,a.account.id);checks++;
  await assert.rejects(db.transaction(async tx=>{await tx.exec('set local role anon');await tx.query('select * from game_account_recoveries');}),/permission denied/);checks++;
}

(async()=>{
 const suffix=Date.now().toString().slice(-7);
 const a=await rpc('account_register',{p_username:'甲'+suffix,p_password:'testing123',p_display_name:'甲玩家',p_security_question:1,p_security_answer:'answer'}),b=await rpc('account_register',{p_username:'乙'+suffix,p_password:'testing123',p_display_name:'乙玩家',p_security_question:1,p_security_answer:'answer'}),c=await rpc('account_register',{p_username:'丙'+suffix,p_password:'testing123',p_display_name:'丙玩家',p_security_question:1,p_security_answer:'answer'});
 await deny('qa_create_room',{p_questions:['一','二']},/Login required/);
 await deny('tycoon_create_room',{p_nickname:'无账号',p_player_key:randomUUID()},/Login required/);
 await deny('spin_create_room',{p_title:'无账号',p_options:['a','b'],p_mode:'shared',p_account_token:''},/Login required/);
 const q=await rpc('qa_create_room',{p_questions:['一','二'],p_account_token:a.token});
 const qa=await rpc('qa_join_room',{p_room_code:q.room.code,p_nickname:'甲',p_player_key:'legacy-key',p_account_token:a.token});
 await deny('qa_save_answer',{p_room_code:q.room.code,p_player_id:qa.currentPlayerId,p_player_key:'legacy-key',p_question_index:1,p_content:'越权',p_account_token:b.token},/Player not found/);
 const room=await rpc('spin_create_room',{p_title:'今天吃什么',p_options:['火锅','烧烤','日料'],p_mode:'shared',p_account_token:a.token});const code=room.room.code;
 let outsiders=await rpc('spin_get_room',{p_room_code:code,p_account_token:c.token});assert.equal(outsiders.isMember,false);assert.equal(outsiders.history,undefined);checks++;
 await rpc('spin_join_room',{p_room_code:code,p_account_token:b.token});
 await deny('spin_get_history',{p_room_code:code,p_account_token:c.token},/membership/);
 await deny('spin_update_room',{p_room_code:code,p_title:'更改',p_options:['x','y'],p_mode:'individual',p_version:1,p_account_token:b.token},/Only host/);
 const request=randomUUID();const first=await rpc('spin_draw',{p_room_code:code,p_request_id:request,p_account_token:a.token});
 const retried=await rpc('spin_draw',{p_room_code:code,p_request_id:request,p_account_token:a.token});assert.equal(first.draw.id,retried.draw.id);checks++;
 await deny('spin_draw',{p_room_code:code,p_request_id:randomUUID(),p_account_token:b.token},/progress/);
 await deny('spin_update_room',{p_room_code:code,p_title:'更改',p_options:['x','y'],p_mode:'individual',p_version:1,p_account_token:a.token},/progress/);
 let shared=await rpc('spin_get_room',{p_room_code:code,p_account_token:b.token});assert.equal(shared.lastShared.id,first.draw.id);assert.deepEqual(first.draw.options,['火锅','烧烤','日料']);checks++;
 await sql("update spin_draws set ends_at=now()-interval '1 second'");
 await rpc('spin_update_room',{p_room_code:code,p_title:'见面玩什么',p_options:['桌游','电影'],p_mode:'individual',p_version:1,p_account_token:a.token});
 await deny('spin_update_room',{p_room_code:code,p_title:'旧配置',p_options:['x','y'],p_mode:'individual',p_version:1,p_account_token:a.token},/Room changed/);
 let [pa,pb]=await Promise.all([rpc('spin_draw',{p_room_code:code,p_request_id:randomUUID(),p_account_token:a.token}),rpc('spin_draw',{p_room_code:code,p_request_id:randomUUID(),p_account_token:b.token})]);assert.notEqual(pa.draw.id,pb.draw.id);checks++;
 let history=await rpc('spin_get_history',{p_room_code:code,p_account_token:b.token});assert.equal(history.length,3);assert(history.some(d=>d.actor===a.account.displayName));assert.deepEqual(history[2].options,['火锅','烧烤','日料']);checks++;
 let records=await rpc('account_get_records',{p_account_token:b.token});assert(records.spin.some(r=>r.roomCode===code));checks++;
 const renewed=await rpc('account_refresh',{p_account_token:a.token});assert.equal(renewed.token,a.token);assert(Date.parse(renewed.expiresAt)>Date.now()+89*86400000);checks++;
 await rpc('account_logout',{p_account_token:c.token});await deny('account_refresh',{p_account_token:c.token},/Login required/);
 await extraChecks(a,b,c,code,q.room.code,qa.currentPlayerId);
 await accountChecks();
 console.log('Database checks passed:',checks,JSON.stringify({code,qa:q.room.code}));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>db.close());
