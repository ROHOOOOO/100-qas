importScripts('rules.js','chess.js','race.js','ai.js','ai-extra.js');
self.onmessage = function(event) {
  try { self.postMessage({id:event.data.id,...BoardAI.choose(event.data.state,event.data.level)}); }
  catch(error) { self.postMessage({id:event.data.id,error:error.message}); }
};
