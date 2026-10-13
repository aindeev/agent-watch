import type { PluginTheme } from "@getpaseo/plugin";
import type { PluginScreenProps } from "@getpaseo/plugin/client";
import { useRpc } from "@getpaseo/plugin/client";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { getState, setQuiet, type AgentCard } from "../shared/rpc";
import { ago, clock } from "./time";
import { AgentSummary } from "./visual";

export const STATE_KEY = ["agent-watch", "state"];

export function useWatchState() {
  const fetchState = useRpc(getState);
  return useQuery({ queryKey: STATE_KEY, queryFn: () => fetchState({}), refetchInterval: 15_000 });
}

const LABEL: Record<AgentCard["state"], string> = {
  you: "Needs you",
  work: "Working",
  done: "Done, waiting for a next task",
  closed: "Not running",
};

function makeStyles(theme: PluginTheme, compact: boolean) {
  const c = theme.colors;
  return {
    screen: { flex: 1, backgroundColor: c.surface0 },
    content: { padding: compact ? 16 : 24, gap: 12, maxWidth: 860, width: "100%" as const, alignSelf: "center" as const },
    h1: { color: c.foreground, fontSize: 20, fontWeight: "700" as const },
    muted: { color: c.foregroundMuted, fontSize: 12.5 },
    text: { color: c.foreground, fontSize: 14, lineHeight: 20 },
    banner: { backgroundColor: c.statusDanger, borderRadius: 10, padding: 14, gap: 6 },
    bannerTitle: { color: "#fff", fontSize: 16, fontWeight: "700" as const },
    bannerText: { color: "#fff", fontSize: 13.5 },
    calm: { color: c.statusSuccess, fontWeight: "600" as const },
    row: { flexDirection: "row" as const, alignItems: "center" as const, gap: 8, flexWrap: "wrap" as const },
    card: { backgroundColor: c.surface1, borderColor: c.border, borderWidth: 1, borderRadius: 10, padding: 14, gap: 8 },
    cardYou: { borderColor: c.statusDanger, borderWidth: 2 },
    title: { color: c.foreground, fontSize: 15, fontWeight: "700" as const, flexShrink: 1 },
    pill: { borderRadius: 999, paddingHorizontal: 8, paddingVertical: 2 },
    pillText: { fontSize: 11.5, fontWeight: "600" as const },
    barTrack: { height: 6, borderRadius: 3, backgroundColor: c.surface2, overflow: "hidden" as const },
    section: { color: c.foregroundMuted, fontSize: 11.5, fontWeight: "700" as const, letterSpacing: 0.4 },
    button: { backgroundColor: c.surface2, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 7 },
    buttonText: { color: c.foreground, fontSize: 13, fontWeight: "600" as const },
  };
}

// The sidebar asks for an agent to be opened by passing ?open=<agent>&n=<nonce>; each nonce is acted on once.
let handledOpen: string | null = null;

export function AgentWatchScreen({ theme, layout, navigation, params }: PluginScreenProps) {
  useEffect(() => {
    if (params.open && params.n && params.n !== handledOpen && navigation) {
      handledOpen = params.n;
      navigation.openAgent({ agentId: params.open });
    }
  }, [params.open, params.n, navigation]);
  const s = useMemo(() => makeStyles(theme, layout.compact), [theme, layout.compact]);
  const state = useWatchState();
  const queryClient = useQueryClient();
  const quietRpc = useRpc(setQuiet);
  const quiet = useMutation({
    mutationFn: (minutes: number) => quietRpc({ minutes }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: STATE_KEY }),
  });
  const c = theme.colors;
  const data = state.data;
  const [expanded, setExpanded] = useState<string | null>(null);

  if (!data) {
    return (
      <View style={[s.screen, { padding: 24 }]}>
        <Text style={s.muted}>{state.isError ? "Couldn't reach the plugin." : "Loading…"}</Text>
      </View>
    );
  }
  if (!data.configured) {
    return (
      <View style={[s.screen, { padding: 24, gap: 8 }]}>
        <Text style={s.h1}>Agent watch</Text>
        <Text style={s.text}>
          No claude-watcher data yet. Start its dashboard loop (dashboard/run.sh), which records where the checkout is,
          or set CLAUDE_WATCHER_DIR for the Paseo daemon.
        </Text>
      </View>
    );
  }

  const needs = data.cards.filter((card) => card.state === "you");
  const pillColor = (st: AgentCard["state"]) =>
    st === "you" ? c.statusDanger : st === "done" ? c.statusSuccess : st === "closed" ? c.statusDanger : c.accent;

  return (
    <ScrollView style={s.screen} contentContainerStyle={s.content}>
      {needs.length > 0 ? (
        <View style={s.banner}>
          <Text style={s.bannerTitle}>
            {needs.length} {needs.length === 1 ? "agent needs" : "agents need"} you
          </Text>
          {needs.map((card) => (
            <Text key={card.name} style={s.bannerText}>
              {card.title}: {card.need}
            </Text>
          ))}
        </View>
      ) : (
        <Text style={s.calm}>Nothing needs you right now</Text>
      )}

      <View style={[s.row, { justifyContent: "space-between" }]}>
        <Text style={s.h1}>Agent progress · {data.overall}% overall</Text>
        <Text style={s.muted}>updated {data.updated ? ago(data.updated) : "?"}</Text>
      </View>

      <View style={[s.card, { flexDirection: "row", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap" }]}>
        <Text style={s.text}>
          {data.quietUntil
            ? data.quietReason === "hours"
              ? `Quiet hours: no calls until ${clock(data.quietUntil)}`
              : `Calls paused until ${clock(data.quietUntil)}`
            : `Calls are on${data.quietHours ? ` (quiet hours ${data.quietHours})` : ""}`}
        </Text>
        <View style={s.row}>
          {data.quietUntil ? (
            <Pressable accessibilityRole="button" style={s.button} onPress={() => quiet.mutate(0)}>
              <Text style={s.buttonText}>Resume calls</Text>
            </Pressable>
          ) : (
            [60, 120].map((m) => (
              <Pressable key={m} accessibilityRole="button" style={s.button} onPress={() => quiet.mutate(m)}>
                <Text style={s.buttonText}>Pause {m / 60}h</Text>
              </Pressable>
            ))
          )}
        </View>
      </View>

      <View style={[s.card, { padding: 0, gap: 0, overflow: "hidden" }]}>
        {data.cards.map((card, idx) => {
          const key = card.name || card.title;
          const isOpen = expanded === key;
          const tint = pillColor(card.state);
          return (
            <View
              key={key}
              style={[
                { paddingHorizontal: 12, paddingVertical: 8, gap: 3, borderTopWidth: idx ? 1 : 0, borderColor: c.border },
                card.state === "you" && { backgroundColor: c.statusDanger + "1f", borderLeftWidth: 4, borderLeftColor: c.statusDanger },
              ]}
            >
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={`${card.title}, ${LABEL[card.state]}`}
                onPress={() => setExpanded(isOpen ? null : key)}
                style={{ gap: 3 }}
              >
                <View style={[s.row, { flexWrap: "nowrap" }]}>
                  <Text style={[s.title, { flex: 1, fontSize: 14 }]} numberOfLines={1}>
                    {card.shortTitle || card.title}
                  </Text>
                  <View style={{ width: 70, height: 5, borderRadius: 3, backgroundColor: c.surface2, overflow: "hidden" }}>
                    <View style={{ width: `${Math.max(4, card.pct)}%`, height: 5, backgroundColor: tint }} />
                  </View>
                  <Text style={{ color: tint, fontSize: 11.5, fontWeight: "700", width: 64, textAlign: "right" }}>
                    {card.state === "you" ? "NEEDS YOU" : card.state === "done" ? "done" : `${card.pct}%`}
                  </Text>
                  {card.paseoId && navigation ? (
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={`Open ${card.title}`}
                      hitSlop={8}
                      onPress={() => navigation.openAgent({ agentId: card.paseoId! })}
                    >
                      <Text style={{ color: c.foregroundMuted, fontSize: 15 }}>↗</Text>
                    </Pressable>
                  ) : null}
                </View>
                <Text
                  style={[s.muted, card.state === "you" && { color: c.statusDanger, fontWeight: "600" }]}
                  numberOfLines={isOpen ? undefined : 1}
                >
                  {card.state === "you" ? card.need : card.doing}
                </Text>
              </Pressable>
              {isOpen && (
                <View style={{ paddingTop: 6, paddingBottom: 4 }}>
                  <AgentSummary card={card} theme={theme} needsYou={card.state === "you"} />
                </View>
              )}
            </View>
          );
        })}
      </View>

      {data.events.length > 0 && (
        <View style={[s.card, { gap: 4 }]}>
          <Text style={s.section}>RECENT CALLS</Text>
          {data.events
            .slice()
            .reverse()
            .map((e, i) => (
              <Text key={i} style={s.muted} numberOfLines={2}>
                <Text style={{ fontWeight: "700", color: c.foreground }}>{e.kind}</Text> {e.text}
              </Text>
            ))}
        </View>
      )}
    </ScrollView>
  );
}
