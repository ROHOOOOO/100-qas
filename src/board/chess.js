/* International chess: board indices a8=0, h1=63; white is +1. */
(function(root){
  'use strict';
  const clone=v=>JSON.parse(JSON.stringify(v)),sgn=Math.sign;
  const rookRight={0:8,7:4,56:2,63:1};
  function attacked(b,to,by){
    const tx=to%8,ty=to>>3;
    for(let f=0;f<64;f++)if(sgn(b[f])===by){
      const p=Math.abs(b[f]),dx=tx-f%8,dy=ty-(f>>3),ax=Math.abs(dx),ay=Math.abs(dy);
      if(p===1&&Math.max(ax,ay)===1)return true;
      if(p===5&&ax*ay===2)return true;
      if(p===6&&ax===1&&dy===-by)return true;
      if((p===2&&(ax===ay||dx===0||dy===0))||(p===3&&(dx===0||dy===0))||(p===4&&ax===ay)){
        if(!dx&&!dy)continue;const step=sgn(dx)+sgn(dy)*8;let i=f+step;while(i!==to&&!b[i])i+=step;if(i===to)return true;
      }
    }return false;
  }
  function checked(s,who=s.turn){const k=s.board.indexOf(who);return k<0||attacked(s.board,k,-who);}
  function apply(s,m){
    const n={...s,board:s.board.slice()},p=n.board[m.from],who=sgn(p),t=Math.abs(p),captured=n.board[m.to];
    n.board[m.from]=0;n.board[m.to]=m.promote?who*m.promote:p;
    if(t===6&&m.to===s.ep&&!captured&&m.from%8!==m.to%8)n.board[m.to+who*8]=0;
    if(t===1&&Math.abs(m.to-m.from)===2){const rf=m.to>m.from?m.from+3:m.from-4,rt=m.to>m.from?m.from+1:m.from-1;n.board[rt]=n.board[rf];n.board[rf]=0;}
    n.castling=s.castling;if(t===1)n.castling&=who===1?12:3;
    if(rookRight[m.from])n.castling&=~rookRight[m.from];if(rookRight[m.to])n.castling&=~rookRight[m.to];
    n.ep=t===6&&Math.abs(m.to-m.from)===16?(m.from+m.to)/2:-1;
    n.halfmove=t===6||captured?0:s.halfmove+1;n.turn=-who;return n;
  }
  function legal(s,m){
    if(!m||!Number.isInteger(m.from)||!Number.isInteger(m.to)||m.from<0||m.from>63||m.to<0||m.to>63||m.from===m.to)return false;
    const b=s.board,p=b[m.from],who=s.turn,t=Math.abs(p);if(sgn(p)!==who||sgn(b[m.to])===who||Math.abs(b[m.to])===1)return false;
    const dx=m.to%8-m.from%8,dy=(m.to>>3)-(m.from>>3),ax=Math.abs(dx),ay=Math.abs(dy);
    const promotes=t===6&&(m.to>>3)===(who===1?0:7);
    if(promotes?![2,3,4,5].includes(m.promote):m.promote!=null)return false;
    let ok=false;
    if(t===6){
      ok=dx===0&&!b[m.to]&&(dy===-who||(dy===-2*who&&(m.from>>3)===(who===1?6:1)&&!b[m.from-who*8]));
      if(ax===1&&dy===-who)ok=Boolean(b[m.to])||(m.to===s.ep&&!b[m.to]&&b[m.to+who*8]===-who*6);
    }else if(t===5)ok=ax*ay===2;
    else if(t===1){
      ok=Math.max(ax,ay)===1;
      if(!dy&&ax===2&&m.from===(who===1?60:4)){
        const right=who===1?(dx>0?1:2):(dx>0?4:8),rf=m.from+(dx>0?3:-4),step=sgn(dx);
        ok=Boolean(s.castling&right)&&b[rf]===who*3&&!checked(s,who);
        for(let i=m.from+step;i!==rf;i+=step)if(b[i])ok=false;
        if(attacked(b,m.from+step,-who)||attacked(b,m.to,-who))ok=false;
      }
    }else if((t===2&&(ax===ay||!dx||!dy))||(t===3&&(!dx||!dy))||(t===4&&ax===ay)){
      ok=true;const step=sgn(dx)+sgn(dy)*8;for(let i=m.from+step;i!==m.to;i+=step)if(b[i]){ok=false;break;}
    }
    return ok&&!checked(apply(s,m),who);
  }
  function moves(s){const out=[];for(let from=0;from<64;from++)if(sgn(s.board[from])===s.turn)for(let to=0;to<64;to++){
    if(Math.abs(s.board[from])===6&&(to>>3)===(s.turn===1?0:7)){for(const promote of [2,3,4,5])if(legal(s,{from,to,promote}))out.push({from,to,promote});}
    else if(legal(s,{from,to}))out.push({from,to});
  }return out;}
  function key(s){let ep=-1;if(s.ep>=0)for(const from of [s.ep+s.turn*8-1,s.ep+s.turn*8+1])if(legal(s,{from,to:s.ep}))ep=s.ep;return s.board.join(',')+':'+s.turn+':'+s.castling+':'+ep;}
  function initial(){const row=[3,5,4,2,1,4,5,3],s={kind:'chess',board:[...row.map(p=>-p),...Array(8).fill(-6),...Array(32).fill(0),...Array(8).fill(6),...row],turn:1,castling:15,ep:-1,halfmove:0,moves:[],positions:[],result:null};s.positions=[key(s)];return s;}
  function insufficient(b){const material=b.map((p,i)=>({p:Math.abs(p),i})).filter(x=>x.p&&x.p!==1);return !material.length||(material.length===1&&[4,5].includes(material[0].p))||(material.every(x=>x.p===4)&&new Set(material.map(x=>(x.i%8+(x.i>>3))%2)).size===1);}
  function play(s,m){
    if(s.result||!legal(s,m))throw Error('Illegal move.');const n=clone(apply(s,m)),before={board:s.board,turn:s.turn,castling:s.castling,ep:s.ep,halfmove:s.halfmove};
    n.moves.push({...m,side:s.turn,piece:s.board[m.from],captured:s.board[m.to]||(Math.abs(s.board[m.from])===6&&m.to===s.ep?-s.turn*6:0),before:clone(before)});
    n.positions.push(key(n));
    if(!moves(n).length)n.result={winner:checked(n)?s.turn:0,reason:checked(n)?'checkmate':'stalemate-draw'};
    else if(insufficient(n.board))n.result={winner:0,reason:'insufficient'};
    else if(n.positions.filter(p=>p===n.positions.at(-1)).length>=3)n.result={winner:0,reason:'repetition'};
    else if(n.halfmove>=100)n.result={winner:0,reason:'fifty-moves'};
    return n;
  }
  function undo(s,side){if(s.result)throw Error('Game ended.');const index=s.moves.findLastIndex(m=>m.side===side);if(index<0)throw Error('Nothing to undo.');return {...clone(s),...clone(s.moves[index].before),moves:clone(s.moves.slice(0,index)),positions:s.positions.slice(0,index+1),result:null};}
  root.BoardChess={initial,legal,moves,play,undo,checked,attacked,key,apply,insufficient};
  if(typeof module!=='undefined')module.exports=root.BoardChess;
})(globalThis);
