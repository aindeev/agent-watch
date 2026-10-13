# Shared voice settings for every ElevenLabs agent here, tuned to sound like a person on the phone.
# Applied by create_agent.py (the coordinator) and brief_call.py (briefings).
import config

# Listening noises that shouldn't cut the agent off mid-sentence ("mm-hmm"). Pure noises only. Real words like "yes", "yeah", "okay" or "right" must stay out: they are often answers,
# and anything on this list is dropped even when it answers a question the agent just asked.
BACKCHANNELS = ["mm-hmm", "mhm", "uh-huh", "hmm", "uh", "um", "I see", "go on"]

STYLE = """
How to talk (this is a phone call, not a document):
- Every reply is ONE short sentence, under fifteen words. Talk like a busy colleague: "Got it, I'll tell Checkout." Not "Understood, I'll pass that along: Checkout should..."
- Never explain what you're about to do, never restate their whole answer, never say "just to confirm" more than once a call.
- Never read lists, IDs, links or PR numbers unless asked.
- After you say something that needs an answer, stop and wait. Don't stack questions.
- If you're interrupted, stop at once and respond to what they said. Don't restart your last sentence from the top.
- "Mm-hmm" while you're talking means "keep going". But "yes", "yeah", "right" or "okay" right after you've asked something IS the answer: take it and move on. Never ask the same question twice.
- Use skip_turn ONLY if they explicitly say "hang on", "one sec", "wait", or are clearly speaking to someone else in the room. Never use it right after you've asked a question or when they've answered you.
- If you didn't catch something or it's ambiguous, ask one short question ("Sorry, was that book the meeting, or prep for it?"). Never guess an answer.
- Confirm answers in five words or fewer ("Got it, watch production."), then move on.
- Say numbers the way a person would: "about one and a half million", "fifteen of nineteen".
- If a voicemail greeting or recording answers, use voicemail_detection and end the call without leaving a message."""

def keywords():
    """Names the speech recogniser should expect (VOICE_KEYWORDS in .env, comma separated)."""
    return [k.strip() for k in config.ENV.get('VOICE_KEYWORDS', '').split(',') if k.strip()]

def apply(conversation_config: dict) -> dict:
    """Merge the shared turn-taking, listening and model settings into an agent's conversation_config."""
    cc = conversation_config
    cc['turn'] = {
        **cc.get('turn', {}),
        'turn_model': 'turn_v3',             # ElevenLabs' latest end-of-turn model: listens to how you speak, not just silence
        'turn_eagerness': 'normal',          # turn_v3 already handles mid-thought pauses; 'patient' added lag to every reply
        'speculative_turn': True,            # start preparing a reply while you finish, for lower latency
        'turn_timeout': 10,
        'silence_end_call_timeout': 45,      # hang up if the line goes dead
        'interruption_ignore_terms': BACKCHANNELS,
        'merge_with_default_ignore_terms': False,   # the defaults include words that are often real answers
        'soft_timeout_config': {'timeout_seconds': 2.0, 'use_llm_generated_message': True, 'message': 'One sec.'},
    }
    cc['vad'] = {**cc.get('vad', {}), 'background_voice_detection': True}   # ignore other voices in the room
    cc['asr'] = {**cc.get('asr', {}), 'quality': 'high', 'keywords': keywords()}
    agent = cc.setdefault('agent', {})
    prompt = agent.setdefault('prompt', {})
    prompt.update({
        'llm': 'claude-sonnet-5',            # strong at following the call plan; no reasoning, so replies start fast
        'reasoning_effort': 'none',
        'temperature': 0.3,
        'prompt': prompt.get('prompt', '') + '\n' + STYLE,
    })
    tools = prompt.setdefault('built_in_tools', {})
    tools['skip_turn'] = {'name': 'skip_turn', 'description': 'Stay quiet only when the user explicitly asks you to wait, or is talking to someone else in the room. Never right after you asked a question.',
                          'params': {'system_tool_type': 'skip_turn'}}
    tools['voicemail_detection'] = {'name': 'voicemail_detection', 'description': 'End the call if a voicemail system or recording answers.',
                                    'params': {'system_tool_type': 'voicemail_detection'}}
    return cc
