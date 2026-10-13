# Shared configuration: secrets and personal settings come from .env, the tracked sessions from sessions.json.
# Both files are gitignored; see .env.example and sessions.example.json.
import os,json,re
ROOT=os.path.dirname(os.path.abspath(__file__))

def _env():
    p=os.path.join(ROOT,'.env')
    if not os.path.exists(p):return {}
    out={}
    for l in open(p):
        if '=' not in l or l.lstrip().startswith('#'):continue
        k,v=l.split('=',1);out[k.strip()]=v.split(' #')[0].strip()
    return out
ENV=_env()

USER_NAME=ENV.get('USER_NAME','the user')
TO_NUMBER=ENV.get('TO_NUMBER','')                  # E.164 number the watcher phones
PR_LINK=ENV.get('PR_LINK','')                      # optional, e.g. https://github.com/org/repo/pull/  (links #1234 in summaries)
DASHBOARD_OUT=ENV.get('DASHBOARD_OUT','')             # optional: write the dashboard page somewhere other than dashboard/index.html
COORDINATOR_AGENT=ENV.get('COORDINATOR_AGENT','')   # Paseo agent id (or prefix) of the coordinator session; it and its children aren't tracked
CLAUDE_TMP=ENV.get('CLAUDE_TMP',f'/private/tmp/claude-{os.getuid()}')   # where Claude Code keeps per-session task output

# Quiet hours, local time, e.g. 21:00-08:00 (may wrap past midnight). Empty disables them.
QUIET_HOURS=ENV.get('QUIET_HOURS','')

def quiet_hours_end(t):
    """If epoch time t falls inside QUIET_HOURS, the epoch time they end; else None."""
    import time as _t
    if not QUIET_HOURS:return None
    a,b=[int(x.split(':')[0])*60+int(x.split(':')[1]) for x in QUIET_HOURS.split('-')]
    lt=_t.localtime(t);m=lt.tm_hour*60+lt.tm_min
    inside=(a<=m<b) if a<b else (m>=a or m<b)
    if not inside:return None
    mins_left=(b-m)%(24*60) or 24*60
    return int((t+mins_left*60)//60*60)

def encode(path):
    """Claude Code's folder name for a working directory: every non-alphanumeric character becomes '-'."""
    return re.sub(r'[^A-Za-z0-9]','-',path)

def load_sessions():
    """Optional extras per session from sessions.json: {session_id: dict(title, plan, cwd, links)}."""
    p=os.path.join(ROOT,'sessions.json')
    try:raw=json.load(open(p))
    except FileNotFoundError:return {}
    return {s['session_id']:dict(title=s.get('title',s['session_id'][:8]),plan=s.get('plan',''),cwd=s['cwd'],links=s.get('links',[])) for s in raw}
