(function (root) {
  'use strict';
  const KEY = 'friends-games-language-v1';
  const languages = ['zh-CN', 'zh-TW', 'en'];
  const labels = ['简体中文', '繁體中文', 'English'];
  const catalog = root.FRIENDS_I18N_CATALOG;
  const bindings = new WeakMap();
  const fixed = new Set(['同词相遇', 'Friends Games', '100 Q&As', 'Friends Tycoon', 'What’s Next?', 'Board Games', '五子棋', '中国象棋', '国际象棋', '飞行棋', '跳棋', '帥 將', '楚 河', '漢 界']);
  const attrs = ['placeholder', 'title', 'aria-label', 'aria-description', 'alt'];
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const escapeRE = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const rows = new Map(catalog.messages.map(row => [row[0], row]));
  const patterns = catalog.messages.filter(row => /\{\d+\}/.test(row[0])).map(row => {
    const slots = [];
    const parts = row[0].split(/(\{\d+\})/g).map(part => {
      if (/^\{\d+\}$/.test(part)) { slots.push(Number(part.slice(1,-1))); return '([\\s\\S]*?)'; }
      return escapeRE(part);
    });
    return {row, slots, re:new RegExp('^'+parts.join('')+'$'), weight:row[0].replace(/\{\d+\}/g,'').length};
  }).sort((a,b) => b.weight-a.weight);
  function detect(list) {
    for (const value of list || []) {
      const code = String(value).toLowerCase();
      if (/^zh(?:-|$)/.test(code)) return /(?:tw|hk|mo|hant)/.test(code) ? 'zh-TW' : 'zh-CN';
      if (/^en(?:-|$)/.test(code)) return 'en';
    }
    return 'zh-CN';
  }
  function stored() { try { return localStorage.getItem(KEY); } catch { return null; } }
  let language = languages.includes(stored()) ? stored() : detect(navigator.languages || [navigator.language]);
  function translated(row) { return row[language === 'en' ? 1 : 2]; }
  function match(value) {
    for (const item of patterns) { const result=item.re.exec(value); if(result) return {item,result}; }
    return null;
  }
  function text(value, depth=0) {
    const original=String(value ?? '');
    if (language==='zh-CN' || !original.trim() || depth>5) return original;
    const key=original.trim(), leading=original.slice(0,original.indexOf(key)), trailing=original.slice(original.indexOf(key)+key.length);
    if(fixed.has(key)) return original;
    const direct=rows.get(key);
    if(direct) return leading+translated(direct)+trailing;
    const found=match(key);
    if(found) {
      const {item,result}=found, values={};
      item.slots.forEach((slot,i) => { values[slot]=text(result[i+1],depth+1); });
      return leading+translated(item.row).replace(/\{(\d+)\}/g,(_,n)=>values[n] ?? '')+trailing;
    }
    // Mixed status lines use separate semantic parts; do not replace words inside unknown text.
    if(key.includes(' | ')) return leading+key.split(' | ').map(v=>text(v,depth+1)).join(' | ')+trailing;
    if(key.includes('·')) return leading+key.split(/(\s*·\s*)/).map(v=>v.includes('·')?v:text(v,depth+1)).join('')+trailing;
    if(/(?:^\/ | \/ | \/$)/.test(key)) return leading+key.split(/(\s*\/\s*)/).map(v=>v.includes('/')?v:text(v,depth+1)).join('')+trailing;
    if(key.startsWith('：')) return ': '+text(key.slice(1),depth+1);
    if(key.includes('：')) return leading+key.split('：').map(v=>text(v,depth+1)).join(language==='en'?': ':'：')+trailing;
    const side=key.match(/^(黑棋|白棋|红方|黑方|白方|蓝方|绿方|黄方|紫方|青方)(.+)$/);
    if(side) return leading+text(side[1],depth+1)+(language==='en'?' ':'')+text(side[2],depth+1)+trailing;
    return original;
  }
  function user(value) { return '<span translate="no">'+escape(value)+'</span>'; }
  function canonical(bank) { return Array.isArray(bank) && bank.length===root.QA_QUESTIONS.length && bank.every((q,i)=>q===root.QA_QUESTIONS[i]); }
  function questionBank(bank) { return canonical(bank) && language!=='zh-CN' ? catalog.questions[language].slice() : bank.slice(); }
  function questionHtml(question,index,bank) {
    return canonical(bank) ? '<span translate="no" data-i18n-question="'+index+'">'+escape(question)+'</span>' : user(question);
  }
  const dateOptions={date:{year:'numeric',month:'numeric',day:'numeric'},chat:{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'},spin:{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'}};
  function dateText(value,preset='date') {
    const date=new Date(value); return Number.isNaN(date.getTime())?'':new Intl.DateTimeFormat(language,dateOptions[preset]).format(date);
  }
  function dateHtml(value,preset='date') { return '<time translate="no" data-i18n-date="'+escape(value)+'" data-date-format="'+preset+'" datetime="'+escape(value)+'">'+escape(dateText(value,preset))+'</time>'; }
  function logHtml(value) { return '<span translate="no" data-i18n-log="'+escape(value)+'">'+escape(value)+'</span>'; }
  function logText(value) {
    if(language==='zh-CN') return value;
    const direct=rows.get(value); if(direct) return translated(direct);
    const found=match(value); if(!found) return value;
    const {item,result}=found, values={};
    const raw=item.row[0].startsWith('{0}') || item.row[0].startsWith('移除后') || item.row[0].startsWith('游戏结束，') ? [0] : [];
    if(item.row[0].includes('向 {1} 支付租金')) raw.push(1);
    if(['{0} 暂无主人，可以购买。','{0} 已经满级，本回合自动结束。'].includes(item.row[0])) raw.length=0;
    item.slots.forEach((slot,i)=>{values[slot]=raw.includes(slot)?result[i+1]:text(result[i+1]);});
    return translated(item.row).replace(/\{(\d+)\}/g,(_,n)=>values[n] ?? '');
  }
  function control() {
    return '<label class="language-control"><span>切换语言</span><select data-language-select aria-label="切换语言">'+languages.map((code,i)=>'<option translate="no" lang="'+code+'" value="'+code+'"'+(code===language?' selected':'')+'>'+labels[i]+'</option>').join('')+'</select></label>';
  }
  function bind(node,key,current,write) {
    let fields=bindings.get(node); if(!fields){fields={};bindings.set(node,fields);}
    let saved=fields[key]; if(!saved || current!==saved.rendered) saved={source:current,rendered:current};
    const next=text(saved.source); saved.rendered=next;fields[key]=saved;
    if(current!==next) write(next);
  }
  function localizeNode(node) {
    if(node.nodeType===3) {
      if(!node.parentElement || node.parentElement.closest('[translate="no"],textarea,input,script,style,noscript')) return;
      bind(node,'text',node.nodeValue,value=>{node.nodeValue=value;});return;
    }
    if(node.nodeType!==1) return;
    if(node.hasAttribute('data-i18n-question')) {
      const i=Number(node.dataset.i18nQuestion), bank=language==='zh-CN'?root.QA_QUESTIONS:catalog.questions[language];
      if(bank[i]!==undefined && node.textContent!==bank[i]) node.textContent=bank[i];
    }
    if(node.hasAttribute('data-i18n-date')) {const value=dateText(node.dataset.i18nDate,node.dataset.dateFormat);if(node.textContent!==value)node.textContent=value;}
    if(node.hasAttribute('data-i18n-log')) {const value=logText(node.dataset.i18nLog);if(node.textContent!==value)node.textContent=value;}
    if(node.hasAttribute('data-language-select')) node.value=language;
    if(node.closest('[translate="no"],script,style,noscript')) return;
    for(const attr of attrs) if(node.hasAttribute(attr)) bind(node,attr,node.getAttribute(attr),value=>node.setAttribute(attr,value));
  }
  function apply(target=document.documentElement) {
    localizeNode(target);
    const walker=document.createTreeWalker(target,NodeFilter.SHOW_ELEMENT|NodeFilter.SHOW_TEXT);
    let node;while((node=walker.nextNode()))localizeNode(node);
  }
  function setLanguage(value,persist=true) {
    if(!languages.includes(value))return;
    language=value;
    if(persist)try{localStorage.setItem(KEY,value);}catch{/* Keep the current tab usable when storage is disabled. */}
    document.documentElement.lang=value;apply();
    document.dispatchEvent(new CustomEvent('friends-language-change',{detail:{language:value}}));
  }
  function title(value,isUser=false) {
    const node=document.querySelector('title');if(node)node.setAttribute('translate',isUser?'no':'yes');
    document.title=value;
  }
  root.FriendsI18n={text,user,dateHtml,dateText,questionBank,questionHtml,logHtml,control,apply,setLanguage,title,detect,get language(){return language;}};
  document.documentElement.lang=language;
  document.addEventListener('change',event=>{if(event.target.matches('[data-language-select]'))setLanguage(event.target.value);});
  window.addEventListener('storage',event=>{if(event.key===KEY&&languages.includes(event.newValue))setLanguage(event.newValue,false);});
  const observer=new MutationObserver(records=>{
    const targets=new Set();
    for(const record of records){
      if(record.type==='childList')for(const node of record.addedNodes)targets.add(node);
      else targets.add(record.target);
    }
    for(const node of targets)if(node.isConnected)apply(node);
  });
  observer.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:attrs});
  apply();
})(window);
