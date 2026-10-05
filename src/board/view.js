(function(root){
 'use strict';const R=root.BoardRules,G=root.BoardRace;
 const colors=['#b84436','#396bb2','#397857','#bf8a21','#86589f','#27888a'],colorNames=['红方','蓝方','绿方','黄方','紫方','青方'];
 const names={1:['帅','将'],2:['仕','士'],3:['相','象'],4:['马','马'],5:['车','车'],6:['炮','炮'],7:['兵','卒']};
 const glyphs={1:['♔','♚'],2:['♕','♛'],3:['♖','♜'],4:['♗','♝'],5:['♘','♞'],6:['♙','♟']};
 const sideName=(kind,s)=>kind==='chess'?(s===1?'白方':'黑方'):kind==='xiangqi'?(s===1?'红方':'黑方'):kind==='gomoku'?(s===1?'黑棋':'白棋'):colorNames[s-1];
 const coordinate=(kind,i)=>kind==='halma'?String(i+1):String.fromCharCode(65+i%(kind==='gomoku'?15:kind==='chess'?8:9))+(kind==='gomoku'?15-Math.floor(i/15):kind==='chess'?8-Math.floor(i/8):10-Math.floor(i/9));
 const point=i=>[500+(G.points[i][0]+G.points[i][1]/2)*56,500+G.points[i][1]*48.4974];
 function render(s,opts={}){
  const {side=1,interactive=false,selected=-1,path=[]}=opts,kind=s.kind;
  if(kind==='flight')return flight(s,interactive);
  let board=s.board,targets=[],svg='',w,h;
  if(kind==='halma'){
   const draft=path.length?path:selected>=0?[selected]:[];
   if(interactive&&draft.length)targets=board.map((_,i)=>i).filter(i=>G.halmaLegal(s,{path:[...draft,i]}));
   if(draft.length>1){board=board.slice();board[draft[0]]=0;board[draft.at(-1)]=s.turn;}
   svg='<svg viewBox="0 0 1000 1000" aria-hidden="true">';
   G.camps.forEach((camp,c)=>{const coords=camp.map(point),x=coords.reduce((a,p)=>a+p[0],0)/10,y=coords.reduce((a,p)=>a+p[1],0)/10;const seat=G.campOrder[s.count].indexOf(c);if(seat>=0)svg+='<circle cx="'+x+'" cy="'+y+'" r="90" style="fill:'+colors[seat]+'" opacity=".10"/>';});
   const visiblePath=draft.length>1?draft:s.moves?.at(-1)?.path;
   if(visiblePath?.length>1)svg+='<polyline points="'+visiblePath.map(i=>point(i).join(',')).join(' ')+'" fill="none" stroke="#cc9252" stroke-width="7"/>';
   svg+='</svg>';
  }else{
   w=kind==='gomoku'?15:kind==='chess'?8:9;h=kind==='gomoku'?15:kind==='chess'?8:10;
   if(interactive&&selected>=0)targets=R.list(s).filter(m=>m.from===selected).map(m=>m.to);
   if(kind==='chess'){
    svg='<svg viewBox="0 0 800 800" aria-hidden="true">';for(let y=0;y<8;y++)for(let x=0;x<8;x++)svg+='<rect x="'+x*100+'" y="'+y*100+'" width="100" height="100" fill="'+((x+y)%2?'#91a998':'#f4eddb')+'"/>';svg+='</svg>';
   }else{
    svg='<svg viewBox="0 0 '+(w+1)*100+' '+(h+1)*100+'" aria-hidden="true">';for(let y=1;y<=h;y++)svg+='<path d="M100 '+y*100+' H'+w*100+'"/>';
    for(let x=1;x<=w;x++)svg+='<path d="M'+x*100+' 100 V'+(kind==='xiangqi'&&x>1&&x<9?'500 M'+x*100+' 600 V':'')+h*100+'"/>';
    if(kind==='xiangqi')svg+='<path d="M400 100 L600 300 M600 100 L400 300 M400 800 L600 1000 M600 800 L400 1000"/><text x="320" y="563">楚 河</text><text x="680" y="563">漢 界</text>';
    else for(const [x,y]of[[4,4],[12,4],[8,8],[4,12],[12,12]])svg+='<circle cx="'+x*100+'" cy="'+y*100+'" r="9"/>';svg+='</svg>';
   }
  }
  const last=s.moves?.at(-1),check=R.isCheck(s);
  const cells=board.map((p,i)=>{
   let x,y,width,height;
   if(kind==='halma'){[x,y]=point(i).map(v=>v/10);width=height=4.5;}
   else{let a=i%w,b=Math.floor(i/w);if(side===-1){a=w-1-a;b=h-1-b;}const inset=kind==='chess'?.5:1;x=(a+inset)/(kind==='chess'?w:w+1)*100;y=(b+inset)/(kind==='chess'?h:h+1)*100;width=94/(kind==='chess'?w:w+1);height=94/(kind==='chess'?h:h+1);}
   const glyph=p?(kind==='xiangqi'?names[Math.abs(p)][p>0?0:1]:kind==='chess'?glyphs[Math.abs(p)][p>0?0:1]:''):'';
   const label=coordinate(kind,i)+(p?' '+sideName(kind,kind==='halma'?p:Math.sign(p))+(glyph||'棋子'):' 空位');
   const cls='board-cell '+(p?'occupied side-'+(p>0?'plus':'minus'):'empty')+(i===selected||path.at(-1)===i?' selected':'')+(targets.includes(i)?' target':'')+(last?.to===i?' last-move':'')+(check&&p===s.turn?' in-check':'');
   const style='left:'+x+'%;top:'+y+'%;width:'+width+'%;height:'+height+'%;'+(kind==='halma'?'--piece-color:'+(colors[p-1]||'#decfab')+';':'');
   return '<'+(interactive?'button type="button"':'span')+' class="'+cls+'" style="'+style+'" data-board="cell" data-index="'+i+'" aria-label="'+label+'"><span>'+glyph+'</span></'+(interactive?'button':'span')+'>';
  }).join('');return '<div class="chess-board '+kind+'" role="group" aria-label="棋盘">'+svg+cells+'</div>';
 }
 function flight(s,interactive){
  let svg='<svg viewBox="0 0 1500 1500" aria-hidden="true"><rect width="1500" height="1500" fill="#f7f2e6"/>';
  for(let side=1;side<=s.count;side++){
   const box=G.airports[side-1],x=Math.min(...box.map(p=>p[0]))*100-40,y=Math.min(...box.map(p=>p[1]))*100-40;
   svg+='<rect x="'+x+'" y="'+y+'" width="380" height="380" rx="45" fill="'+colors[side-1]+'" opacity=".13"/>';
   for(let h=0;h<6;h++){const [a,b]=G.home(side,h);svg+='<rect x="'+a*100+'" y="'+b*100+'" width="100" height="100" fill="'+colors[side-1]+'" opacity=".5"/><text x="'+(a*100+50)+'" y="'+(b*100+65)+'">'+(h===5?'★':h+1)+'</text>';}
  }
  G.track.forEach(([x,y],i)=>{svg+='<rect x="'+x*100+'" y="'+y*100+'" width="100" height="100" rx="15" fill="'+colors[(i+2)%4]+'" opacity=".23"/><text x="'+(x*100+50)+'" y="'+(y*100+62)+'">'+(i+1)+'</text>';});
  for(let side=1;side<=s.count;side++){const [x,y]=G.track[((side-1)*13+18)%52],[a,b]=G.track[((side-1)*13+30)%52];svg+='<path d="M'+(x*100+50)+' '+(y*100+50)+' L'+(a*100+50)+' '+(b*100+50)+'" style="stroke:'+colors[side-1]+'" stroke-width="9" stroke-dasharray="14 14" opacity=".45"/>';}
  svg+='</svg>';
  const legal=interactive?G.flightMoves(s).map(m=>m.token):[],groups=new Map();
  const positions=s.board.map((p,i)=>{const side=Math.floor(i/4)+1,token=i%4,xy=G.planePoint(side,token,p),key=xy.join(',');if(!groups.has(key))groups.set(key,[]);groups.get(key).push(i);return {p,side,token,xy,key,i};});
  const pieces=positions.map(({p,side,token,xy,key,i})=>{const group=groups.get(key),slot=group.indexOf(i),offset=group.length>1?[[0,0],[.34,0],[0,.34],[.34,.34]][slot%4]:[.17,.17];const x=(xy[0]+.32+offset[0])/15*100,y=(xy[1]+.32+offset[1])/15*100,active=side===s.turn&&legal.includes(token);
   return '<'+(active?'button type="button"':'span')+' class="flight-plane '+(active?'can-move':'')+'" style="left:'+x+'%;top:'+y+'%;--piece-color:'+colors[side-1]+'" data-board="plane" data-token="'+token+'" aria-label="'+sideName('flight',side)+'飞机'+(token+1)+'"><span>✈</span><small>'+(token+1)+'</small></'+(active?'button':'span')+'>';
  }).join('');return '<div class="chess-board flight" role="group" aria-label="飞行棋棋盘">'+svg+pieces+'</div>';
 }
 root.BoardView={render,sideName,coordinate,colors};
})(globalThis);
