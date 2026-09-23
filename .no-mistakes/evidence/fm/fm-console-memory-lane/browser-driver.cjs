const {chromium}=require('/home/clif/.npm/_npx/e41f203b7505f1fb/node_modules/playwright-core');
const {execFileSync}=require('node:child_process');
const fs=require('node:fs');
(async()=>{
const evidence='/home/clif/.no-mistakes/evidence/01M37VRR2WA8H6FF9ZN9T0MHRH';
const browser=await chromium.launch({executablePath:'/home/clif/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',headless:true,args:['--no-sandbox']});
try {
const context=await browser.newContext({httpCredentials:{username:'operator',password:'local-browser-validation-secret-1234567890'},viewport:{width:1280,height:1100}});
const page=await context.newPage(); const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.goto('http://127.0.0.1:18765');
await page.getByRole('button',{name:'03 Do work'}).click();
await page.locator('#draft').fill('Check the deployment report and preserve this order.');
await page.locator('#send-order').click();
await page.waitForFunction(()=>document.querySelector('#order-result').textContent.includes('Order saved'));
const env={...process.env,FM_HOME:process.cwd()+'/.console-live/home'};
const receipts=JSON.parse(execFileSync('bin/fm-inbox.sh',['receipts'],{env,encoding:'utf8'}));
fs.writeFileSync(evidence+'/initial-receipts.json',JSON.stringify(receipts,null,2));
const id=receipts.pending[0].id;
execFileSync('bin/fm-inbox.sh',['reply','--json',id,'Deployment verification is recorded in the deployment report.'],{env});
execFileSync('bin/fm-inbox.sh',['drain','--ack',id],{env});
await page.reload();await page.getByRole('button',{name:'03 Do work'}).click();
await page.locator('.excerpt-view').waitFor();
const answer=page.locator('.message.answer');
const text=await answer.innerText();if(!text.includes('cursor 000000000001')||!text.includes('deployment-check/report.md')||!text.includes('bounded local memory excerpt'))throw Error('Missing visible answer contract: '+text);
await page.locator('#conversation').scrollIntoViewIfNeeded();
await page.screenshot({path:evidence+'/orders-and-answers.png',fullPage:true});
await page.getByRole('button',{name:'View source'}).click();
await page.waitForFunction(()=>document.querySelector('.excerpt-source-view').textContent.includes('# Deployment report'));
await page.screenshot({path:evidence+'/view-source.png',fullPage:true});
const source=await page.locator('.excerpt-source-view').innerText();
await page.getByRole('button',{name:'View source'}).click();if(await page.locator('.excerpt-source-view').isVisible())throw Error('Source toggle did not collapse');
const guards=[];for(const path of ['/artifact/private.md','/artifact/..%2Fconfig%2Fconsole-operator-secret','/data/deployment-check/report.md','/artifact/deployment-check__report.md?line=0']){const r=await context.request.get('http://127.0.0.1:18765'+path);guards.push({path,status:r.status()});if(r.status()<400)throw Error('Confinement failed');}
execFileSync('python3',['bin/fm-console.py','--mark-curated','000000000001'],{env});
await page.reload();await page.getByRole('button',{name:'03 Do work'}).click();
await page.waitForFunction(()=>document.querySelector('#curation-status').textContent.includes('All 1 durable answers are folded'));
await page.screenshot({path:evidence+'/curated-cursor.png',fullPage:true});
await page.setViewportSize({width:390,height:844});await page.screenshot({path:evidence+'/mobile-orders.png',fullPage:true});
const final=await context.request.get('http://127.0.0.1:18765/api/receipts');
fs.writeFileSync(evidence+'/browser-validation.json',JSON.stringify({answer:text,source,curation:await page.locator('#curation-status').innerText(),guards,errors,receipts:await final.json()},null,2));
if(errors.length)throw Error(errors.join('\n'));
console.log('Browser order submission, durable acknowledged answer, excerpt, cursor, source expand/collapse, artifact confinement, curated reload and mobile screenshots passed.');
}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
