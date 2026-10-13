Agent watch shows how your Claude Code agents are doing, using claude-watcher (the companion project that phones you when an agent needs you).

It adds a sidebar item. A badge on it counts the agents that need you. The item opens a screen with one card per tracked agent, showing:
- what it has done so far;
- what it is doing now;
- what it needs from you, if anything;
- how far through its task it is.

Tap a card to open that agent. The screen also shows whether phone calls are paused, has buttons to pause calls for one or two hours or resume them, and lists the latest call activity.

## Setup

It reads files written by claude-watcher's dashboard loop on the same machine as the Paseo daemon. Starting the loop with `dashboard/run.sh` records where the checkout is. To use a different checkout, set CLAUDE_WATCHER_DIR in the daemon's environment instead. The plugin reads `dashboard/state.json`, `events.log` and `quiet_until` there. The pause buttons write `quiet_until`. Nothing leaves the machine.
