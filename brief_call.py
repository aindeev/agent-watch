# Phone the user and read them a briefing, then take questions on it.
#   python3 brief_call.py <script.txt> [facts.txt] ["topic for the greeting"]
# The script is spoken word for word as the call's opening (no paraphrasing, not interruptible);
# afterwards the voice agent answers questions using only the script and the optional facts file.
import json,os,sys,time,urllib.request,urllib.error
import config,voice_config
ENV=config.ENV;NAME=config.USER_NAME

def el(method,path,body=None):
    req=urllib.request.Request('https://api.elevenlabs.io'+path,json.dumps(body).encode() if body else None,
        {'xi-api-key':ENV['ELEVENLABS_API_KEY'],'Content-Type':'application/json'},method=method)
    try:return json.load(urllib.request.urlopen(req,timeout=30))
    except urllib.error.HTTPError as e:sys.exit(f'{method} {path}: {e.code} {e.read().decode()[:500]}')

PROMPT=f'''You are {NAME}'s briefing line. You have just read {NAME} (and anyone listening with them) the briefing below, word for word.
Now take questions. Answer in one to three short spoken sentences, using only the briefing and the facts below; if they don't cover it, say so plainly.
Speak numbers the way a person would say them aloud. No acronyms. When they say they're done, or there are no questions, say goodbye and end the call.

BRIEFING:
{{{{script}}}}

FACTS:
{{{{facts}}}}'''

def ensure_agent():
    body={"name":f"Briefing line (calls {NAME})",
          "conversation_config":{
            "agent":{"first_message":"{{opening}}","language":"en","disable_first_message_interruptions":True,
                     "prompt":{"prompt":PROMPT,"built_in_tools":{"end_call":{"name":"end_call","description":"End the call when the listener is done.","params":{"system_tool_type":"end_call"}}}},
                     "dynamic_variables":{"dynamic_variable_placeholders":{"opening":"Hi.","script":"","facts":""}}},
            "conversation":{"max_duration_seconds":1200}}}
    voice_config.apply(body['conversation_config'])
    aid=ENV.get('EL_BRIEF_AGENT_ID')
    if aid:el('PATCH',f'/v1/convai/agents/{aid}',body);return aid
    aid=el('POST','/v1/convai/agents/create',body)['agent_id']
    with open(os.path.join(config.ROOT,'.env'),'a') as f:f.write(f'EL_BRIEF_AGENT_ID={aid}\n')
    return aid

if __name__=='__main__':
    script=open(sys.argv[1]).read().strip()
    facts=open(sys.argv[2]).read().strip() if len(sys.argv)>2 and sys.argv[2] else ''
    topic=sys.argv[3] if len(sys.argv)>3 else 'the briefing you asked for'
    aid=ensure_agent()   # also refreshes its settings
    opening=f"Hi {NAME}, it's your agent coordinator with {topic}. It takes about four minutes, and you can ask questions at the end.\n\n{script}\n\nAny questions?"
    r=el('POST','/v1/convai/sip-trunk/outbound-call',{'agent_id':aid,'agent_phone_number_id':ENV['EL_PHONE_ID'],'to_number':config.TO_NUMBER,
        'conversation_initiation_client_data':{'dynamic_variables':{'opening':opening,'script':script,'facts':facts}}})
    print(json.dumps(r))
