/* Shared by the board UI, offline backend, AI worker, and rule tests. */
(function (root) {
  'use strict';
  const side = p => Math.sign(p), type = p => Math.abs(p);
  const clone = value => JSON.parse(JSON.stringify(value));
  function initial(kind) {
    if (!['gomoku','xiangqi'].includes(kind)) throw new Error('Invalid game.');
    const board = Array(kind === 'gomoku' ? 225 : 90).fill(0);
    if (kind === 'xiangqi') {
      const row = [5,4,3,2,1,2,3,4,5];
      for(let x=0;x<9;x++){board[x]=-row[x];board[81+x]=row[x];}
      for(const x of [1,7]){board[18+x]=-6;board[63+x]=6;}
      for(const x of [0,2,4,6,8]){board[27+x]=-7;board[54+x]=7;}
    }
    return {kind,board,turn:1,moves:[],positions:[{key:key(board,1),actor:0,check:false}],result:null};
  }
  const key = (board,turn) => board.join(',')+':'+turn;
  function pseudo(board,from,to) {
    if(!Number.isInteger(from)||!Number.isInteger(to)||from<0||from>=90||to<0||to>=90||from===to) return false;
    const p=board[from], s=side(p);if(!s||side(board[to])===s)return false;
    const x=from%9,y=Math.floor(from/9),tx=to%9,ty=Math.floor(to/9),dx=tx-x,dy=ty-y;
    const palace=tx>=3&&tx<=5&&(s===1?ty>=7:ty<=2);
    let blocks=0;
    if(dx===0||dy===0){const step=dx===0?Math.sign(dy)*9:Math.sign(dx);for(let i=from+step;i!==to;i+=step)if(board[i])blocks++;}
    switch(type(p)){
      case 1:return (type(board[to])===1&&dx===0&&blocks===0)||(palace&&Math.abs(dx)+Math.abs(dy)===1);
      case 2:return palace&&Math.abs(dx)===1&&Math.abs(dy)===1;
      case 3:return Math.abs(dx)===2&&Math.abs(dy)===2&&(s===1?ty>=5:ty<=4)&&!board[from+dy/2*9+dx/2];
      case 4:return (Math.abs(dx)===2&&Math.abs(dy)===1&&!board[from+Math.sign(dx)])||(Math.abs(dx)===1&&Math.abs(dy)===2&&!board[from+Math.sign(dy)*9]);
      case 5:return (dx===0||dy===0)&&blocks===0;
      case 6:return (dx===0||dy===0)&&blocks===(board[to]?1:0);
      case 7:return (dx===0&&dy===-s)||((s===1?y<=4:y>=5)&&dy===0&&Math.abs(dx)===1);
      default:return false;
    }
  }
  function checked(board,s) {
    const king=board.indexOf(s);if(king<0)return true;
    for(let i=0;i<90;i++)if(side(board[i])===-s&&pseudo(board,i,king))return true;
    return false;
  }
  function legal(kind,board,s,move) {
    if(!move||!Number.isInteger(move.to)||move.to<0||move.to>=board.length)return false;
    if(kind==='gomoku')return !board[move.to];
    if(side(board[move.from])!==s||type(board[move.to])===1||!pseudo(board,move.from,move.to))return false;
    const next=board.slice();next[move.to]=next[move.from];next[move.from]=0;return !checked(next,s);
  }
  function moves(kind,board,s) {
    const result=[];
    if(kind==='gomoku'){for(let i=0;i<225;i++)if(!board[i])result.push({to:i});return result;}
    for(let from=0;from<90;from++)if(side(board[from])===s)for(let to=0;to<90;to++)if(legal(kind,board,s,{from,to}))result.push({from,to});
    return result;
  }
  function line(board,to,s) {
    const x=to%15,y=Math.floor(to/15);
    for(const [dx,dy] of [[1,0],[0,1],[1,1],[1,-1]]){
      let count=1;for(const dir of [-1,1]){let a=x+dx*dir,b=y+dy*dir;while(a>=0&&a<15&&b>=0&&b<15&&board[b*15+a]===s){count++;a+=dx*dir;b+=dy*dir;}}
      if(count>=5)return true;
    }return false;
  }
  function play(state,move) {
    if(state.result||!legal(state.kind,state.board,state.turn,move))throw new Error('Illegal move.');
    const next=clone(state),s=state.turn,b=next.board;
    const entry={from:state.kind==='gomoku'?-1:move.from,to:move.to,side:s,piece:state.kind==='gomoku'?s:b[move.from],captured:b[move.to]};
    if(entry.from>=0)b[entry.from]=0;b[entry.to]=entry.piece;
    next.moves.push(entry);next.turn=-s;
    next.positions.push({key:key(b,-s),actor:s,check:state.kind==='xiangqi'&&checked(b,-s)});
    if(state.kind==='gomoku'){
      if(line(b,move.to,s))next.result={winner:s,reason:'five'};
      else if(b.every(Boolean))next.result={winner:0,reason:'full'};
    }else{
      if(!moves('xiangqi',b,-s).length)next.result={winner:s,reason:checked(b,-s)?'checkmate':'stalemate'};
      else {
        const current=next.positions.at(-1).key, occurrences=[];
        next.positions.forEach((p,i)=>{if(p.key===current)occurrences.push(i);});
        if(occurrences.length>=3){
          const loop=next.positions.slice(occurrences.at(-3)+1);
          const alwaysCheck=who=>loop.filter(p=>p.actor===who).every(p=>p.check);
          const red=alwaysCheck(1),black=alwaysCheck(-1);
          next.result={winner:red!==black?(red?-1:1):0,reason:red!==black?'perpetual-check':'repetition'};
        }
      }
    }
    return next;
  }
  function undo(state,s) {
    if(state.result)throw new Error('Game ended.');
    let index=state.moves.length-1;while(index>=0&&state.moves[index].side!==s)index--;
    if(index<0)throw new Error('Nothing to undo.');
    const next=clone(state);next.board=initial(state.kind).board;
    next.moves=next.moves.slice(0,index);next.positions=next.positions.slice(0,index+1);next.turn=s;next.result=null;
    for(const m of next.moves){if(m.from>=0)next.board[m.from]=0;next.board[m.to]=m.piece;}
    return next;
  }
  const api={initial,legal,moves,checked,play,undo,key,line,pseudo};
  root.BoardRules=api;if(typeof module!=='undefined')module.exports=api;
})(globalThis);
