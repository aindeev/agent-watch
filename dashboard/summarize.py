# Writes summaries.json: a short plain-English read of each session, via headless Claude.
import json,os,sys,hashlib,subprocess,time,concurrent.futures as cf
from lib import *
SP=SUMS
try:old=json.load(open(SP))
except Exception:old={}
PROMPT='''You are summarising one Claude Code session for {USER}, who runs several sessions at once and glances at a dashboard.
Read the digest and answer with JSON only (no fences):
{"short_title": "2 to 4 words naming the work, e.g. Checkout split PRs, Search reindex (no punctuation, no quotes)",
 "done": [up to 4 short past-tense items, most important first, each under 12 words, concrete (PR numbers ok)],
 "doing": "one plain sentence, under 25 words, what it is doing right now",
 "waiting_on_you": null OR "one sentence: exactly what {USER} must decide or do",
 "complete": true if the ORIGINAL request is fully finished,
 "progress": {"done": int, "total": int, "unit": "short plural noun, e.g. PRs merged"} : how far through the ORIGINAL request it is, judged from the conversation and subagent activity. Count concrete units the agent itself uses (PRs merged of planned, items done of list). If it has no countable plan, use done/10 as a rough tenths estimate with unit "tenths". Only count something done when it is actually finished (merged/shipped), not just started.}
waiting_on_you is non-null ONLY when the session has stopped and cannot make progress without {USER} (it asked them a question, needs approval, or stopped mid-way). Background work, CI, merge queues or production watches are NOT waiting on {USER}. If {USER} asked the agent a question, the agent owes the answer: that is NOT waiting on {USER}. Only an explicit request from the agent to {USER} that is still unanswered counts.
Plain words, no jargon beyond PR numbers and feature names.

DIGEST:
'''.replace('{USER}',config.USER_NAME)
def digest(sid):
    r=parse(sid);pr=progress(sid)
    if not r:return None,None
    q=time.time()-r['mtime']
    parts=[f'Title: {META[sid][0]}',f'Plan: {META[sid][1]}',f'Previous progress estimate: {pr}',f'Transcript quiet for {int(q/60)} min; background tasks or subagents active: {bg_active(sid)}']
    parts+=[f'USER (original request, {u[0]}): {u[1][:600]}' for u in r['users'][:2]]
    parts+=[f'SUBAGENT ACTIVITY: {a}' for a in activity(sid)]
    parts+=[f'USER ({u[0]}): {u[1][:600]}' for u in r['users'][-5:]]
    parts+=[f'CLAUDE ({a[0]}): {a[1][:1500]}' for a in r['asst'][-4:]]
    d='\n'.join(parts)
    key=hashlib.sha1(('\n'.join(parts[4:])+str(q>600)).encode()).hexdigest()
    return d,key
def run(sid):
    d,key=digest(sid)
    if not d:return sid,old.get(sid)
    o=old.get(sid) or {}
    if o.get('key')==key:return sid,o
    try:
        out=subprocess.run(['claude','-p','--model','sonnet','--output-format','text'],input=PROMPT+d,capture_output=True,text=True,timeout=180,cwd=HERE).stdout
        j=json.loads(out[out.index('{'):out.rindex('}')+1])
        j['key']=key;j['at']=time.time();return sid,j
    except Exception as e:
        return sid,o
# --idle: only agents Paseo shows as not running (cheap, run every minute so a finished or waiting agent's card
# catches up fast); without it, every agent (every few minutes)
idle_only='--idle' in sys.argv
todo=[s for s in META if not (idle_only and (SESS.get(s) or {}).get('status')=='running')]
with cf.ThreadPoolExecutor(5) as ex:
    res={**old,**dict(ex.map(run,todo))}
res={s:v for s,v in res.items() if s in META}
json.dump(res,open(SP+'.tmp','w'),indent=1);os.replace(SP+'.tmp',SP)
