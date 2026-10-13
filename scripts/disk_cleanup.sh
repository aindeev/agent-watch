#!/bin/zsh
# Safe disk upkeep (settings come from claude-watcher's .env: CLEANUP_REPO, CLEANUP_GH_REPO, STACK_PREFIX). Prints free space; cleans only when free < THRESHOLD_G (default 150).
# Rules: see memory disk-cleanup.md. Every check is re-done fresh each run.
set -u
setopt NULL_GLOB  # unmatched globs expand to nothing instead of aborting the rm
threshold=${THRESHOLD_G:-150}
free_g() { df -g /System/Volumes/Data | awk 'NR==2{print $4}'; }
before=$(free_g)
echo "free=${before}G threshold=${threshold}G"
[ "$before" -ge "$threshold" ] && [ "${1:-}" != "--force" ] && exit 0

main=${CLEANUP_REPO:-}            # main git checkout whose worktrees agents create (from .env)

# 1. Self-rebuilding caches
go clean -cache 2>/dev/null
rm -rf ~/Library/Caches/deno ~/.config/gcloud/logs/* $TMPDIR/node-compile-cache $TMPDIR/playwright-transform-cache-* $TMPDIR/go-build*
npm cache clean --force >/dev/null 2>&1
UV_LOCK_TIMEOUT=5 uv cache clean >/dev/null 2>&1
rm -rf ~/Library/Developer/Xcode/DerivedData/*
ls -d ~/.vscode/extensions/anthropic.claude-code-* 2>/dev/null | sort -V | sed '$d' | xargs rm -rf

# 2. Merged, clean, idle worktrees
[ -n "$main" ] && gh -R ${CLEANUP_GH_REPO} pr list --state merged --limit 3000 --json headRefName,headRefOid \
  --jq '.[]|"\(.headRefName) \(.headRefOid)"' > /tmp/merged_oids.txt || : > /tmp/merged_oids.txt
git -C $main worktree list --porcelain | awk '/^worktree /{print $2}' | while read p; do
  [ "$p" = "$main" ] && continue; [ -d "$p" ] || continue
  b=$(git -C "$p" branch --show-current); [ -n "$b" ] || continue
  grep -q "^$b $(git -C "$p" rev-parse HEAD)\$" /tmp/merged_oids.txt || continue
  [ -z "$(git -C "$p" status --porcelain)" ] || continue
  find "$p" \( -name node_modules -o -name .git \) -prune -o -type f -mmin -360 -print -quit | grep -q . && continue
  lsof +D "$p" 2>/dev/null | grep -q . && continue
  git -C $main worktree remove "$p" && echo "removed worktree $p"
done
git -C $main worktree prune

# 3. node_modules in worktrees idle 12h+
git -C $main worktree list --porcelain | awk '/^worktree /{print $2}' | while read p; do
  [ "$p" = "$main" ] && continue; [ -d "$p/node_modules" ] || continue
  find "$p" \( -name node_modules -o -name .git \) -prune -o -type f -mmin -720 -print -quit | grep -q . && continue
  lsof +D "$p/node_modules" 2>/dev/null | grep -q . && continue
  rm -rf "$p/node_modules" && echo "cleared node_modules $p"
done

# 3b. Per-agent Go build caches in /tmp (GOCACHE=/tmp/*gocache*): pure caches, safe to drop once idle 2h+
for d in /private/tmp/*gocache*(N/); do
  [ -d "$d" ] || continue
  find "$d" -type f -mmin -120 -print -quit 2>/dev/null | grep -q . && continue
  rm -rf "$d" && echo "cleared go cache $d"
done

# 3c. Per-agent Xcode DerivedData folders in /tmp (-derivedDataPath /tmp/...): caches, safe to drop once idle 2h+
for d in /private/tmp/*(N/); do
  [ -d "$d/ModuleCache.noindex" ] && [ -d "$d/Build" ] || continue
  find "$d" -type f -mmin -120 -print -quit 2>/dev/null | grep -q . && continue
  rm -rf "$d" && echo "cleared xcode derived data $d"
done

# 4. Docker: stopped containers, anonymous volumes, volumes of deleted worktrees
docker container prune -f >/dev/null 2>&1
docker volume prune -f >/dev/null 2>&1
for v in $(docker volume ls -q --filter dangling=true 2>/dev/null); do
  w=$(echo $v | sed -nE "s/.*_${STACK_PREFIX:-none}(.*)$/\\1/p"); [ -n "$w" ] || continue
  [ -d "${main}-$w" ] || docker volume rm $v >/dev/null 2>&1
done
docker image prune -f >/dev/null 2>&1

# 5. Claude session scratch untouched 24h
for s in /private/tmp/claude-$(id -u)/-Users-*/*(N/); do
  j=~/.claude/projects/${s:h:t}/${s:t}.jsonl; [ -f "$j" ] || continue
  [ -n "$(find "$j" -mmin -1440)" ] && continue
  [ -n "$(find "$s" -type f -mmin -1440 -print -quit 2>/dev/null)" ] && continue
  rm -rf "$s"
done
git -C $main worktree prune

echo "freed=$(( $(free_g) - before ))G now_free=$(free_g)G"
