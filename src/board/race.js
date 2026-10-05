/* Chinese checkers and aeroplane race. Pure transitions; dice are supplied by the backend. */
(function(root){
 'use strict';const copy=v=>JSON.parse(JSON.stringify(v));
 const directions=[[1,0],[-1,0],[0,1],[0,-1],[1,-1],[-1,1]],points=[],camps=Array.from({length:6},()=>[]);
 for(let r=-4;r<=4;r++)for(let q=-4;q<=4;q++)if(Math.abs(q+r)<=4)points.push([q,r]);
 for(let c=0;c<6;c++)for(let k=1;k<=4;k++)for(let a=k;a<=4;a++){let q=a,r=-4-k;for(let t=0;t<c;t++)[q,r]=[-r,q+r];camps[c].push(points.length);points.push([q,r]);}
 const pointIndex=new Map(points.map((p,i)=>[p.join(','),i])),at=(q,r)=>pointIndex.get(q+','+r);
 const campOrder={2:[0,3],3:[0,2,4],4:[0,1,3,4],6:[0,1,2,3,4,5]};
 const track=[[6,13],[6,12],[6,11],[6,10],[6,9],[5,8],[4,8],[3,8],[2,8],[1,8],[0,8],[0,7],[0,6],[1,6],[2,6],[3,6],[4,6],[5,6],[6,5],[6,4],[6,3],[6,2],[6,1],[6,0],[7,0],[8,0],[8,1],[8,2],[8,3],[8,4],[8,5],[9,6],[10,6],[11,6],[12,6],[13,6],[14,6],[14,7],[14,8],[13,8],[12,8],[11,8],[10,8],[9,8],[8,9],[8,10],[8,11],[8,12],[8,13],[8,14],[7,14],[6,14]];
 const home=(side,p)=>side===1?[7,13-p]:side===2?[1+p,7]:side===3?[7,1+p]:[13-p,7];
 const airports=[[[1,10],[3,10],[1,12],[3,12]],[[1,1],[3,1],[1,3],[3,3]],[[10,1],[12,1],[10,3],[12,3]],[[10,10],[12,10],[10,12],[12,12]]];
 function planePoint(side,token,progress){return progress<0?airports[side-1][token]:progress<52?track[((side-1)*13+progress)%52]:home(side,progress-52);}
 function initial(kind,count=2,turn=1){
  if(kind==='halma'?!campOrder[count]:kind!=='flight'||count<2||count>4)throw Error('Invalid seats.');
  const s={kind,count,board:Array(kind==='halma'?121:count*4).fill(kind==='halma'?0:-1),turn,turnSerial:0,rankings:[],dice:null,moves:[],positions:[],result:null};
  if(kind==='halma')campOrder[count].forEach((c,i)=>camps[c].forEach(p=>s.board[p]=i+1));return s;
 }
 function next(s){for(let i=1;i<=s.count;i++){const side=(s.turn-1+i)%s.count+1;if(!s.rankings.includes(side)){s.turn=side;s.turnSerial++;return;}}}
 function finish(s){const who=s.turn,done=s.kind==='flight'?s.board.slice((who-1)*4,who*4).every(p=>p===57):camps[(campOrder[s.count][who-1]+3)%6].every(p=>s.board[p]===who);
  if(done&&!s.rankings.includes(who))s.rankings.push(who);
  if(s.rankings.length===s.count-1){s.rankings.push(Array.from({length:s.count},(_,i)=>i+1).find(p=>!s.rankings.includes(p)));s.result={winner:s.rankings[0],reason:'ranked'};}
  return done;
 }
 function halmaLegal(s,m){
  const path=m?.path;if(!Array.isArray(path)||path.length<2||path.length>121||path.some(i=>!Number.isInteger(i)||i<0||i>=121)||new Set(path).size!==path.length||s.board[path[0]]!==s.turn)return false;
  const b=s.board.slice();let previous=path[0];b[previous]=0;
  for(let i=1;i<path.length;i++){const to=path[i];if(b[to])return false;const dx=points[to][0]-points[previous][0],dy=points[to][1]-points[previous][1];
   const step=directions.some(([x,y])=>dx===x&&dy===y),jump=directions.some(([x,y])=>dx===2*x&&dy===2*y&&b[at(points[previous][0]+x,points[previous][1]+y)]);
   if((step&&path.length!==2)||(!step&&!jump))return false;previous=to;
  }return true;
 }
 function halmaMoves(s){const out=[];for(let from=0;from<121;from++)if(s.board[from]===s.turn){
  const [q,r]=points[from];for(const [dx,dy]of directions){const to=at(q+dx,r+dy);if(to!=null&&!s.board[to])out.push({path:[from,to]});}
  const b=s.board.slice();b[from]=0;const seen=new Set([from]),queue=[[from]];
  for(let i=0;i<queue.length;i++){const path=queue[i],p=points[path.at(-1)];for(const [dx,dy] of directions){const mid=at(p[0]+dx,p[1]+dy),to=at(p[0]+2*dx,p[1]+2*dy);
   if(to!=null&&b[mid]&&!b[to]&&!seen.has(to)){seen.add(to);const nextPath=[...path,to];out.push({path:nextPath});queue.push(nextPath);}
  }}
 }return out;}
 function flightMoves(s){if(s.dice==null)return [];const out=[];for(let token=0;token<4;token++){const p=s.board[(s.turn-1)*4+token];if(p>=0&&p<57||p===-1&&s.dice===6)out.push({token});}return out;}
 function roll(state,value){if(state.result||state.kind!=='flight'||state.dice!=null||!Number.isInteger(value)||value<1||value>6)throw Error('Illegal roll.');const s=copy(state);s.dice=value;if(!flightMoves(s).length){s.dice=null;next(s);}return s;}
 function play(state,m){
  if(state.result)throw Error('Game ended.');const s=copy(state),who=s.turn,before={board:state.board.slice(),turn:who,rankings:state.rankings.slice(),turnSerial:state.turnSerial};let entry;
  if(s.kind==='halma'){
   if(m?.pass===true){if(halmaMoves(s).length)throw Error('Illegal move.');entry={side:who,pass:true,before};}
   else{if(!halmaLegal(s,m))throw Error('Illegal move.');const from=m.path[0],to=m.path.at(-1);s.board[from]=0;s.board[to]=who;entry={side:who,from,to,path:m.path.slice(),before};}
   finish(s);if(!s.result)next(s);
  }else{
   if(!flightMoves(s).some(a=>a.token===m?.token))throw Error('Illegal move.');const index=(who-1)*4+m.token,from=s.board[index],die=s.dice,stops=[];
   let to=from===-1?0:from+die;if(to>57)to=114-to;stops.push(to);
   if(from!==-1&&to<52){if(to===18){to=30;stops.push(to);}else if(to%4===2&&to+4<52){to+=4;stops.push(to);if(to===18){to=30;stops.push(to);}}}
   const captures=[];for(const stop of stops)if(stop<52){const global=((who-1)*13+stop)%52;for(let i=0;i<s.board.length;i++){const side=Math.floor(i/4)+1,p=s.board[i];if(side!==who&&p>=0&&p<52&&((side-1)*13+p)%52===global){s.board[i]=-1;captures.push(i);}}}
   s.board[index]=to;s.dice=null;entry={side:who,token:m.token,from,to,dice:die,stops,captures};const done=finish(s);if(!s.result&&(done||die!==6))next(s);
  }
  s.moves.push(entry);return s;
 }
 function undo(s,side){if(s.kind!=='halma')throw Error('Undo not available.');if(s.result)throw Error('Game ended.');const i=s.moves.findLastIndex(m=>m.side===side);if(i<0)throw Error('Nothing to undo.');return {...copy(s),...copy(s.moves[i].before),moves:copy(s.moves.slice(0,i)),result:null};}
 const api={initial,play,undo,roll,halmaLegal,halmaMoves,flightMoves,points,camps,campOrder,directions,at,track,airports,home,planePoint};root.BoardRace=api;if(typeof module!=='undefined')module.exports=api;
 const R=root.BoardRules;if(R){const base={...R};R.initial=(kind,count,turn)=>kind==='chess'?root.BoardChess.initial():['flight','halma'].includes(kind)?initial(kind,count,turn):base.initial(kind);
  R.list=s=>s.kind==='chess'?root.BoardChess.moves(s):s.kind==='halma'?halmaMoves(s):s.kind==='flight'?flightMoves(s):base.moves(s.kind,s.board,s.turn);
  R.valid=(s,m)=>s.kind==='chess'?root.BoardChess.legal(s,m):s.kind==='halma'?halmaLegal(s,m):s.kind==='flight'?flightMoves(s).some(a=>a.token===m?.token):base.legal(s.kind,s.board,s.turn,m);
  R.play=(s,m)=>s.kind==='chess'?root.BoardChess.play(s,m):['flight','halma'].includes(s.kind)?play(s,m):base.play(s,m);
  R.undo=(s,side)=>s.kind==='chess'?root.BoardChess.undo(s,side):s.kind==='halma'?undo(s,side):s.kind==='flight'?(()=>{throw Error('Undo not available.');})():base.undo(s,side);
  R.isCheck=(s,side=s.turn)=>s.kind==='chess'?root.BoardChess.checked(s,side):s.kind==='xiangqi'?base.checked(s.board,side):false;
 }
})(globalThis);
