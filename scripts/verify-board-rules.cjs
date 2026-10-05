// Pure rules and bounded AI checks. No browser, network or persisted user data.
const assert = require('node:assert/strict');
const R = require('../src/board/rules.js');
const AI = require('../src/board/ai.js');
let checks = 0;
const fixtures = [];
function check(label, fn) { fn(); checks++; }
function position(kind, pieces, turn = 1) {
  const state = R.initial(kind); state.board.fill(0);
  for (const [index, piece] of pieces) state.board[index] = piece;
  state.turn = turn; state.positions = [{key:R.key(state.board,turn),actor:0,check:false}];
  return state;
}
function playCase(label, state, move, result) {
  check(label, () => assert.deepEqual(R.play(state,move).result,result));
  fixtures.push({label,state,move});
}
check('initial armies and legal opening', () => {
  assert.equal(R.initial('xiangqi').board.filter(Boolean).length,32);
  assert.equal(R.moves('xiangqi',R.initial('xiangqi').board,1).length,44);
  assert.equal(R.moves('gomoku',R.initial('gomoku').board,1).length,225);
});
for (const [name,indices,to] of [
  ['horizontal',[106,107,108,109],110],['vertical',[37,52,67,82],97],
  ['diagonal',[32,48,64,80],96],['antidiagonal',[42,56,70,84],98],
  ['overline',[105,106,108,109,110],107]]) {
  playCase(name,position('gomoku',indices.map(i=>[i,1])),{to},{winner:1,reason:'five'});
}
check('no row wrapping', () => assert.equal(R.play(position('gomoku',[[13,1],[14,1],[15,1],[16,1]]),{to:17}).result,null));
check('invalid and occupied coordinates',()=>{
  let s=R.play(R.initial('gomoku'),{to:112});
  for(const to of [-1,225,2.2,'3',null,112])assert.throws(()=>R.play(s,{to}),/Illegal/);
  assert.throws(()=>R.play({...s,result:{winner:1}},{to:0}),/Illegal/);
});
const full=R.initial('gomoku');for(let i=0;i<225;i++)full.board[i]=((i%15+2*Math.floor(i/15))%4<2)?1:-1;full.turn=full.board[224];full.board[224]=0;
playCase('full board draw',full,{to:224},{winner:0,reason:'full'});
check('horse leg and elephant eye / river',()=>{
  const b=position('xiangqi',[[85,1],[4,-1],[49,7],[82,4],[83,3]]).board;
  assert(R.pseudo(b,82,65));b[73]=7;assert(!R.pseudo(b,82,65));
  b[73]=0;assert(R.pseudo(b,83,63));b[73]=7;assert(!R.pseudo(b,83,63));
  b[83]=0;b[47]=3;assert(!R.pseudo(b,47,31));
});
check('cannon screens and captures',()=>{
  const b=position('xiangqi',[[45,6],[48,7],[51,-5]]).board;
  assert(R.pseudo(b,45,51));assert(!R.pseudo(b,45,50));b[48]=0;assert(!R.pseudo(b,45,51));
  assert(R.pseudo(b,45,50));b[48]=7;b[49]=-7;assert(!R.pseudo(b,45,51));
});
check('pawn direction, river, palace',()=>{
  const b=position('xiangqi',[[54,7],[27,-7],[85,1],[4,-1],[84,2]]).board;
  assert(R.pseudo(b,54,45));assert(!R.pseudo(b,54,55));assert(!R.pseudo(b,54,63));
  b[36]=7;assert(R.pseudo(b,36,37));assert(!R.pseudo(b,36,45));
  assert(R.pseudo(b,27,36));assert(!R.pseudo(b,27,28));b[54]=-7;assert(R.pseudo(b,54,55));
  assert(R.pseudo(b,84,76));assert(!R.pseudo(b,84,74));assert(!R.pseudo(b,85,83));
});
check('facing generals and pinned shield',()=>{
  const s=position('xiangqi',[[85,1],[4,-1],[49,5]]);
  assert(!R.checked(s.board,1));assert(!R.legal(s.kind,s.board,1,{from:49,to:48}));
  s.board[49]=0;assert(R.checked(s.board,1));assert(R.checked(s.board,-1));
  assert(!R.legal(s.kind,s.board,1,{from:85,to:4}));
});
playCase('checkmate',position('xiangqi',[[85,1],[4,-1],[49,7],[12,5],[14,5],[21,5]]),{from:21,to:22},{winner:1,reason:'checkmate'});
playCase('stalemate loses',position('xiangqi',[[85,1],[4,-1],[49,7],[21,5],[23,5]]),{from:23,to:14},{winner:1,reason:'stalemate'});
function sequence(label,state,moves,result){for(const move of moves){fixtures.push({label,state,move});state=R.play(state,move);}check(label,()=>assert.deepEqual(state.result,result));return state;}
const cycle=[{from:82,to:65},{from:1,to:20},{from:65,to:82},{from:20,to:1}];
sequence('third repeated position draws',R.initial('xiangqi'),[...cycle,...cycle],{winner:0,reason:'repetition'});
const perpetual=position('xiangqi',[[85,1],[4,-1],[49,7],[21,5]]);
const checksCycle=[{from:21,to:22},{from:4,to:3},{from:22,to:21},{from:3,to:4}];
sequence('one-sided perpetual check loses',perpetual,[...checksCycle,...checksCycle],{winner:-1,reason:'perpetual-check'});
check('undo one/two plies and reset repetition state',()=>{
  let s=R.initial('xiangqi');for(const m of cycle.slice(0,3))s=R.play(s,m);
  let n=R.undo(s,1);assert.equal(n.moves.length,2);assert.equal(n.turn,1);assert.equal(n.positions.length,3);
  n=R.undo(s,-1);assert.equal(n.moves.length,1);assert.equal(n.turn,-1);assert.deepEqual(n.board,R.play(R.initial('xiangqi'),cycle[0]).board);
  assert.throws(()=>R.undo(R.initial('gomoku'),1),/Nothing/);
});
const aiReport=[];
for(const kind of ['gomoku','xiangqi'])for(const level of ['easy','normal','hard']){
  check(kind+' '+level+' legal bounded opening',()=>{
    const s=R.initial(kind),start=Date.now(),answer=AI.choose(s,level);
    assert(R.legal(kind,s.board,s.turn,answer.move));assert(Date.now()-start<6000);
    aiReport.push({kind,level,depth:answer.depth,nodes:answer.nodes,ms:Date.now()-start});
  });
}
for(const level of ['easy','normal','hard']){
  check(level+' takes immediate five',()=>{const s=position('gomoku',[[105,-1],[106,1],[107,1],[108,1],[109,1]]);assert.equal(AI.choose(s,level).move.to,110);});
  check(level+' takes xiangqi mate',()=>{const s=fixtures.find(f=>f.label==='checkmate').state;assert.equal(R.play(s,AI.choose(s,level).move).result?.winner,1);});
}
for(const level of ['normal','hard'])check(level+' prevents immediate loss',()=>{
  const s=position('gomoku',[[105,1],[106,-1],[107,-1],[108,-1],[109,-1],[70,1],[71,1]]);
  assert.equal(AI.choose(s,level).move.to,110);
});
for(const level of ['normal','hard'])check(level+' avoids a poisoned cannon capture',()=>{
  const s=position('xiangqi',[[85,1],[4,-1],[49,7],[81,5],[0,-6],[2,-5]]);
  const move=AI.choose(s,level).move;assert(!(move.from===81&&move.to===0));
});
console.log(JSON.stringify({checks,aiReport},null,2));
module.exports={fixtures,position};
