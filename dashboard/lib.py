import json,os,html,re,time,datetime,glob
import sys
sys.path.insert(0,os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
HERE=os.path.dirname(os.path.abspath(__file__))
OUT=config.DASHBOARD_OUT or os.path.join(HERE,'index.html')
SUMS=os.path.join(HERE,'summaries.json')
import subprocess
def _paseo(*args):
    r=subprocess.run(['paseo',*args,'--json'],capture_output=True,text=True,timeout=30)
    if r.returncode:raise RuntimeError(r.stderr.strip()[:200])
    return json.loads(r.stdout or '[]')
HIDDEN=set()   # Claude session ids whose Paseo agent is archived or deleted
def paseo_agents():
    """Live Paseo agents keyed by Claude session id. If the daemon can't be reached, every known agent is
    assumed alive (better than reporting them all closed)."""
    try:live={a['id']:a for a in _paseo('ls','-a')}
    except Exception:live=None
    out={}
    for f in glob.glob(os.path.expanduser('~/.paseo/agents/*/*.json')):
        try:d=json.load(open(f))
        except Exception:continue
        sid=(d.get('runtimeInfo') or {}).get('sessionId') or (d.get('persistence') or {}).get('sessionId')
        if not sid:continue
        # archived (Paseo stamps archivedAt and leaves it out of `paseo ls`) or deleted: hide it everywhere
        if d.get('archivedAt') or (live is not None and d['id'] not in live):HIDDEN.add(sid);continue
        a=(live or {}).get(d['id'],{})
        out[sid]=dict(paseo_id=d['id'],name=d['id'][:7],title=a.get('name') or d.get('title') or '',
                      status=a.get('status') or d.get('lastStatus'),labels=d.get('labels') or {},cwd=d.get('cwd'),
                      archived=bool(a.get('archived') or a.get('archivedAt') or d.get('archivedAt')),workspaceId=d.get('workspaceId'))
    return out
def pending():
    """{paseo agent id: [pending permission requests]}; AskUserQuestion dialogs appear here too."""
    out={}
    try:
        for p in _paseo('permit','ls'):out.setdefault(p['agentId'],[]).append(p)
    except Exception:pass
    return out
SESS=paseo_agents()
# Tracked: every open Paseo agent, except the coordinator itself and agents it started (tests, helpers).
# sessions.json is optional and only adds a plan or links for an agent.
def _excluded(a):
    me=config.COORDINATOR_AGENT
    return bool(me) and (a['paseo_id'].startswith(me) or a['labels'].get('paseo.parent-agent-id','').startswith(me)) \
        or bool(a['labels'].get('cwtest'))
_extra=config.load_sessions()
CFG={sid:dict(title=a['title'] or (_extra.get(sid) or {}).get('title',''),plan=(_extra.get(sid) or {}).get('plan',''),
              cwd=a['cwd'],links=(_extra.get(sid) or {}).get('links',[]))
     for sid,a in SESS.items() if not _excluded(a)}
# title: Paseo's live name wins, since agents get re-tasked; the plan from sessions.json may be out of date
META={sid:((SESS.get(sid) or {}).get('title') or c['title'],c['plan'],c['links']) for sid,c in CFG.items() if sid not in HIDDEN}
def proj(sid):
    """Folder holding a session's transcript, subagents and workflows."""
    return os.path.expanduser('~/.claude/projects/'+config.encode(CFG[sid]['cwd'])+'/')
def transcript(sid):return proj(sid)+sid+'.jsonl'
def txt(c):
    if isinstance(c,str):return c
    return '\n'.join(b.get('text','') for b in c if isinstance(b,dict) and b.get('type')=='text')
def tail_lines(p,n=6_000_000):
    sz=os.path.getsize(p)
    with open(p,'rb') as fh:
        fh.seek(max(0,sz-n));d=fh.read().decode('utf-8','ignore')
    return d.split('\n')[1:]
def parse(sid):
    p=transcript(sid)
    if not os.path.exists(p):return None
    users=[];asst=[];last=None;cwd=None;subs=0;tools=[]
    for line in tail_lines(p):
        try:o=json.loads(line)
        except:continue
        if o.get('isSidechain'):continue
        last=o.get('timestamp',last);cwd=o.get('cwd',cwd)
        m=o.get('message') or {}
        c=m.get('content')
        if o.get('type')=='user' and not o.get('isMeta'):
            t=txt(c or '')
            if t and not t.lstrip().startswith('<') and not (isinstance(c,list) and any(b.get('type')=='tool_result' for b in c if isinstance(b,dict))):
                users.append((o['timestamp'],t))
        elif o.get('type')=='assistant' and isinstance(c,list):
            t=txt(c)
            if t.strip():asst.append((o['timestamp'],t))
            for b in c:
                if b.get('type')=='tool_use':
                    tools.append((o['timestamp'],b['name'],b.get('input') or {}))
    # pick the last substantive status message (longest of last 3, prefer >200 chars)
    status=None
    for a in reversed(asst):
        if len(a[1])>250:status=a;break
    if not status and asst:status=asst[-1]
    tl=tools[-1] if tools else None
    return dict(users=users,asst=asst,status=status,last=last,cwd=cwd,tool=tl,mtime=os.path.getmtime(p))
def ago(ts):
    if not ts:return '?'
    t=datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
    s=(datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()
    return f'{int(s)}s ago' if s<90 else f'{int(s/60)}m ago' if s<5400 else f'{s/3600:.1f}h ago'
def md(s):
    s=html.escape(s.strip())
    s=re.sub(r'\*\*(.+?)\*\*',r'<b>\1</b>',s)
    s=re.sub(r'`([^`]+)`',r'<code>\1</code>',s)
    if config.PR_LINK:s=re.sub(r'#(\d{3,6})\b',lambda m:f'<a href="{config.PR_LINK}{m[1]}">#{m[1]}</a>',s)
    lines=s.split('\n');out=[]
    for l in lines:
        if l.startswith('|'):
            cells=[x.strip() for x in l.strip('|').split('|')]
            if all(re.fullmatch(r':?-+:?',x) for x in cells if x):continue
            out.append('<tr>'+''.join(f'<td>{x}</td>' for x in cells)+'</tr>')
        else:out.append(l if l.strip() else '<br>')
    s='\n'.join(out)
    s=re.sub(r'((?:<tr>.*</tr>\n?)+)',r'<table>\1</table>',s)
    return s.replace('\n','<br>').replace('</tr><br>','</tr>')
def tooldesc(t):
    if not t:return ''
    n,i=t[1],t[2]
    d=i.get('description') or i.get('file_path') or i.get('sql') or i.get('command') or ''
    return f'{n}: {str(d)[:120]}'
def progress(sid):
    # (done,total,label) as judged by the summarizer from the agent's own transcript and subagents
    try:
        p=json.load(open(SUMS)).get(sid,{}).get('progress') or {}
        d,t=int(p['done']),int(p['total'])
        return (min(d,t),t,p.get('unit') or 'steps') if t>0 else None
    except Exception:return None
def _last_text(path,n=1_500_000):
    for line in reversed(tail_lines(path,n)):
        try:o=json.loads(line)
        except Exception:continue
        if o.get('type')=='assistant':
            t=txt((o.get('message') or {}).get('content') or [])
            if t.strip():return t.strip()
    return ''
def activity(sid,window=3*3600):
    """What the agent's workflows and subagents have been doing lately, read from their own transcripts."""
    out=[];base=proj(sid)+'subagents';now=time.time()
    for root,_,files in os.walk(base):
        for f in files:
            fp=os.path.join(root,f);age=now-os.path.getmtime(fp)
            if age>window:continue
            if f=='journal.jsonl':
                for line in tail_lines(fp,200_000)[-12:]:
                    try:o=json.loads(line)
                    except Exception:continue
                    if o.get('type')=='started':out.append((age,f"workflow step started: {o.get('label')} ({o.get('phase')})"))
                    elif o.get('type')=='result':out.append((age,f"workflow step finished: {json.dumps(o.get('result'))[:300]}"))
            elif f.endswith('.jsonl'):
                try:desc=json.load(open(fp[:-6]+'.meta.json')).get('description','subagent')
                except Exception:desc='subagent'
                out.append((age,f"subagent '{desc}': {_last_text(fp)[-500:]}"))
    out.sort()
    return [x for _,x in out[:8]]
ASK=re.compile(r'(\?\s*$|want me to|should i |shall i |your call|let me know|do you want|which (one|option)|approve|needs? your|waiting (on|for) you|before i (merge|ship))',re.I|re.M)
def bg_active(sid):
    if (SESS.get(sid) or {}).get('status')=='running':return True
    # background shells write to tasks/; workflows and subagents write their own transcripts under subagents/
    d=f"{config.CLAUDE_TMP}/{config.encode(CFG[sid]['cwd'])}/{sid}/tasks"
    try:
        if any(time.time()-os.path.getmtime(os.path.join(d,f))<600 for f in os.listdir(d)):return True
    except Exception:pass
    for root,_,files in os.walk(proj(sid)+'subagents'):
        if any(time.time()-os.path.getmtime(os.path.join(root,f))<600 for f in files if f.endswith('.jsonl')):return True
    return False
def verdict(sid,r,pr,alive):
    quiet=time.time()-r['mtime']
    last_a=r['asst'][-1][1] if r['asst'] else ''
    tail=last_a.strip().split('\n')[-1] if last_a else ''
    user_after=r['users'] and r['asst'] and r['users'][-1][0]>r['asst'][-1][0]
    done=pr and pr[0]>=pr[1]
    if not alive:return ('closed','Session closed','The session is no longer running.')
    if quiet<300 or (bg_active(sid) and not done) or user_after:
        return ('work','Working on your request','It is still working; you don\'t need to do anything.')
    if ASK.search(tail):
        return ('you','Waiting on you: it asked you something',tail[:400])
    if done:
        return ('done','✓ Done: ready for your next request','The original request is complete. Nothing will happen until you give it a follow-up.')
    return ('you','Stopped before finishing: waiting on you',f'It went quiet {ago(r["last"])} at {pr[0] if pr else "?"}/{pr[1] if pr else "?"}. Say "continue" or give it direction.')

# quiet but waiting on something outside the session (CI, a merge queue, a deploy, a retry loop): not stuck
EXTERNAL_WAIT=re.compile(r'\b(watch\w*|waiting\b|wait\w* (on|for)|merge queue|mergify|queued|re-?run\w*|retr(y|ies|ying)|CI\b|checks?|deploy\w*|auto-?merge)',re.I)
