# Agent Watch

Keeps an eye on several long-running Claude Code agents running in Paseo. When one needs you, it phones you.

- **Dashboard** (`dashboard/`): a local HTML page that refreshes every minute. For each tracked session it shows what's done, what it's doing now and how far through the original request it is. Each session's transcript and its subagents and workflows are summarised by `claude -p --model sonnet`.
- **Watcher** (`watcher.py`): uses the same rules to notice when a session needs you:
  - it's blocked on a question dialog;
  - it's waiting for you to approve a command;
  - it's waiting on you;
  - it has stalled;
  - it has finished;
  - it has been archived or deleted in Paseo.
- **Phone calls**: an ElevenLabs voice agent calls you over a Telnyx number, goes through each item, and turns your spoken answers into instructions.
- **Delivering answers**: the watcher hands each answer straight to the agent through Paseo. Question dialogs get `paseo permit deny --message`, which returns your answer to the agent. Approval requests get `paseo permit allow` or `deny`. Everything else gets `paseo send`.
- **Coordinator triage** (`coord.py`): before phoning, the watcher gives the coordinator session 5 minutes to sort the item out itself. It can answer, nudge or dismiss it. If the coordinator doesn't act, or decides it needs you, the call goes out.

```
sessions ──► dashboard (summaries, progress) ──► index.html
   │
   └──► watcher ──TRIAGE──► coordinator session ──resolve──► (no call)
            │                      └──call──┐
            └──── 5 min, no decision ───────┴──► ElevenLabs + Telnyx ──► your phone
                                                     │
                       answers ◄─────────────────────┘
                         ├─ question / approval → paseo permit
                         └─ anything else       → paseo send
```

## Paseo plugin

`paseo-plugin/` adds an **Agent watch** item to Paseo's sidebar, with a badge that counts the agents that need you. It opens a native version of the dashboard:
- one card per agent, showing progress, what it's doing now and what it has done;
- tap a card to open that agent;
- whether calls are paused, with buttons to pause for one or two hours or resume;
- the latest call activity.

Install it with `paseo plugin install ./paseo-plugin`. After changing it, run `paseo plugin reload agent-watch`. It reads `dashboard/state.json`, which `gen.py` writes each minute, and finds this checkout through `~/.config/claude-watcher/root`, which `dashboard/run.sh` writes. Set `CLAUDE_WATCHER_DIR` instead to use a different checkout.

## Menu bar app

`menubar/` is **Agent Watch**, a native macOS menu bar app (SwiftUI, macOS 14+) showing the same picture as the Paseo plugin, without opening Paseo:

- The menu bar icon turns into a red pill with a count when agents need you.
- **Needs you** cards show what each agent needs. You can answer with one tap on a suggested answer, type a reply, have it phone you now (**Call me**), or keep it on your list without calls (**Later**). A countdown shows when the watcher will call.
- **Working** rows have segmented progress bars and expand to show what each agent has done, with a box to message it.
- A machine strip shows free disk, memory, load and containers, and a **Recent** list shows calls and cleanups.
- The call chip pauses calls (30 minutes to tomorrow morning) or resumes them.
- You get a notification when an agent starts needing you.

Every action goes through `coord.py`, so it behaves exactly like a phone answer. Build and install it with `menubar/build.sh`, which puts `Agent Watch.app` in `~/Applications` and opens it at login. Like the plugin, it finds this checkout through `~/.config/claude-watcher/root` or `CLAUDE_WATCHER_DIR`.

There are two ways to test it:

- `AgentWatch --snapshot out.png [--root dir] [--dark]` renders the window to a PNG.
- Running the binary with `AGENTWATCH_HARNESS=1 AGENTWATCH_SELFTEST=<dir>` opens it in an offscreen panel that never takes focus. It is driven by commands written to `<dir>/cmd` (`click x y`, `keys text\r`, `shot file.png`, `dump`). See `menubar/Sources/AgentWatch/SelfTest.swift`.

### Teammates (local network only)

Agent Watch can link with teammates' Agent Watch on the same network, so you can see each other's agents and message each other's coordinators. It works without a server and nothing goes over the internet.

- **Linking:** open Teammates, choose **Connect** and pick a nearby Mac (found with Bonjour, `_agentwatch._tcp`). Both screens show the same 6-digit code, and the link is made only when both people confirm it matches. This is numeric comparison, as in Bluetooth pairing. The initiator commits to its random value first, so a man in the middle can't force a matching code, and the code covers both Macs' identity keys.
- **Connections:** every later connection is mutually authenticated with each Mac's Ed25519 identity key, uses a fresh X25519 key exchange (forward secrecy), and encrypts every frame with ChaChaPoly. An altered, replayed or reordered frame ends the connection.
  - Connections from addresses outside the local network are refused, as are unknown keys.
  - A connection that doesn't authenticate within 15 seconds is dropped.
  - Frames are capped at 256 KB, and messages at 20 per minute per teammate.
  - The identity key lives in `~/Library/Application Support/AgentWatch/identity.key` (mode 0600).
- **What a teammate sees:** you choose per teammate, under **You share**:
  - **Counts:** how many of your agents need you, are working, or are done.
  - **Summary:** counts plus titles and progress (the default).
  - **Detail:** summary plus what each agent is doing.
  - Transcripts are never shared.
- **What a teammate can do:** send messages to you and your coordinator, and nothing else. They can't answer your agents, pause your calls or act on anything. Their messages arrive labelled as theirs, and the coordinator treats them as information, never as instructions.
- **Coordinator:** `coord.py peer ls | status <name> | inbox | send <name> "<text>"`. Incoming messages are also written to `events.log` as `PEER <name> (<from>): <text>`.
- **Testing:** `AgentWatch --selftest-crypto` runs the cryptography checks. The same harness drives two instances on one Mac, each with its own `AGENTWATCH_HOME`, `AGENTWATCH_NAME` and `AGENTWATCH_PORT`.

Some office and guest Wi-Fi networks block devices from talking to each other. On those, teammates won't find each other.

## Requirements

- macOS or Linux with Python 3.10+, Claude Code (`claude` on PATH), and Paseo with its daemon running (`paseo` on PATH).
- **For phone calls only** (everything else, including the dashboard, Paseo plugin, menu bar app and teammates, works without any keys):
  - Without a calling service: a [Telnyx](https://telnyx.com) account with about $10 of credit, and an API key. The phone number costs about $1/month.
  - **If your team has its own calling service:** point `CALL_CLI` at its command-line tool. Calls then use the team's phone line and keys, and you need none of your own. The tool must accept `<op> --input '<json>' --json --no-input` and print `{"ok": true, "data": …}` (see `.env.example` for the two ops it needs). If the tool is missing or refuses, the watcher falls back to the keys below and tries the tool again 30 minutes later.
  - Otherwise, a voice for the calls. Choose either:
    - [OpenAI](https://platform.openai.com) Realtime (`OPENAI_API_KEY`, the default engine, via `voice/realtime_bridge.py`);
    - [ElevenLabs](https://elevenlabs.io) (`ELEVENLABS_API_KEY`, the Starter plan works).
  - Each person uses their own keys and pays their own per-minute costs. Calls go to the `TO_NUMBER` in their own `.env`.
  - Without `TO_NUMBER`, the watcher still triages, resumes agents after usage limits and looks after the machine. It just never phones.

## Setup

```sh
cp .env.example .env && chmod 600 .env      # fill in USER_NAME, TO_NUMBER and both API keys
cp sessions.example.json sessions.json      # optional: extra context for some agents (see below)
python3 provision_telnyx.py                 # buys a number and connects it to ElevenLabs
python3 create_agent.py                     # creates the voice agent
python3 watcher.py --test                   # places one test call
```

Every open Paseo agent is tracked automatically, and agents never have to report their own progress. The summariser reads each transcript and works out:
- what's been done;
- what's happening now;
- how far along it is;
- a 2–4 word name.

Two kinds of agent are left out: the coordinator, named by `COORDINATOR_AGENT` in `.env`, and the agents it starts itself. Archived agents are hidden too.

`sessions.json` is optional. Use it only to give an agent extra context (`plan`) or links for its card:
- `session_id`: the Claude session ID (`paseo inspect <agent>`, or the transcript file name under `~/.claude/projects/`).
- `plan`: one or two sentences of context for the summariser.
- `links`: optional pages to link from the dashboard card.

## Running

```sh
nohup dashboard/run.sh >/dev/null 2>&1 & echo $! > dashboard/run.pid
nohup python3 -u watcher.py >> events.log 2>> watcher.err & echo $! > watcher.pid
open dashboard/index.html
```

Then, in a Claude Code session started in this folder (the coordinator), paste:

> You are the coordinator for my Claude Code sessions. Watch `events.log` with the Monitor tool: `tail -n 0 -F events.log watcher.err`, re-armed whenever it expires.
> - On a **TRIAGE** line, run `python3 coord.py show <name>` and decide within 5 minutes.
>   - Resolve it yourself when the answer follows from my earlier instructions, it's a plain stall, or the agent's recommended option is internal and reversible. Use `coord.py answer` for question dialogs and approvals, and `coord.py send` for anything else. Always say the answer came from you, not me.
>   - Escalate with `coord.py call <name> "<what I should hear>" [finished|stalled|waiting]` when it's irreversible or outward-facing, a product decision, ambiguous, a closed session, or an agent that has finished and needs its next task.
> - On a **RELAY** line (shown only when Paseo delivery failed), deliver the instruction yourself with `paseo send`.

Quiet hours: set `QUIET_HOURS=21:00-08:00` in `.env` (local time; it can wrap past midnight) and the watcher won't call during them. Anything that comes up is held and called together when they end. `coord.py quiet <minutes>` pauses calls on demand. `coord.py quiet 0`, or **Resume calls** in the Paseo plugin, turns them back on, including during quiet hours.

Stop everything with `kill $(cat watcher.pid) $(cat dashboard/run.pid)`.

## Files

| File | What it does |
|---|---|
| `config.py` | Loads `.env` and `sessions.json` |
| `dashboard/lib.py` | Reads Paseo agents and pending approvals, Claude Code transcripts, subagent/workflow activity |
| `dashboard/summarize.py` | Writes `summaries.json` (done / doing / waiting / progress) with headless Claude |
| `dashboard/gen.py` | Renders `index.html` |
| `watcher.py` | Detection, triage hand-off, calls, answer delivery through Paseo |
| `coord.py` | The coordinator's triage commands |
| `create_agent.py` | Creates or updates the ElevenLabs voice agent |
| `provision_telnyx.py` | One-time phone line setup |
| `brief_call.py` | Phone the user and read them a script word for word (uninterruptible), then take questions on it |
| `paseo-plugin/` | The Agent watch screen and sidebar item for Paseo |
| `menubar/` | Agent Watch, the macOS menu bar app |

## Privacy

Everything stays on your machine except two things:
- **The call content:** the questions, summaries and your answers go to ElevenLabs.
- **The dashboard summaries:** transcripts are summarised by Claude.

Call transcripts are saved in `calls/`, which is gitignored along with `.env`, `sessions.json` and all runtime state.

## License

MIT. See [LICENSE](LICENSE).
