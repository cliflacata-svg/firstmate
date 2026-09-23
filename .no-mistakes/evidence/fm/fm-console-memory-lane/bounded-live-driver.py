import base64, fcntl, json, os, pathlib, shutil, socket, sqlite3, subprocess, time, urllib.request
root=pathlib.Path.cwd(); work=root/'.console-phase-live'; home=work/'home'; evidence=pathlib.Path('/home/clif/.no-mistakes/evidence/01M37VRR2WA8H6FF9ZN9T0MHRH')
for name in ('config','data','state/inbox/.replies'): (home/name).mkdir(parents=True,exist_ok=True)
(home/'config/console-operator-secret').write_text('isolated-live-validation-secret-123456')
(home/'config/console-operator-secret').chmod(0o600)
(home/'data/learnings.md').write_text('context\n'+'界'*1600+' boundedneedle '+'界'*1600+'\nend')
inbox=home/'state/inbox'
for n in range(1,46):
    ident=f'legacy-{n:04d}'
    (inbox/f'{ident}.note').write_text(f'id={ident}\n--\norder {n}\n')
    (inbox/'.replies'/ident).write_text(f'id={ident}\nseq={n}\n--\nboundedneedle answer {n}\n')
for n in range(1000): (home/'data'/f'retained-{n:04d}').mkdir(exist_ok=True)
guard=work/'guard'; guard.mkdir(exist_ok=True)
(guard/'sitecustomize.py').write_text('''import os, sys, stat
from pathlib import Path
home=Path(os.environ['FM_HOME']); prefix=str(home/'state/inbox')
def audit(event,args):
    if event=='sqlite3.connect':
        db=Path(args[0]); observed={}
        for suffix in ('','-journal','-wal','-shm'):
            p=Path(str(db)+suffix)
            if p.exists():
                mode=stat.S_IMODE(p.stat().st_mode); observed[suffix or 'database']=oct(mode)
                assert mode==0o600, (p,mode)
        with (home/'permissions.jsonl').open('a') as out:
            import json
            out.write(json.dumps(observed)+'\\n')
    if (home/'guard-enabled').exists() and event in ('open','os.scandir','os.listdir') and isinstance(args[0],(str,bytes)):
        path=os.fsdecode(args[0]); allowed=os.environ.get('RECEIPT_ALLOWED_ID','')
        targeted=allowed and path in (prefix+'/'+allowed+'.note',prefix+'/handled/'+allowed+'.note',prefix+'/.replies/'+allowed)
        if (path==prefix or path.startswith(prefix+'/')) and not targeted:
            raise RuntimeError('historical record access forbidden: '+path)
sys.addaudithook(audit)
original_scandir=os.scandir
class BoundedScan:
    def __init__(self,path): self.inner=original_scandir(path); self.count=0
    def __enter__(self): return self
    def __exit__(self,*args):
        self.inner.close()
        with (home/'candidate-counts.txt').open('a') as out: out.write(str(self.count)+'\\n')
    def __iter__(self): return self
    def __next__(self):
        item=next(self.inner); self.count+=1
        assert self.count<=40, 'candidate enumeration exceeded 40'
        return item
os.scandir=lambda path: BoundedScan(path) if str(path)==str(home/'data') else original_scandir(path)

''')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}; env.update(FM_HOME=str(home),PYTHONPATH=str(guard),PYTHONDONTWRITEBYTECODE='1')
with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
log=open(work/'server.log','w'); server=subprocess.Popen(['python3','bin/fm-console.py','--port',str(port)],env=env,stdout=log,stderr=log,umask=0o022)
results={'tested_head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'live':True,'transport':'authenticated HTTP to real fm-console.py subprocess; real fm-inbox.sh mutations','prior_visual_evidence':['orders-and-answers.png','view-source.png','curated-cursor.png','browser-validation.json']}
def get(path):
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,headers={'Authorization':'Basic '+base64.b64encode(b'operator:isolated-live-validation-secret-123456').decode()})
    with urllib.request.urlopen(req,timeout=15) as res: return json.load(res)
def cmd(args,allowed=''):
    p=subprocess.run([str(root/'bin/fm-inbox.sh')]+args,env=dict(env,RECEIPT_ALLOWED_ID=allowed),capture_output=True,text=True,timeout=10)
    assert p.returncode==0,(args,p.stdout,p.stderr)
    return p.stdout
def snapshot():
    with sqlite3.connect(home/'state/.inbox-receipts.sqlite3') as db: return dict(db.execute('SELECT id,payload FROM notes'))
try:
    for _ in range(100):
        try: get('/api/session'); break
        except OSError: time.sleep(.05)
    first=get('/api/receipts?after=')
    (home/'guard-enabled').touch()
    pages=[first]
    for _ in range(3): pages.append(get('/api/receipts?after='+pages[-1]['reply_cursor']))
    assert [len(p['replies']) for p in pages]==[20,20,5,0]
    assert [r['cursor'] for p in pages for r in p['replies']]==[f'{n:012d}' for n in range(1,46)]
    for p in pages:
        assert len(p['pending'])<=20 and len(p['handled'])<=20
        for r in p['replies']:
            e=r['excerpt']; assert isinstance(e,dict) and 'boundedneedle' in e['excerpt']
            assert len(e['excerpt'].encode())<=2400
    results['pages']=pages
    excerpt=first['replies'][0]['excerpt']; art=get('/artifact/'+excerpt['artifact']+'?line='+str(excerpt['line']))
    assert len(art['content'].encode())<=6000
    results['artifact']=art
    before=snapshot(); cmd(['drain','--ack','legacy-0001'],'legacy-0001'); after=snapshot()
    assert [k for k in before if before[k]!=after[k]]==['legacy-0001']
    updated=get('/api/receipts?after=000000000045'); assert updated['handled'][0]['id']=='legacy-0001'
    results['mutation']={'changed_records':['legacy-0001'],'live_response':updated,'historical_reads':'denied by active audit hook except mutation target'}
    with (home/'state/.inbox-receipts.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        # Drain intentionally reads pending notes, but must not acquire projection lock.
        (home/'guard-enabled').unlink(); cmd(['drain']); (home/'guard-enabled').touch()
    results['drain_while_projection_locked']='passed'
    database=home/'state/.inbox-receipts.sqlite3'
    assert database.stat().st_mode&0o777==0o600
    with sqlite3.connect(database) as db:
        db.execute('PRAGMA journal_mode=WAL'); db.execute('UPDATE metadata SET payload=payload'); db.commit()
        paths=[database,pathlib.Path(str(database)+'-wal'),pathlib.Path(str(database)+'-shm'),pathlib.Path(str(database)+'-journal')]
        paths[-1].touch()
        for p in paths: p.chmod(0o644)
        assert get('/api/receipts?after=000000000045')['replies']==[]
        assert all(p.stat().st_mode&0o777==0o600 for p in paths if p.exists())
    results['permissions_before_sqlite_connect']=[json.loads(s) for s in (home/'permissions.jsonl').read_text().splitlines()]
    results['candidate_enumeration_counts']=[int(x) for x in (home/'candidate-counts.txt').read_text().splitlines()]
    assert max(results['candidate_enumeration_counts'])<=40
    results['retained_task_directories']=1000
    results['verdict']='pass'
finally:
    server.terminate(); server.wait(timeout=10); log.close()
    evidence.mkdir(parents=True,exist_ok=True)
    (evidence/'bounded-live-validation.json').write_text(json.dumps(results,indent=2))
    shutil.copy2(work/'check.py',evidence/'bounded-live-driver.py')
    shutil.copy2(work/'server.log',evidence/'bounded-live-server.log')
print(json.dumps({'verdict':results.get('verdict'),'page_sizes':[len(p['replies']) for p in results['pages']],'evidence':str(evidence/'bounded-live-validation.json')}))
