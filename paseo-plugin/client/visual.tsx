import type { PluginTheme } from "@getpaseo/plugin";
import { Text, View } from "react-native";
import type { AgentCard } from "../shared/rpc";

// One segment per unit when progress is countable (4 of 8 lanes = 8 segments, 4 filled); a smooth bar otherwise.
// "tenths" is the summariser's rough estimate for work with no countable plan: show it as a plain percentage.
export const countable = (card: AgentCard) => (card.progress && card.progress.unit !== "tenths" ? card.progress : null);

export function Segmented({ card, color, track, height = 8 }: { card: AgentCard; color: string; track: string; height?: number }) {
  const p = countable(card);
  if (p && p.total > 1 && p.total <= 40) {
    return (
      <View style={{ flexDirection: "row", gap: p.total > 20 ? 2 : 3 }} accessibilityLabel={`${p.done} of ${p.total} ${p.unit}`}>
        {Array.from({ length: p.total }, (_, i) => (
          <View key={i} style={{ flex: 1, height, borderRadius: 2, backgroundColor: i < p.done ? color : track }} />
        ))}
      </View>
    );
  }
  return (
    <View style={{ height, borderRadius: height / 2, backgroundColor: track, overflow: "hidden" }} accessibilityLabel={`${card.pct}%`}>
      <View style={{ width: `${Math.max(3, card.pct)}%`, height, backgroundColor: color }} />
    </View>
  );
}

export function stateColor(card: AgentCard, theme: PluginTheme, needsYou: boolean) {
  const c = theme.colors;
  if (needsYou || card.state === "you") return c.statusDanger;
  if (card.state === "done") return c.statusSuccess;
  if (card.state === "closed") return c.statusDanger;
  return c.accent;
}

const CHIP: Record<AgentCard["state"], string> = { you: "Needs you", work: "Working", done: "Done", closed: "Stopped" };

// A compact, mostly visual summary of one agent: status chip, big count, segmented bar, one line of "now", ticked items.
export function AgentSummary({ card, theme, needsYou }: { card: AgentCard; theme: PluginTheme; needsYou: boolean }) {
  const c = theme.colors;
  const color = stateColor(card, theme, needsYou);
  const p = countable(card);
  const running = card.status === "running";
  return (
    <View style={{ gap: 10 }}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
        <Text style={{ flex: 1, color: c.foreground, fontSize: 14, fontWeight: "700" }} numberOfLines={1}>
          {card.shortTitle || card.title}
        </Text>
        <View style={{ backgroundColor: color, borderRadius: 999, paddingHorizontal: 8, paddingVertical: 2 }}>
          <Text style={{ color: "#fff", fontSize: 10.5, fontWeight: "800" }}>{needsYou ? "NEEDS YOU" : CHIP[card.state].toUpperCase()}</Text>
        </View>
      </View>

      <View style={{ flexDirection: "row", alignItems: "flex-end", gap: 6 }}>
        <Text style={{ color, fontSize: 28, fontWeight: "800", lineHeight: 30 }}>{p ? p.done : `${card.pct}%`}</Text>
        {p ? <Text style={{ color: c.foregroundMuted, fontSize: 13, paddingBottom: 3 }}>/ {p.total} {p.unit}</Text> : null}
        <View style={{ flex: 1 }} />
        <Text style={{ color: c.foregroundMuted, fontSize: 11, paddingBottom: 3 }}>{running ? "● working now" : `idle ${card.quietMin}m`}</Text>
      </View>
      <Segmented card={card} color={color} track={c.surface2} />

      <Text style={{ color: needsYou ? c.statusDanger : c.foreground, fontSize: 12.5, fontWeight: needsYou ? "600" : "400" }} numberOfLines={2}>
        {needsYou || card.state === "you" ? card.need : card.doing}
      </Text>

      {card.done.length > 0 && (
        <View style={{ gap: 3 }}>
          {card.done.slice(0, 4).map((item) => (
            <View key={item} style={{ flexDirection: "row", gap: 6, alignItems: "center" }}>
              <Text style={{ color: c.statusSuccess, fontSize: 11 }}>✓</Text>
              <Text style={{ flex: 1, color: c.foregroundMuted, fontSize: 11.5 }} numberOfLines={1}>
                {item}
              </Text>
            </View>
          ))}
        </View>
      )}
    </View>
  );
}
