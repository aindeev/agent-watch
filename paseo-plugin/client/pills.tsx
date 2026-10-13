import type { PluginButtonContentProps, PluginButtonRegistration, PluginClientContext } from "@getpaseo/plugin/client";
import { View } from "react-native";
import { AgentSummary, countable } from "./visual";
import { getState, type AgentCard } from "../shared/rpc";

const POLL_MS = 15_000;

// A pill above each tracked agent's message box with its progress ("14/19 PRs merged"), or "Needs you".
// Pressing it shows what the agent is doing and what it has done.
export function contributePills(client: PluginClientContext) {
  const pills = new Map<string, { pill: PluginButtonRegistration; label: string; workspaceId: string }>();
  const cards = new Map<string, AgentCard>();
  let needing = new Set<string>();
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;

  function Content({ agentId, theme }: PluginButtonContentProps & { agentId?: string }) {
    const card = agentId ? cards.get(agentId) : undefined;
    if (!card) return null;
    return (
      <View style={{ padding: 14, width: 320 }}>
        <AgentSummary card={card} theme={theme} needsYou={needing.has(card.sid)} />
      </View>
    );
  }

  const labelFor = (card: AgentCard, needsYou: boolean) =>
    needsYou ? "Needs you" : countable(card) ? `${card.progress!.done}/${card.progress!.total} ${card.progress!.unit}` : `${card.pct}%`;

  const sync = async () => {
    try {
      const state = await client.rpc(getState, {});
      if (stopped) return;
      needing = new Set(state.needs.map((n) => n.sid));
      const seen = new Set<string>();
      for (const card of state.cards) {
        if (!card.paseoId || !card.workspaceId) continue;
        seen.add(card.paseoId);
        cards.set(card.paseoId, card);
        const label = labelFor(card, needing.has(card.sid));
        const entry = pills.get(card.paseoId);
        if (entry && entry.workspaceId === card.workspaceId) {
          if (entry.label !== label) {
            entry.pill.update({ label, icon: needing.has(card.sid) ? "CircleAlert" : "Activity" });
            entry.label = label;
          }
          continue;
        }
        entry?.pill.remove();
        const pill = client.addComposerPill({
          id: "agent-watch-progress",
          workspaceId: card.workspaceId,
          agentId: card.paseoId,
          button: {
            title: "Agent progress",
            icon: needing.has(card.sid) ? "CircleAlert" : "Activity",
            label,
            behavior: { kind: "popover", Content },
          },
        });
        pills.set(card.paseoId, { pill, label, workspaceId: card.workspaceId });
      }
      for (const [agentId, entry] of pills) {
        if (!seen.has(agentId)) {
          entry.pill.remove();
          pills.delete(agentId);
          cards.delete(agentId);
        }
      }
    } catch {
      /* try again next poll */
    } finally {
      if (!stopped) timer = setTimeout(sync, POLL_MS);
    }
  };
  void sync();

  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
    for (const entry of pills.values()) entry.pill.remove();
    pills.clear();
  };
}
