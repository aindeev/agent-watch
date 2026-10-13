import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

// One card per tracked agent, as written by claude-watcher's dashboard/gen.py.
export type AgentCard = {
  sid: string;
  title: string;
  // 2-4 word name from the summariser; falls back to the title
  shortTitle: string;
  // Paseo's own status for the agent: "running" while it is actually doing something
  status: string | null;
  workspaceId: string | null;
  // minutes since its transcript last changed
  quietMin: number;
  name: string;
  paseoId: string | null;
  state: "you" | "work" | "done" | "closed";
  pct: number;
  progress: { done: number; total: number; unit: string } | null;
  done: string[];
  doing: string;
  need: string | null;
  lastActive: string | null;
  link: string | null;
};

// Something the watcher would phone about, from needs.json.
export type Need = {
  sid: string;
  name: string;
  title: string;
  kind: "question" | "permission" | "waiting" | "stalled" | "finished" | "closed";
  need: string;
  options: string[];
  paseo_id: string | null;
  // epoch seconds the call would go out, or null once retries ran out
  callAt: number | null;
  held: boolean;
};

export type WatchState = {
  // false when claude-watcher can't be found or hasn't written its state yet
  configured: boolean;
  root: string | null;
  updated: number | null;
  overall: number;
  cards: AgentCard[];
  needs: Need[];
  // epoch ms; calls are held until then. reason "hours" = the nightly quiet hours, "manual" = a pause button
  quietUntil: number | null;
  quietReason: "hours" | "manual" | null;
  quietHours: string | null;
  // latest call activity from events.log, newest last
  events: { kind: string; text: string }[];
};

export const getState = defineRpc({
  name: "agentwatch.get",
  input: z.object({}),
  output: z.custom<WatchState>(),
});

// minutes > 0 pauses calls for that long; 0 resumes them.
export const setQuiet = defineRpc({
  name: "agentwatch.quiet",
  input: z.object({ minutes: z.number().min(0).max(24 * 60) }),
  output: z.object({ quietUntil: z.number().nullable() }),
});

// Act on something that needs the user: answer it (delivered as theirs), have the watcher call now,
// or say they'll handle it themselves (no call).
export const act = defineRpc({
  name: "agentwatch.act",
  input: z.object({ sid: z.string().min(1), action: z.enum(["reply", "callnow", "dismiss"]), text: z.string().optional() }),
  output: z.object({ ok: z.boolean(), message: z.string() }),
});
