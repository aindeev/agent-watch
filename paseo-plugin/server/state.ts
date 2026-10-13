import { readFile, writeFile, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { RpcInput } from "@getpaseo/plugin";
import { execFile } from "node:child_process";
import type { Need, WatchState, act, setQuiet } from "../shared/rpc";

// claude-watcher's dashboard/run.sh records its checkout here; CLAUDE_WATCHER_DIR overrides it.
async function findRoot(): Promise<string | null> {
  if (process.env.CLAUDE_WATCHER_DIR) return process.env.CLAUDE_WATCHER_DIR;
  try {
    return (await readFile(join(homedir(), ".config", "claude-watcher", "root"), "utf8")).trim() || null;
  } catch {
    return null;
  }
}

type CallStatus = { pausedUntil: number | null; reason: "hours" | "manual" | null; quietHours: string | null };

// The watcher writes call_status.json every minute with the pause in effect (manual pause or quiet hours).
async function readCallStatus(root: string): Promise<CallStatus> {
  try {
    const s = JSON.parse(await readFile(join(root, "call_status.json"), "utf8")) as CallStatus;
    if (s.pausedUntil && s.pausedUntil * 1000 > Date.now()) return { ...s, pausedUntil: s.pausedUntil * 1000 };
    return { pausedUntil: null, reason: null, quietHours: s.quietHours };
  } catch {
    return { pausedUntil: null, reason: null, quietHours: null };
  }
}

// Call-related lines only; TRIAGE and WATCHING are the coordinator's business.
const SHOWN = ["CALLING", "DELIVERED", "NO-ANSWER", "HELD", "SKIPPED", "RELAY", "ERROR"];

async function readEvents(root: string) {
  try {
    const lines = (await readFile(join(root, "events.log"), "utf8")).trim().split("\n");
    return lines
      .map((line) => ({ kind: line.split(" ")[0], text: line.slice(line.indexOf(" ") + 1) }))
      .filter((e) => SHOWN.includes(e.kind))
      .slice(-6);
  } catch {
    return [];
  }
}

async function readNeeds(root: string): Promise<Need[]> {
  try {
    return JSON.parse(await readFile(join(root, "needs.json"), "utf8")) as Need[];
  } catch {
    return [];
  }
}

// Runs claude-watcher's coord.py, so plugin actions behave exactly like the coordinator's and the phone's.
export async function handleAct({ sid, action, text }: RpcInput<typeof act>) {
  const root = await findRoot();
  if (!root) return { ok: false, message: "claude-watcher not found" };
  // "say" delivers the user's own words to any agent (answering its open question if it has one), even one on hold
  const args = action === "reply" ? ["say", sid, text ?? ""] : action === "callnow" ? ["callnow", sid] : ["resolve", sid, "The user will handle it in Paseo"];
  return await new Promise<{ ok: boolean; message: string }>((resolve) => {
    execFile("python3", ["coord.py", ...args], { cwd: root, timeout: 60_000 }, (err, stdout, stderr) => {
      resolve({ ok: !err, message: (err ? stderr || err.message : stdout).trim().slice(0, 300) });
    });
  });
}

export async function handleGetState(): Promise<WatchState> {
  const root = await findRoot();
  const empty: WatchState = {
    configured: false, root, updated: null, overall: 0, cards: [], needs: [], quietUntil: null, quietReason: null, quietHours: null, events: [],
  };
  if (!root) return empty;
  try {
    const s = JSON.parse(await readFile(join(root, "dashboard", "state.json"), "utf8"));
    const call = await readCallStatus(root);
    return {
      configured: true,
      root,
      updated: s.updated * 1000,
      overall: s.overall,
      cards: s.cards,
      needs: await readNeeds(root),
      quietUntil: call.pausedUntil,
      quietReason: call.reason,
      quietHours: call.quietHours,
      events: await readEvents(root),
    };
  } catch {
    return empty;
  }
}

export async function handleSetQuiet({ minutes }: RpcInput<typeof setQuiet>) {
  const root = await findRoot();
  if (!root) throw new Error("claude-watcher not found");
  const file = join(root, "quiet_until");
  if (minutes <= 0) {
    await rm(file, { force: true });
    // inside quiet hours, resuming overrides them until they next end
    const call = await readCallStatus(root);
    if (call.reason === "hours" && call.pausedUntil) await writeFile(join(root, "quiet_override_until"), String(call.pausedUntil / 1000));
    return { quietUntil: null };
  }
  const until = Date.now() + minutes * 60_000;
  // the watcher reads epoch seconds
  await writeFile(file, String(until / 1000));
  return { quietUntil: until };
}
