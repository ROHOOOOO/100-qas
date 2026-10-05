// Create actual first-release data, then upgrade the same database and finish its pending vote.
import assert from 'node:assert/strict';import {createRequire} from 'node:module';import {readFileSync} from 'node:fs';import {randomUUID} from 'node:crypto';
const require=createRequire(import.meta.url),R=require('../src/board/rules.js');require('../src/board/chess.js');require('../src/board/race.js');require('../src/board/local.js');
const modulePath=process.env.PGLITE_MODULE_PATH||'@electric-sql/pglite',{PGlite}=require(modulePath),{pgcrypto}=createRequire(require.resolve(modulePath))('@electric-sql/pglite/contrib/pgcrypto');
const schema=readFileSync('supabase/schema.sql','utf8'),marker='-- International chess';const index=schema.indexOf(marker);assert(index>0,'migration boundary');
const old=schema.slice(0,index)+'\ncommit;';const db=new PGlite({extensions:{pgcrypto}});
async function rpc(name,p){const keys=Object.keys(p);return (await db.query(`select ${name}(${keys.map((k,i)=>k+' => $'+(i+1)).join(',')}) v`,keys.map(k=>k==='p_data'?JSON.stringify(p[k]):p[k]))).rows[0].v;}
try{
 await db.exec('create role anon;create role authenticated;create schema extensions;create extension pgcrypto with schema extensions;');await db.exec(old);
 const accounts=[];for(let i=0;i<2;i++)accounts.push(await rpc('account_register',{p_username:'old_'+i,p_password:'testing123',p_display_name:'旧棋友'+i,p_security_question:1,p_security_answer:'答案'}));
 let b=await rpc('board_create_room',{p_kind:'gomoku',p_title:'升级前棋房',p_account_token:accounts[0].token});
 async function act(i,action,data={}){b=await rpc('board_action',{p_room_code:b.room.code,p_action:action,p_data:data,p_revision:b.room.revision,p_request_id:randomUUID(),p_account_token:accounts[i].token});}
 await act(1,'join');await act(0,'ready',{ready:true});await act(1,'ready',{ready:true});await act(0,'start');const first=b.match.players[0].side===1?0:1;await act(first,'move',{move:{to:112}});await act(first,'undo');assert.equal(b.match.pending.required,undefined);
 const id=b.match.id,code=b.room.code,local={accounts:accounts.map(a=>a.account),boardRooms:{[code]:{...b.room,ownerId:accounts[0].account.id,guestId:accounts[1].account.id,hostSeen:new Date().toISOString(),guestSeen:new Date().toISOString(),requests:[],matchId:id}},boardMatches:{[id]:structuredClone(b.match)}};
 const localResult=globalThis.BoardLocal.run(local,'board_action',{p_room_code:code,p_action:'reply',p_data:{accept:true},p_revision:b.room.revision,p_request_id:randomUUID()},local.accounts[1-first]);assert.equal(localResult.match.state.moves.length,0);
 await db.exec(schema);await act(1-first,'reply',{accept:true});assert.equal(b.match.id,id);assert.equal(b.match.state.moves.length,0);assert.equal(b.room.members.length,2);assert.equal(b.match.events.at(-1).count,1);assert.equal(b.match.events[0].state,undefined);assert.equal(b.match.events.at(-1).state.kind,'gomoku');
 const before=b.match.events;await db.exec(schema);b=await rpc('board_get_room',{p_room_code:code,p_account_token:accounts[0].token});assert.deepEqual(b.match.events,before);console.log('First-release upgrade passed: pending vote, seats, saved replay and idempotent migration.');
}catch(e){console.error(e.message,e.where||'');process.exitCode=1;}finally{await db.close();}
