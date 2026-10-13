import json,os,html,time,datetime,math
from lib import *
try:SUM=json.load(open(SUMS))
except Exception:SUM={}
e=html.escape
def ring(pct,color):
    r=26;c=2*math.pi*r;off=c*(1-pct/100)
    return f'''<svg width="64" height="64" viewBox="0 0 64 64" class="ring"><circle cx="32" cy="32" r="{r}" fill="none" stroke="var(--line)" stroke-width="7"/>
<circle cx="32" cy="32" r="{r}" fill="none" stroke="{color}" stroke-width="7" stroke-linecap="round" stroke-dasharray="{c:.1f}" stroke-dashoffset="{off:.1f}" transform="rotate(-90 32 32)"/>
<text x="32" y="37" text-anchor="middle" font-size="15" font-weight="700" fill="currentColor">{pct}%</text></svg>'''
CHECK='<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="var(--ok)"/><path d="M7 12.5l3.2 3.2L17 9" stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>'
SPIN='<svg class="ic spin" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="none" stroke="var(--line)" stroke-width="3"/><path d="M12 3a9 9 0 0 1 9 9" stroke="var(--run)" stroke-width="3" fill="none" stroke-linecap="round"/></svg>'
HAND='<svg class="ic pulse" viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="var(--warn)"/><path d="M12 6.5v7" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/><circle cx="12" cy="17.3" r="1.5" fill="#fff"/></svg>'
FLAG='<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="var(--ok)"/><path d="M6.5 12.5l3.8 3.8L18 8.5" stroke="#fff" stroke-width="2.8" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>'
cards=[];waiting=[];tot=[];data=[]   # data: the same cards as JSON, for the Paseo plugin
for sid in META:
    title,plan,pages=META[sid];r=parse(sid)
    if not r:continue
    sess=SESS.get(sid);pr=progress(sid);sm=SUM.get(sid) or {}
    if sess and sess.get('archived'):continue      # archived in Paseo: hidden
    quiet=time.time()-r['mtime'];bg=bg_active(sid)
    pct=round(100*pr[0]/max(pr[1],1)) if pr else 0
    complete=bool(sm.get('complete')) or (pr and pr[0]>=pr[1] and quiet>300 and not bg)
    if complete:pct=100
    tot.append(pct)
    need=None
    if not sess:state='closed'
    elif complete:state='done'
    elif sm.get('waiting_on_you') and quiet>180 and not bg:state='you';need=sm['waiting_on_you']
    elif quiet>900 and not bg and not EXTERNAL_WAIT.search(sm.get('doing') or ''):state='you';need=f'It stopped {ago(r["last"])} before finishing. Tell it to continue or give it direction.'
    else:state='work'
    if need:waiting.append((title,sess.get('name','?'),need))
    done=sm.get('done') or []
    doing=sm.get('doing') or '…'
    if state=='done':dicon,dlabel,dtext=FLAG,'Complete','The original request is done. It is waiting for your next request.'
    elif state=='you':dicon,dlabel,dtext=HAND,'Needs you',need
    elif state=='closed':dicon,dlabel,dtext=HAND,'Session closed','This terminal is no longer running.'
    else:dicon,dlabel,dtext=SPIN,'Doing now',doing
    link=next((p for p in pages if os.path.exists(p)),None)
    color={'done':'var(--ok)','you':'var(--warn)'}.get(state,'var(--run)')
    data.append(dict(sid=sid,title=title,shortTitle=(sm.get('short_title') or '').strip()[:40],name=(sess or {}).get('name',''),paseoId=(sess or {}).get('paseo_id'),state=state,pct=pct,
        status=(sess or {}).get('status'),workspaceId=(sess or {}).get('workspaceId'),quietMin=int(quiet/60),
        progress=dict(done=pr[0],total=pr[1],unit=pr[2]) if pr else None,done=done,doing=doing,need=need,waiting=sm.get("waiting_on_you") or None,summaryAt=sm.get("at"),lastActive=r["last"],link=link))
    cards.append(({'you':0,'work':1,'done':2,'closed':3}[state],f'''<section class="card s-{state}">
<header>{ring(pct,color)}<div><h2>{e(title)}</h2><div class="meta">{e(sess.get('name','') if sess else 'closed')} · active {ago(r['last'])}{f' · <a href="file://{link}">details</a>' if link else ''}</div></div></header>
<div class="cols"><div class="col"><h3>{CHECK} Done so far</h3><ul>{''.join(f'<li>{e(x)}</li>' for x in done) or '<li class="mut">summarising…</li>'}</ul></div>
<div class="col"><h3>{dicon} {dlabel}</h3><p>{e(dtext)}</p></div></div></section>'''))
overall=round(sum(tot)/max(len(tot),1))
if waiting:
    top=f'''<div class="alert"><div class="alert-h">{HAND} {len(waiting)} {'session needs' if len(waiting)==1 else 'sessions need'} you</div>
{''.join(f'<div class="alert-row"><b>{e(t)}</b> <span class="term">terminal {e(n)}</span><div>{e(x)}</div></div>' for t,n,x in waiting)}</div>'''
    ttl=f'({len(waiting)}) Needs you · Agent progress'
else:
    top=f'<div class="calm">{CHECK} Nothing needs you right now</div>';ttl='Agent progress'
now=datetime.datetime.now().strftime('%-I:%M %p')
page=f'''<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="60"><title>{ttl}</title>
<style>
:root{{--bg:#fafaf9;--fg:#1c1917;--mut:#78716c;--card:#fff;--line:#e7e5e4;--ok:#16a34a;--warn:#d97706;--run:#2563eb}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0c0a09;--fg:#e7e5e4;--mut:#a8a29e;--card:#1c1917;--line:#33302e}}}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,system-ui,sans-serif}}
main{{max-width:980px;margin:0 auto;padding:20px 16px 40px}}
.alert{{background:var(--warn);color:#fff;border-radius:12px;padding:18px 20px;margin-bottom:18px;box-shadow:0 0 0 4px #f59e0b55}}
.alert-h{{font-size:22px;font-weight:800;display:flex;align-items:center;gap:10px}} .alert .ic{{width:28px;height:28px}} .alert .ic circle:first-child{{fill:#fff3}}
.alert-row{{background:#0002;border-radius:8px;padding:10px 12px;margin-top:10px;font-size:15px}} .term{{font-size:12px;opacity:.85;margin-left:6px}}
.calm{{display:flex;align-items:center;gap:8px;color:var(--ok);font-weight:600;margin-bottom:14px}}
.head{{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:12px}} h1{{font-size:20px;margin:0}} .sub,.mut{{color:var(--mut)}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 18px;margin-bottom:12px}}
.s-you{{border:2px solid var(--warn)}} .s-done{{border-color:var(--ok)}}
.card header{{display:flex;align-items:center;gap:14px}} h2{{font-size:16px;margin:0}} .meta{{color:var(--mut);font-size:12.5px}} a{{color:inherit}}
.cols{{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:10px}} @media(max-width:640px){{.cols{{grid-template-columns:1fr}}}}
h3{{font-size:13px;margin:0 0 6px;display:flex;align-items:center;gap:7px;text-transform:uppercase;letter-spacing:.04em;color:var(--mut)}}
.ic{{width:20px;height:20px;flex:none}} ul{{margin:0;padding-left:18px}} li{{margin:2px 0}} .col p{{margin:0;font-size:14.5px}}
.s-you .col p{{font-weight:600}}
.spin{{animation:sp 1s linear infinite}} @keyframes sp{{to{{transform:rotate(360deg)}}}} .pulse{{animation:pu 1.4s ease-in-out infinite}} @keyframes pu{{50%{{opacity:.45}}}}
</style></head><body><main>
{top}
<div class="head"><h1>Agent progress · {overall}% overall</h1><span class="sub">updated {now}</span></div>
{''.join(c for _,c in sorted(cards,key=lambda x:x[0]))}
</main></body></html>'''
open(OUT+'.tmp','w').write(page);os.replace(OUT+'.tmp',OUT)
ST=os.path.join(HERE,'state.json')
order={'you':0,'work':1,'done':2,'closed':3}
json.dump(dict(updated=time.time(),overall=overall,cards=sorted(data,key=lambda c:order[c['state']])),open(ST+'.tmp','w'),indent=1);os.replace(ST+'.tmp',ST)
