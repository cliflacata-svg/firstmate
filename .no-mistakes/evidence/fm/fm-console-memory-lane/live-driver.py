import base64,http.client,json,os,subprocess,time,stat
from pathlib import Path
root=Path.cwd(); home=root/'.console-live'; env=dict(os.environ,FM_HOME=str(home)); log=[]
def req(path,body=None,auth=True,extra=None):
 c=http.client.HTTPConnection('127.0.0.1',18765,timeout=60)
 h={'Authorization':'Basic '+base64.b64encode(b'operator:console-validation-secret-1234567890').decode()} if auth else {}
 if body is not None:h.update({'Origin':'http://127.0.0.1:18765','Content-Type':'application/json','X-Console-CSRF':csrf})
 h.update(extra or {}); c.request('POST' if body is not None else 'GET',path,json.dumps(body) if body is not None else None,h); r=c.getresponse(); data=r.read(); c.close()
 try:data=json.loads(data)
 except: data=data.decode()
 return r.status,data
def cli(*args):
 p=subprocess.run([str(root/'bin/fm-inbox.sh'),*args],env=env,text=True,capture_output=True); assert p.returncode in (0,3),(args,p.stderr);return p.stdout
csrf=req('/api/session')[1]['csrf']; ids=[]
for i in range(23):
 body={'request_id':f'live-{i}','text':f'Harbor deployment question {i}\nKeep this second line.'}
 status,order=req('/api/order',body)
 if status==429:
  time.sleep(61); status,order=req('/api/order',body)
 assert status==202,(status,order)
 ids.append(order['id'])
 if i==0:
  replay=req('/api/order',body)[1];assert replay['id']==ids[0] and replay['outcome']=='replay';log.append({'order':order,'replay':replay})
 cli('drain','--ack',ids[-1]); cli('reply',ids[-1],f'Harbor deployment answer {i}: blue release lane.')
status,page=req('/api/receipts');assert status==200 and len(page['replies'])==20
second=req('/api/receipts?after='+page['reply_cursor'])[1];assert len(second['replies'])==3
assert len({r['cursor'] for r in page['replies']+second['replies']})==23
excerpt=page['replies'][0]['excerpt'];assert excerpt['file']=='harbor/report.md' and len(excerpt['excerpt'].encode())<=2400
artifact=req('/artifact/'+excerpt['artifact']+'?line='+str(excerpt['line']));assert artifact[0]==200 and 'blue release lane' in artifact[1]['content']
log.append({'first_page_count':20,'second_page_count':3,'sample_reply':page['replies'][0],'artifact':artifact})
for path in ['/artifact/private.md','/artifact/memory-archive.md','/artifact/../config/console-operator-secret','/artifact/%2e%2e%2fconfig%2fconsole-operator-secret','/data/harbor/report.md']:
 result=req(path);assert result[0]==404;log.append({'confined_path':path,'status':result[0]})
(home/'data'/'learnings.md').symlink_to(home/'data/private.md')
assert req('/artifact/learnings.md')[0]==404
assert req('/artifact/harbor__report.md',auth=False)[0]==401
assert req('/api/session',extra={'Origin':'https://example.invalid'})[0]==403
assert req('/artifact/harbor__report.md?line=0')[0]==400
cursor=second['reply_cursor'];subprocess.run(['python3','bin/fm-console.py','--mark-curated',cursor],env=env,check=True,capture_output=True)
curated=req('/api/receipts')[1];assert curated['curated_through']==cursor and all(r['curated'] for r in curated['replies'])
start=time.monotonic();empty=req('/api/receipts?after='+cursor)[1];elapsed=time.monotonic()-start;assert empty['replies']==[]
db=home/'state/.inbox-receipts.sqlite3';assert stat.S_IMODE(db.stat().st_mode)==0o600
db.chmod(0o644);cli('receipts');assert stat.S_IMODE(db.stat().st_mode)==0o600
log.append({'curated_through':cursor,'empty_incremental_poll_seconds':round(elapsed,3),'projection_mode':oct(stat.S_IMODE(db.stat().st_mode)),'repaired_existing_0644':True})
(home/'expected.json').write_text(json.dumps({'cursor':cursor,'ids':ids}))
Path('/home/clif/.no-mistakes/evidence/01M37VRR2WA8H6FF9ZN9T0MHRH/live-http.json').write_text(json.dumps(log,indent=2))
print('Live HTTP: 23 durable exchanges, replay, 20+3 cursor pages, bounded report excerpt, confinement, curation, private projection passed.')
