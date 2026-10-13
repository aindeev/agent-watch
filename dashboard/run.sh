#!/bin/zsh
# Rebuilds the dashboard every 20 seconds; refreshes AI summaries every minute for idle agents (whose cards change
# what the user must do) and every third minute for all. Summaries are cached, so unchanged agents cost nothing.
# Start with: nohup dashboard/run.sh >/dev/null 2>&1 &   (it outlives any terminal)
cd "$(dirname "$0")"
# lets the Paseo plugin find this checkout
mkdir -p ~/.config/claude-watcher && (cd .. && pwd) > ~/.config/claude-watcher/root
i=0;spid=""
while true; do
  # one summariser at a time, never blocking the 20-second rebuild
  if ! { [ -n "$spid" ] && kill -0 $spid 2>/dev/null; } && [ $((i % 3)) -eq 0 ]; then
    if [ $((i % 9)) -eq 0 ]; then python3 summarize.py 2>>err.log & else python3 summarize.py --idle 2>>err.log & fi
    spid=$!
  fi
  python3 gen.py 2>>err.log
  i=$((i+1)); sleep 20
done
