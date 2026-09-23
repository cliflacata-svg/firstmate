const fs = require('fs'), path = require('path'), cp = require('child_process'), assert = require('assert');
const root=process.cwd(), dir=path.join(root,'.console-ui-check'), home=path.join(dir,'home');
const evidence='/home/clif/.no-mistakes/evidence/01M37VRR2WA8H6FF9ZN9T0MHRH';
fs.mkdirSync(evidence,{recursive:true});
const secret='local-ui-test-secret-01234567890123456789';
fs.writeFileSync(path.join(home,'config/console-operator-secret'),secret,{mode:0o600});
fs.writeFileSync(path.join(home,'data/learnings.md'),'# Deployment memory\nDeployment verification requires checking the visible source excerpt.\n');
const env={...process.env,FM_HOME:home};
const owner=(...args)=>{const p=cp.spawnSync(path.join(root,'bin/fm-inbox.sh'),args,{env,encoding:'utf8'}); assert([0,3].includes(p.status),p.stderr); return JSON.parse(p.stdout);};
const note=owner('note','--json','--request-id','ui-source-check','Explain deployment verification');
owner('reply','--json',note.id,'Deployment verification requires checking the visible source excerpt.');
const server=cp.spawn('python3',['bin/fm-console.py','--port','18765'],{env,stdio:['ignore',fs.openSync(path.join(dir,'server.log'),'w'), 'pipe']});
const browser=cp.spawn('/home/clif/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',['--headless','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--no-default-browser-check','--remote-debugging-port=0',`--user-data-dir=${path.join(dir,'profile')}`,'about:blank'],{stdio:['ignore','ignore',fs.openSync(path.join(dir,'chrome.log'),'w')]});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let ws;
(async()=>{
 try {
  let port;
  for(let i=0;i<100;i++){try{port=fs.readFileSync(path.join(dir,'profile/DevToolsActivePort'),'utf8').split('\n')[0];break;}catch{} await sleep(100);}
  assert(port,'Chromium never started');
  const tabs=await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws=new WebSocket(tabs[0].webSocketDebuggerUrl); await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
  let id=0;const pending=new Map(),errors=[],requests=[];
  ws.onmessage=({data})=>{const m=JSON.parse(data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(m.error):p.resolve(m.result);}else if(m.method==='Runtime.exceptionThrown')errors.push(m.params);else if(m.method==='Network.responseReceived')requests.push({url:m.params.response.url,status:m.params.response.status});};
  const send=(method,params={})=>new Promise((resolve,reject)=>{pending.set(++id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});
  const evaluate=async expression=>{const r=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert(!r.exceptionDetails,JSON.stringify(r.exceptionDetails));return r.result.value;};
  const wait=async expression=>{for(let i=0;i<150;i++){if(await evaluate(expression))return;await sleep(100);}throw Error('Timed out: '+expression);};
  const click=async selector=>{const p=await evaluate(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);await send('Input.dispatchMouseEvent',{type:'mousePressed',...p,button:'left',clickCount:1});await send('Input.dispatchMouseEvent',{type:'mouseReleased',...p,button:'left',clickCount:1});};
  await send('Page.enable');await send('Runtime.enable');await send('Network.enable');
  await send('Emulation.setDeviceMetricsOverride',{width:1280,height:1000,deviceScaleFactor:1,mobile:false});
  await send('Network.setExtraHTTPHeaders',{headers:{Authorization:'Basic '+Buffer.from('operator:'+secret).toString('base64')}});
  await send('Page.navigate',{url:'http://127.0.0.1:18765/'});
  await wait(`document.querySelectorAll('.message.answer').length===1`);
  await click('[data-lane="work"]');
  await wait(`!document.querySelector('#work').hidden`);
  const before=await evaluate(`({excerpt:document.querySelector('.excerpt-body').innerText,source:document.querySelector('.excerpt-source').innerText,cursor:document.querySelector('.answer .message-foot').innerText,curation:document.querySelector('#curation-status').innerText,sourceHidden:document.querySelector('.excerpt-source-view').hidden})`);
  assert(before.excerpt.includes('Deployment verification'));assert.equal(before.source,'learnings.md:2');assert(before.cursor.includes('cursor 000000000001'));assert(before.curation.includes('1 of 1'));assert(before.sourceHidden);
  await click('.excerpt-view');
  await wait(`document.querySelector('.excerpt-source-view').innerText.includes('# Deployment memory')`);
  const after=await evaluate(`({source:document.querySelector('.excerpt-source-view').innerText,visible:!document.querySelector('.excerpt-source-view').hidden,button:document.querySelector('.excerpt-view').innerText})`);
  assert(after.visible);assert(after.source.includes(before.excerpt));
  const screenshot=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});fs.writeFileSync(path.join(evidence,'console-ui-source.png'),Buffer.from(screenshot.data,'base64'));
  await click('.excerpt-view');assert(await evaluate(`document.querySelector('.excerpt-source-view').hidden`));
  assert.equal(errors.length,0,JSON.stringify(errors));assert(requests.some(r=>r.url.includes('/artifact/')&&r.status===200));
  fs.writeFileSync(path.join(evidence,'console-ui-check.json'),JSON.stringify({verdict:'pass',browser:'Cached Chromium 151 via direct CDP',wrapperBlocker:'chrome-devtools-axi omits required pageId; pages lists zero pages',before,after,requests,errors,sourceTogglePassed:true},null,2));
  console.log(JSON.stringify({verdict:'pass',before,after,evidence},null,2));
 }finally{if(ws)ws.close();browser.kill('SIGTERM');server.kill('SIGTERM');}
})().catch(e=>{console.error(e);process.exitCode=1;});
