# Creates (or updates) the ElevenLabs voice agent that phones the user when their Claude sessions need them.
import json,os,urllib.request,urllib.error
import config,voice_config
env=config.ENV
# The person's name is a per-call variable, so one agent can phone anyone (e.g. a team's shared agent behind a
# calling CLI); the watcher fills {{user_name}} on every call.
NAME='{{user_name}}'
KEY=env['ELEVENLABS_API_KEY']
PROMPT=f'''You are {NAME}'s agent coordinator. {NAME} runs several Claude Code agents at once. You are calling them because some of their agents need them.

The items that need {NAME}, numbered:
{{{{items}}}}

How to run the call:
- Your greeting has already read item 1 aloud: don't repeat it; just get the answer to it (or a skip), then go on to item 2 and the rest.
- Right after the greeting, never sit silent waiting. Anything {NAME} says before you have described an item (yes, hi, sure, go ahead) is NOT an answer: never record or pass on an answer to an item you have not read out.
- Go through the items one at a time, in order. For each: say the agent's name, then in one or two plain sentences what happened and exactly what it needs from them.
- Get their answer. If it's vague, ask one short follow-up so the agent can act on it. Read it back in a few words to confirm.
- If they say "skip" or "later" for an item, record that and move on.
- Items marked [question] are a multiple-choice question the agent is blocked on. Read the question and the options in plain words (short labels, a few words of each description, and say which one is recommended). They can pick one, or say something else entirely. Record their pick by the option's exact label plus anything they add.
- Items marked [permission] are an agent waiting for {NAME} to approve something it wants to run. Say in plain words what it wants to do (not the raw command unless it is short) and ask allow or deny. Start the instruction with exactly "Allow" or "Deny", then any reason or extra direction.
- Items marked [finished] (or a stall where the agent says it has done all it can) are agents with nothing left to do. Give them a two-sentence recap of what it achieved and anything it said is left, then ask what it should do next. "Nothing, it can stop" is a valid answer; record it as skip.
- If an agent is closed or dead, tell them; their answer for that one is usually whether to restart it and with what instruction.
- Keep it brisk: they're busy. No small talk, no reading of IDs or long PR lists.
- When every item has an answer (or they want to stop), say you'll pass it all on, then end the call.'''
DATA={"answers":{"type":"string","description":"JSON array, one object per item discussed: {\"item\": <item number>, \"instruction\": \"{NAME}'s answer rewritten as a clear, complete instruction to send to that agent, in their words where possible. For a [question] item, start with the exact label of the option they chose (or \\\"None of the options:\\\" if they chose none) followed by any extra direction. For a [permission] item, start with Allow or Deny\", \"skip\": true|false}. Only include items they actually answered or explicitly skipped."}}
DATA['answers']['description']=DATA['answers']['description'].replace("{NAME}'s",'their')
body={"name":"Agent Coordinator",
 "conversation_config":{
  "agent":{"first_message":f"Hi {NAME}, it's your agent coordinator. {{{{intro}}}}","language":"en",
   "prompt":{"prompt":PROMPT,"built_in_tools":{"end_call":{"name":"end_call","description":f"End the call once every item is answered or {NAME} wants to stop.","params":{"system_tool_type":"end_call"}}}},
   "dynamic_variables":{"dynamic_variable_placeholders":{"items":"1. (test) Example agent: needs a yes/no.","intro":"One agent needs you.","user_name":"Alex"}}},
  "conversation":{"max_duration_seconds":600}},
 "platform_settings":{"data_collection":DATA}}
voice_config.apply(body['conversation_config'])
aid=env.get('EL_AGENT_ID')
url='https://api.elevenlabs.io/v1/convai/agents'+(f'/{aid}' if aid else '/create')
req=urllib.request.Request(url,json.dumps(body).encode(),{'xi-api-key':KEY,'Content-Type':'application/json'},method='PATCH' if aid else 'POST')
try:r=json.load(urllib.request.urlopen(req))
except urllib.error.HTTPError as e:print(e.read().decode());raise
if not aid:
    open(os.path.join(config.ROOT,'.env'),'a').write(f"EL_AGENT_ID={r['agent_id']}\n")
print('agent',r.get('agent_id',aid))
