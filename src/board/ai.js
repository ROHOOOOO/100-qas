/* Bounded, iterative search. Runs in a worker in the application. */
(function(root){
  'use strict';
  const R=root.BoardRules, values=[0,100000,120,120,320,650,350,90];
  function evaluate(kind,board,s){
    if(kind==='xiangqi')return board.reduce((total,p,i)=>{
      if(!p)return total;const who=Math.sign(p),t=Math.abs(p),y=Math.floor(i/9),advance=who===1?9-y:y;
      return total+who*s*(values[t]+(t===7?advance*12+(advance>=5?35:0):t===4?14-Math.abs(i%9-4)*3:0));
    },0);
    let score=0;
    for(let i=0;i<225;i++)if(board[i]){
      const who=board[i],x=i%15,y=Math.floor(i/15);
      for(const [dx,dy] of [[1,0],[0,1],[1,1],[1,-1]]){
        const px=x-dx,py=y-dy;if(px>=0&&px<15&&py>=0&&py<15&&board[py*15+px]===who)continue;
        let n=0,a=x,b=y;while(a>=0&&a<15&&b>=0&&b<15&&board[b*15+a]===who){n++;a+=dx;b+=dy;}
        const open=(px>=0&&px<15&&py>=0&&py<15&&!board[py*15+px]?1:0)+(a>=0&&a<15&&b>=0&&b<15&&!board[b*15+a]?1:0);
        score+=s*who*(n>=5?1000000:open===0?0:([0,2,25,450,22000][n]||0)*(open===2?5:1));
      }
    }return score;
  }
  function after(board,move,s,kind){const b=board.slice();b[move.to]=kind==='gomoku'?s:b[move.from];if(kind!=='gomoku')b[move.from]=0;return b;}
  function candidates(kind,board,s){
    if(kind==='xiangqi')return R.moves(kind,board,s);
    if(board.every(p=>!p))return [{to:112}];
    return R.moves(kind,board,s).filter(m=>{
      const x=m.to%15,y=Math.floor(m.to/15);
      for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++){const a=x+dx,b=y+dy;if(a>=0&&a<15&&b>=0&&b<15&&board[b*15+a])return true;}
      return false;
    });
  }
  function choose(state,level,limits){
    if(state.result)return null;
    const settings={easy:{depth:1,nodes:150,ms:120,width:8},normal:{depth:2,nodes:1800,ms:400,width:12},hard:{depth:4,nodes:12000,ms:1400,width:18}}[level]||null;
    if(!settings)throw new Error('Invalid difficulty.');
    const cfg=Object.assign({},settings,limits||{}),deadline=Date.now()+cfg.ms,kind=state.kind,who=state.turn;
    let nodes=0,completedDepth=0;
    const ranked=(board,s)=>candidates(kind,board,s).map(move=>{
      const b=after(board,move,s,kind);let score=evaluate(kind,b,s);
      if(kind==='gomoku'){const defense=board.slice();defense[move.to]=-s;if(R.line(defense,move.to,-s))score+=1500000;if(R.line(b,move.to,s))score+=3000000;}
      else score+=(Math.abs(board[move.to])?values[Math.abs(board[move.to])]*2:0)+(R.checked(b,-s)?40:0);
      return {move,b,score};
    }).sort((a,b)=>b.score-a.score||a.move.to-b.move.to);
    const options=ranked(state.board,who);if(!options.length)return null;
    // Always take an immediate win; normal/hard also explicitly prevent one-move gomoku losses.
    for(const item of options){const next=R.play(state,item.move);if(next.result?.winner===who)return {move:item.move,nodes:++nodes,depth:1};}
    if(level!=='easy'&&kind==='gomoku'){
      const threat=options.find(item=>{const b=state.board.slice();b[item.move.to]=-who;return R.line(b,item.move.to,-who);});
      if(threat)return {move:threat.move,nodes:++nodes,depth:1};
    }
    if(level==='easy'){
      const seed=state.board.reduce((a,p,i)=>(Math.imul(a^((p+8)*(i+1)),16777619)>>>0),2166136261);
      return {move:options[seed%Math.min(4,options.length)].move,nodes:options.length,depth:1};
    }
    const STOP={};
    function search(board,s,depth,alpha,beta,last){
      if(++nodes>cfg.nodes||Date.now()>deadline)throw STOP;
      if(kind==='gomoku'&&last!=null&&R.line(board,last,-s))return -10000000-depth*100;
      if(!depth)return evaluate(kind,board,s);
      const list=ranked(board,s);if(!list.length)return kind==='xiangqi'?-10000000-depth*100:0;
      let best=-Infinity;
      for(const item of list.slice(0,cfg.width)){
        const score=-search(item.b,-s,depth-1,-beta,-alpha,item.move.to);
        best=Math.max(best,score);alpha=Math.max(alpha,score);if(alpha>=beta)break;
      }return best;
    }
    let best=options[0].move;
    for(let depth=1;depth<=cfg.depth;depth++){
      let roundBest=best,roundScore=-Infinity;
      try{
        for(const item of options.slice(0,cfg.width)){
          const result=R.play(state,item.move).result;
          const score=result?(result.winner===who?10000000:result.winner===-who?-10000000:0):-search(item.b,-who,depth-1,-Infinity,-roundScore,item.move.to);
          if(score>roundScore){roundScore=score;roundBest=item.move;}
        }
        best=roundBest;completedDepth=depth;
      }catch(error){if(error!==STOP)throw error;break;}
    }
    return {move:best,nodes,depth:completedDepth};
  }
  root.BoardAI={choose,evaluate};if(typeof module!=='undefined')module.exports=root.BoardAI;
})(globalThis);
