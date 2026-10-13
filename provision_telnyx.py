# One-time phone line setup: buys a Telnyx number, connects it to ElevenLabs over SIP, and records the IDs in .env.
#   python3 provision_telnyx.py            (needs TELNYX_API_KEY and ELEVENLABS_API_KEY in .env; costs ~$1/month)
#   python3 provision_telnyx.py --country CA --area 604
# Telnyx hides numbers for some countries (e.g. Canada) until the account is verified; US numbers work right away
# and call any North American number at the same rate.
import json,os,sys,secrets,string,time,urllib.request,urllib.error,urllib.parse
import config
ENV=config.ENV
def req(base,method,path,body=None,headers={}):
    r=urllib.request.Request(base+path,json.dumps(body).encode() if body is not None else None,{'Content-Type':'application/json',**headers},method=method)
    try:return json.load(urllib.request.urlopen(r,timeout=30))
    except urllib.error.HTTPError as e:sys.exit(f'{method} {path} failed: {e.code} {e.read().decode()[:400]}')
tx=lambda m,p,b=None:req('https://api.telnyx.com/v2',m,p,b,{'Authorization':f"Bearer {ENV['TELNYX_API_KEY']}"})
el=lambda m,p,b=None:req('https://api.elevenlabs.io',m,p,b,{'xi-api-key':ENV['ELEVENLABS_API_KEY']})
def save(**kv):
    with open(os.path.join(config.ROOT,'.env'),'a') as f:
        for k,v in kv.items():f.write(f'{k}={v}\n')
    os.chmod(os.path.join(config.ROOT,'.env'),0o600)

args=dict(zip(sys.argv[1::2],sys.argv[2::2]))
country=args.get('--country','US');area=args.get('--area')
if 'EL_PHONE_ID' in ENV:sys.exit('Already provisioned (EL_PHONE_ID is in .env).')

print('balance:',tx('GET','/balance')['data']['balance'])
user='cw'+secrets.token_hex(4);pw=''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24))
ovp=tx('POST','/outbound_voice_profiles',{'name':'claude-watcher','whitelisted_destinations':['US','CA'],'traffic_type':'conversational','service_plan':'global'})['data']['id']
conn=tx('POST','/credential_connections',{'connection_name':'claude-watcher-elevenlabs','user_name':user,'password':pw,'sip_uri_calling_preference':'disabled',
    'inbound':{'ani_number_format':'+E.164','dnis_number_format':'+e164'},'outbound':{'outbound_voice_profile_id':ovp}})['data']['id']
q={'filter[country_code]':country,'filter[features][]':'voice','filter[limit]':'5'}
if area:q['filter[national_destination_code]']=area
nums=[n['phone_number'] for n in tx('GET','/available_phone_numbers?'+urllib.parse.urlencode(q))['data'] if '-' not in n['phone_number']]
if not nums:sys.exit(f'No orderable {country} numbers (they may be hidden until your Telnyx account is verified). Try --country US.')
num=nums[0];order=tx('POST','/number_orders',{'phone_numbers':[{'phone_number':num}],'connection_id':conn})['data']['id']
save(TELNYX_OVP_ID=ovp,TELNYX_CONN_ID=conn,TELNYX_SIP_USER=user,TELNYX_SIP_PASS=pw,TELNYX_NUMBER=num)
for _ in range(30):
    if tx('GET',f'/number_orders/{order}')['data']['status']=='success':break
    time.sleep(2)
pid=el('POST','/v1/convai/phone-numbers',{'phone_number':num,'label':'claude-watcher (Telnyx)','provider':'sip_trunk',
    'outbound_trunk_config':{'address':'sip.telnyx.com','transport':'tcp','media_encryption':'disabled','credentials':{'username':user,'password':pw}},
    'inbound_trunk_config':{'media_encryption':'allowed'}})['phone_number_id']
save(EL_PHONE_ID=pid)
print(f'Calls will come from {num}. Next: python3 create_agent.py')
