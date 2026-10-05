// Pure rules, special-position fixtures and bounded computer policies for release two.
const assert=require('node:assert/strict');
const R=require('../src/board/rules.js'),C=require('../src/board/chess.js'),G=require('../src/board/race.js');
require('../src/board/ai.js');const AI=require('../src/board/ai-extra.js');
const fixtures=[];let checks=0;
const check=(label,fn)=>{try{fn();checks++;}catch(e){e.message=label+': '+e.message;throw e;}};
function position(pieces,turn=1){const s=C.initial();s.board.fill(0);s.castling=0;s.turn=turn;for(const [i,p] of pieces)s.board[i]=p;s.positions=[C.key(s)];return s;}
function transition(label,state,move,verify){const next=R.play(state,move);check(label,()=>verify(next));fixtures.push({label,state,move});return next;}
function perft(s,n){return n?C.moves(s).reduce((sum,m)=>sum+perft(C.apply(s,m),n-1),0):1;}
check('chess opening perft',()=>{assert.equal(perft(C.initial(),3),8902);});
let s=position([[60,1],[63,3],[56,3],[4,-1]]);s.castling=3;
transition('short castle moves both pieces',s,{from:60,to:62},n=>{assert.equal(n.board[61],3);assert.equal(n.board[62],1);assert.equal(n.castling,0);});
transition('long castle moves both pieces',s,{from:60,to:58},n=>assert.equal(n.board[59],3));
check('cannot castle through attack',()=>{const n=structuredClone(s);n.board[5]=-3;assert(!C.legal(n,{from:60,to:62}));});
let ep=position([[60,1],[4,-1],[28,6],[11,-6]],-1);ep=transition('double pawn move',ep,{from:11,to:27},n=>assert.equal(n.ep,19));
transition('en passant removes passed pawn',ep,{from:28,to:19},n=>{assert.equal(n.board[27],0);assert.equal(n.board[19],6);});
check('pinned en passant is illegal and absent from position key',()=>{const n=position([[60,1],[0,-1],[4,-3],[28,6],[27,-6]]);n.ep=19;assert(!C.legal(n,{from:28,to:19}));assert.equal(C.key(n),C.key({...n,ep:-1}));});
check('en passant expires',()=>{const n=C.play(C.play(ep,{from:60,to:59}),{from:4,to:3});assert(!C.legal(n,{from:28,to:19}));});
for(const promote of [2,3,4,5])transition('promotion '+promote,position([[60,1],[7,-1],[8,6]]),{from:8,to:0,promote},n=>assert.equal(n.board[0],promote));
check('promotion must be selected',()=>assert(!C.legal(position([[60,1],[7,-1],[8,6]]),{from:8,to:0})));
const mate=position([[18,1],[0,-1],[17,2]]);
transition('mate',mate,{from:17,to:9},n=>assert.deepEqual(n.result,{winner:1,reason:'checkmate'}));
transition('stalemate',position([[18,1],[0,-1],[17,2]]),{from:17,to:10},n=>assert.equal(n.result.reason,'stalemate-draw'));
let repetition=C.initial();for(let i=0;i<2;i++)for(const m of [{from:62,to:45},{from:6,to:21},{from:45,to:62},{from:21,to:6}]){fixtures.push({label:'repetition',state:repetition,move:m});repetition=C.play(repetition,m);}check('threefold',()=>assert.equal(repetition.result.reason,'repetition'));
s=position([[60,1],[4,-1],[56,3],[0,-3]]);s.halfmove=99;transition('50 move draw',s,{from:56,to:48},n=>assert.equal(n.result.reason,'fifty-moves'));
transition('insufficient material',position([[60,1],[4,-1],[12,4],[3,-5]]),{from:12,to:3},n=>assert.equal(n.result.reason,'insufficient'));
check('undo restores chess rights and clocks',()=>{const s=C.initial(),n=C.play(C.play(s,{from:52,to:36}),{from:12,to:28});assert.deepEqual(C.undo(n,1),s);});
check('star geometry',()=>{assert.equal(new Set(G.points.map(p=>p.join(','))).size,121);for(const c of G.camps)assert.equal(c.length,10);});
for(const n of [2,3,4,6])check('halma '+n+' seats',()=>{const s=G.initial('halma',n);assert.equal(s.board.filter(Boolean).length,n*10);assert(G.halmaMoves(s).every(m=>G.halmaLegal(s,m)));});
s=G.initial('halma',3);s.board.fill(0);s.board[G.at(0,0)]=1;s.board[G.at(1,0)]=2;s.board[G.at(3,0)]=3;
transition('chained jump',s,{path:[G.at(0,0),G.at(2,0),G.at(4,0)]},n=>{assert.equal(n.board[G.at(4,0)],1);assert.equal(n.board[G.at(1,0)],2);});
for(const path of [[G.at(0,0),G.at(2,0),G.at(0,0)],[G.at(0,0),G.at(0,1),G.at(0,2)],[G.at(0,0),G.at(-2,0)]])check('reject invalid halma path',()=>assert(!G.halmaLegal(s,{path})));
function halmaFinish(count,side=1){const s=G.initial('halma',count);s.board.fill(0);s.turn=side;for(let who=1;who<=count;who++)for(const id of G.camps[(G.campOrder[count][who-1]+3)%6])s.board[id]=who;const target=G.camps[(G.campOrder[count][side-1]+3)%6][0];const [q,r]=G.points[target];let from;for(const [dx,dy]of G.directions){const i=G.at(q+dx,r+dy);if(i!=null&&!s.board[i]){from=i;break;}}s.board[target]=0;s.board[from]=side;return {state:s,move:{path:[from,target]}};}
let f=halmaFinish(3),ranked=transition('halma first rank keeps playing',f.state,f.move,n=>{assert.deepEqual(n.rankings,[1]);assert.equal(n.result,null);assert.equal(n.turn,2);});
check('ranked pieces remain',()=>assert.equal(ranked.board.filter(p=>p===1).length,10));
check('undo restores ranking',()=>assert.deepEqual(G.undo(ranked,1),f.state));
f=halmaFinish(3,2);f.state.rankings=[1];transition('halma complete ranking',f.state,f.move,n=>{assert.deepEqual(n.rankings,[1,2,3]);assert.equal(n.result.reason,'ranked');});
s=G.initial('flight',4);check('no flight before six',()=>{assert.equal(G.roll(s,3).turn,2);assert.equal(G.roll(s,3).dice,null);});
s=G.roll(s,6);transition('takeoff and extra roll',s,{token:0},n=>{assert.equal(n.board[0],0);assert.equal(n.turn,1);assert.equal(n.dice,null);});
s=G.initial('flight',4);s.board[0]=8;s.dice=6;transition('jump then flight',s,{token:0},n=>assert.deepEqual(n.moves.at(-1).stops,[14,18,30]));
s=G.initial('flight',4);s.board[0]=16;s.board[4]=5;s.board[8]=4;s.dice=2;transition('shortcut endpoint captures',s,{token:0},n=>{assert.equal(n.board[0],30);assert.equal(n.board[4],-1);assert.equal(n.board[8],-1);});
s=G.initial('flight',3);s.board[0]=56;s.dice=4;transition('finish overshoot bounces',s,{token:0},n=>assert.equal(n.board[0],54));
s=G.initial('flight',3);s.board.splice(0,4,57,57,57,56);s.dice=1;ranked=transition('flight continues after rank',s,{token:3},n=>{assert.deepEqual(n.rankings,[1]);assert.equal(n.turn,2);});
s=structuredClone(ranked);s.board.splice(4,4,57,57,57,56);s.dice=1;transition('flight all ranks',s,{token:3},n=>assert.deepEqual(n.rankings,[1,2,3]));
check('flight cannot undo',()=>assert.throws(()=>R.undo(ranked,1),/Undo not available/));
const aiReport=[];
for(const kind of ['chess','halma','flight'])for(const level of ['easy','normal','hard']){const s=R.initial(kind,3);if(kind==='flight')s.dice=6;const start=Date.now(),a=AI.choose(s,level);check(kind+' '+level+' legal computer move',()=>{assert(R.valid(s,a.move));assert(Date.now()-start<6000);});aiReport.push({kind,level,ms:Date.now()-start,depth:a.depth,nodes:a.nodes});}
for(const level of ['easy','normal','hard'])check('chess mate '+level,()=>assert.equal(C.play(mate,AI.choose(mate,level).move).result?.winner,1));
for(const level of ['normal','hard']){s=G.initial('flight',3);s.board.splice(0,4,56,2,-1,-1);s.dice=1;check('flight prioritizes finish '+level,()=>assert.equal(AI.choose(s,level).move.token,0));f=halmaFinish(3);check('halma finishes '+level,()=>assert.deepEqual(G.play(f.state,AI.choose(f.state,level).move).rankings,[1]));}
const completedRaces=[];let seed=123;const die=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%6+1;};
for(const kind of ['flight','halma'])for(const level of ['easy','normal','hard'])for(const count of (kind==='flight'?[2,3,4]:[2,3,4,6])){
 let s=R.initial(kind,count),actions=0;
 for(;actions<1600&&!s.result;actions++){if(kind==='flight'){s=G.roll(s,die());if(s.dice==null)continue;}s=R.play(s,AI.choose(s,level).move);}
 check(kind+' '+level+' '+count+' full ranking',()=>{assert(s.result);assert.equal(new Set(s.rankings).size,count);});completedRaces.push({kind,level,count,actions});
}
console.log(JSON.stringify({expandedRuleChecks:checks,aiReport,completedRaces}));
module.exports={fixtures,halmaFinish,position};
