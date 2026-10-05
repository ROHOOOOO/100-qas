/* Search policies for the three additional games. Dice never enter this policy as a choice. */
(function(root){
 'use strict';const R=root.BoardRules,C=root.BoardChess,G=root.BoardRace,base=root.BoardAI.choose,values=[0,20000,900,500,330,320,100];
 const hash=s=>s.board.reduce((a,p,i)=>(Math.imul(a^((p+10)*(i+1)),16777619)>>>0),2166136261);
 function chessValue(s,side){return s.board.reduce((sum,p,i)=>{const who=Math.sign(p),type=Math.abs(p);if(!p)return sum;const center=7-Math.abs(i%8-3.5)-Math.abs((i>>3)-3.5);return sum+side*who*(values[type]+(type===6?(who===1?6-(i>>3):(i>>3)-1)*9:type===4||type===5?center*6:0));},0);}
 function chess(state,level){
  const cfg={easy:{depth:1,nodes:150,ms:120,width:6},normal:{depth:2,nodes:2000,ms:450,width:14},hard:{depth:4,nodes:12000,ms:1400,width:20}}[level];
  const deadline=Date.now()+cfg.ms;let nodes=0,depthDone=0;const side=state.turn;
  const ranked=s=>C.moves(s).map(move=>{const n=C.apply(s,move);return {move,n,score:chessValue(n,s.turn)+values[Math.abs(s.board[move.to])]*2+(C.checked(n)?45:0)};}).sort((a,b)=>b.score-a.score);
  const options=ranked(state);if(!options.length)return null;
  for(const o of options){const result=C.play(state,o.move).result;if(result?.winner===side)return {move:o.move,nodes:1,depth:1};}
  if(level==='easy')return {move:options[hash(state)%Math.min(4,options.length)].move,nodes:options.length,depth:1};
  const STOP={};
  function search(s,depth,alpha,beta){if(++nodes>cfg.nodes||Date.now()>deadline)throw STOP;let list;
   if(!depth){if(C.checked(s)&&!C.moves(s).length)return -1000000;return chessValue(s,s.turn);}
   list=ranked(s);if(!list.length)return C.checked(s)?-1000000-depth*100:0;
   let best=-Infinity;for(const o of list.slice(0,cfg.width)){const score=-search(o.n,depth-1,-beta,-alpha);best=Math.max(best,score);alpha=Math.max(alpha,score);if(alpha>=beta)break;}return best;
  }
  let move=options[0].move;for(let depth=1;depth<=cfg.depth;depth++){let score=-Infinity,next=move;try{
   for(const o of options.slice(0,cfg.width)){const end=C.play(state,o.move).result,value=end?(end.winner===side?1000000:end.winner===-side?-1000000:0):-search(o.n,depth-1,-Infinity,-score);if(value>score){score=value;next=o.move;}}
   move=next;depthDone=depth;
  }catch(e){if(e!==STOP)throw e;break;}}
  return {move,nodes,depth:depthDone};
 }
 const distance=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[0]+a[1]-b[0]-b[1]));
 // Minimum-cost one-to-one assignment avoids chasing a target hole already needed by another piece.
 function assignment(board,side,count){
  const pieces=[];board.forEach((p,i)=>{if(p===side)pieces.push(i);});const targets=G.camps[(G.campOrder[count][side-1]+3)%6],n=pieces.length;
  const u=Array(n+1).fill(0),v=Array(n+1).fill(0),p=Array(n+1).fill(0),way=Array(n+1).fill(0);
  for(let i=1;i<=n;i++){p[0]=i;let j0=0;const min=Array(n+1).fill(Infinity),used=Array(n+1).fill(false);
   do{used[j0]=true;const i0=p[j0];let delta=Infinity,j1=0;for(let j=1;j<=n;j++)if(!used[j]){const cur=distance(G.points[pieces[i0-1]],G.points[targets[j-1]])-u[i0]-v[j];if(cur<min[j]){min[j]=cur;way[j]=j0;}if(min[j]<delta){delta=min[j];j1=j;}}
    for(let j=0;j<=n;j++){if(used[j]){u[p[j]]+=delta;v[j]-=delta;}else min[j]-=delta;}j0=j1;
   }while(p[j0]!==0);
   do{const j1=way[j0];p[j0]=p[j1];j0=j1;}while(j0!==0);
  }return -v[0];
 }
 function halma(s,level){const moves=G.halmaMoves(s);if(!moves.length)return {move:{pass:true},nodes:1,depth:1};const who=s.turn,targets=G.camps[(G.campOrder[s.count][who-1]+3)%6];let nodes=0;
  const ownKey=b=>b.map((p,i)=>p===who?i:-1).filter(i=>i>=0).join(',');
  const previous=s.moves.filter(m=>m.side===who&&m.before).slice(-48).map(m=>ownKey(m.before.board));
  const home=new Set(G.camps[G.campOrder[s.count][who-1]]);
  const scoreMove=(board,m)=>{const b=board.slice();b[m.path[0]]=0;b[m.path.at(-1)]=who;nodes++;let score=-assignment(b,who,s.count)*100+targets.filter(t=>b[t]===who).length*5;for(let i=0;i<b.length;i++)if(b[i]===who){const d=Math.min(...targets.map(t=>distance(G.points[i],G.points[t])));score-=d*d*5+(home.has(i)?180:0);}
   score-=previous.filter(k=>k===ownKey(b)).length*350;return {move:m,b,score};};
  const options=moves.map(m=>scoreMove(s.board,m)).sort((a,b)=>b.score-a.score);
  if(level==='easy')return {move:options[hash(s)%Math.min(5,options.length)].move,nodes,depth:1};
  if(level==='hard'){
   const deadline=Date.now()+800;for(const option of options.slice(0,8)){
    const next={...s,board:option.b};let best=option.score;for(const move of G.halmaMoves(next)){const v=scoreMove(option.b,move).score;best=Math.max(best,v);if(Date.now()>deadline)break;}
    option.score=option.score*.65+best*.35;if(Date.now()>deadline)break;
   }options.sort((a,b)=>b.score-a.score);
  }
  return {move:options[0].move,nodes,depth:level==='hard'?2:1};
 }
 function flight(s,level){const options=G.flightMoves(s);if(!options.length)return null;if(level==='easy')return {move:options[hash(s)%options.length],nodes:options.length,depth:1};
  const ranked=options.map(move=>{const n=G.play(s,move),last=n.moves.at(-1),index=(s.turn-1)*4+move.token;let score=(last.to-Math.max(0,last.from))*2+last.captures.length*24+(last.to===57?110:0)+(last.from<0?16:0);
   if(level==='hard'){score+=last.to>=52?22:0;if(last.to<52){const target=((s.turn-1)*13+last.to)%52;for(let i=0;i<s.board.length;i++)if(Math.floor(i/4)+1!==s.turn&&s.board[i]>=0&&s.board[i]<52){const gap=(target-(Math.floor(i/4)*13+s.board[i])+52)%52;if(gap>=1&&gap<=6)score-=14;}}
    if(s.board.filter((p,i)=>Math.floor(i/4)+1===s.turn&&p>=0&&p<57).length===1&&last.from===-1)score+=12;
   }return {move,score};}).sort((a,b)=>b.score-a.score);return {move:ranked[0].move,nodes:options.length,depth:level==='hard'?2:1};
 }
 root.BoardAI.choose=(s,level,limits)=>{if(s.result)return null;if(!['easy','normal','hard'].includes(level))throw Error('Invalid difficulty.');return s.kind==='chess'?chess(s,level):s.kind==='halma'?halma(s,level):s.kind==='flight'?flight(s,level):base(s,level,limits);};root.BoardAI.assignment=assignment;
 if(typeof module!=='undefined')module.exports=root.BoardAI;
})(globalThis);
