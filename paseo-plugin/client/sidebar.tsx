import type { PluginSidebarItemProps } from "@getpaseo/plugin/client";
import { SidebarRow } from "@getpaseo/plugin/client/ui";
import { useEffect, useRef, useState } from "react";
import { Animated, Pressable, Text, View } from "react-native";
import type { AgentCard, Need } from "../shared/rpc";
import { AnswerPopover } from "./answer";
import { chimeForNew } from "./chime";
import { useWatchState } from "./screen";
import { callWhen, clock } from "./time";

// Sidebar names: drop a trailing "(...)" note, which is what makes most titles wrap.
const short = (title: string) => title.replace(/\s*\([^)]*\)\s*$/, "");

// An agent counts as idle once Paseo says it isn't running and its transcript has been quiet this long.
const IDLE_AFTER_MIN = 10;

// Right inset of Paseo's SidebarRow trailing slot, so hand-drawn rows line up with the header row.
const ROW_RIGHT = 16;

function MiniBar({ pct, color, track, small }: { pct: number; color: string; track: string; small?: boolean }) {
  const w = small ? 30 : 44;
  const h = small ? 4 : 5;
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 5, flexShrink: 0 }} accessibilityLabel={`${pct}% done`}>
      {/* fixed sizes that never shrink, so the header's bar and every row's bar share one column */}
      <View style={{ width: w, minWidth: w, flexShrink: 0, height: h, borderRadius: 2, backgroundColor: track, overflow: "hidden" }}>
        <View style={{ width: `${Math.max(4, Math.min(100, pct))}%`, height: h, borderRadius: 2, backgroundColor: color }} />
      </View>
      <Text style={{ color, fontSize: small ? 10 : 10.5, fontWeight: "700", width: 26, textAlign: "right" }}>{pct}%</Text>
    </View>
  );
}

// Pulses while the agent is actually running; still and dim when it is not.
function Dot({ color, pulsing }: { color: string; pulsing: boolean }) {
  const opacity = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    if (!pulsing) {
      opacity.setValue(1);
      return;
    }
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(opacity, { toValue: 0.25, duration: 700, useNativeDriver: false }),
        Animated.timing(opacity, { toValue: 1, duration: 700, useNativeDriver: false }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [pulsing, opacity]);
  return <Animated.View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: color, opacity }} />;
}

export function AgentWatchItem({ currentScreen, openScreen, openPopover, theme }: PluginSidebarItemProps) {
  const data = useWatchState().data;
  const [showDone, setShowDone] = useState(false);
  const c = theme.colors;
  const cards = data?.configured ? data.cards : [];
  const needs = data?.configured ? data.needs : [];
  const needing = new Set(needs.map((n) => n.sid));

  useEffect(() => {
    if (data?.configured) chimeForNew(needs.map((n) => `${n.sid}:${n.kind}`));
  }, [data?.configured, needs]);

  const openOverview = () => openScreen({ screenId: "agent-watch" });
  // The sidebar can't open an agent itself; the screen does it from these params, then the agent is shown.
  const openAgent = (card: AgentCard) =>
    card.paseoId ? openScreen({ screenId: "agent-watch", params: { open: card.paseoId, n: String(Date.now()) } }) : openOverview();
  const answer = (need: Need) => openPopover((props) => <AnswerPopover {...props} need={need} />);

  const working = cards.filter((card) => !needing.has(card.sid) && card.state !== "done");
  const done = cards.filter((card) => !needing.has(card.sid) && card.state === "done");

  const row = (card: AgentCard) => {
    const idle = card.status !== "running" && card.quietMin >= IDLE_AFTER_MIN;
    const color = card.state === "done" ? c.statusSuccess : card.state === "closed" ? c.statusDanger : idle ? c.foregroundMuted : c.accent;
    return (
      <Pressable
        key={card.sid}
        accessibilityRole="button"
        accessibilityLabel={`Open ${card.title}`}
        onPress={() => openAgent(card)}
        style={({ pressed }) => ({ flexDirection: "row", alignItems: "center", gap: 7, paddingLeft: 18, paddingRight: ROW_RIGHT, paddingVertical: 3, opacity: pressed ? 0.6 : 1 })}
      >
        <Dot color={color} pulsing={card.status === "running"} />
        <Text style={{ flex: 1, color: idle ? c.foregroundMuted : c.foreground, opacity: idle ? 0.75 : 0.9, fontSize: 12 }} numberOfLines={1}>
          {card.shortTitle || short(card.title)}
        </Text>
        {idle && card.state !== "done" ? (
          <Text style={{ color: c.foregroundMuted, fontSize: 10, width: 61, textAlign: "right" }}>idle {card.quietMin < 90 ? `${card.quietMin}m` : `${Math.round(card.quietMin / 60)}h`}</Text>
        ) : (
          <MiniBar pct={card.pct} color={color} track={c.surface2} small />
        )}
      </Pressable>
    );
  };

  return (
    <View>
      <SidebarRow
        icon="PhoneCall"
        label="Agent watch"
        active={currentScreen?.screenId === "agent-watch"}
        onPress={openOverview}
        trailing={
          needs.length > 0 ? (
            <View style={{ backgroundColor: c.statusDanger, borderRadius: 999, minWidth: 18, paddingHorizontal: 5, alignItems: "center" }}>
              <Text style={{ color: "#fff", fontSize: 11, fontWeight: "700" }}>{needs.length}</Text>
            </View>
          ) : data?.configured ? (
            <MiniBar pct={data.overall} color={c.accent} track={c.surface2} small />
          ) : undefined
        }
      />
      {data?.quietUntil && data.quietReason === "manual" ? (
        <SidebarRow id="quiet" icon="PhoneOff" label={`Calls paused until ${clock(data.quietUntil)}`} onPress={openOverview} />
      ) : null}

      {needs.map((need) => (
        // a solid red block, so an agent waiting on the user can't be missed; tap to answer right here
        <Pressable
          key={need.sid}
          accessibilityRole="button"
          accessibilityLabel={`${need.title} needs you. Answer`}
          onPress={() => answer(need)}
          style={({ pressed }) => ({
            backgroundColor: c.statusDanger, borderRadius: 8, marginHorizontal: 8, marginVertical: 3, paddingHorizontal: 10, paddingVertical: 7, opacity: pressed ? 0.85 : 1,
          })}
        >
          <Text style={{ color: "#fff", fontSize: 10.5, fontWeight: "800", letterSpacing: 0.6 }}>NEEDS YOU · TAP TO ANSWER</Text>
          <Text style={{ color: "#fff", fontSize: 13, fontWeight: "700" }} numberOfLines={1}>
            {cards.find((c2) => c2.sid === need.sid)?.shortTitle || short(need.title)}
          </Text>
          <Text style={{ color: "#fff", fontSize: 11.5, opacity: 0.92 }} numberOfLines={2}>
            {need.need}
          </Text>
          <Text style={{ color: "#fff", fontSize: 10.5, opacity: 0.8, marginTop: 2 }}>{callWhen(need)}</Text>
        </Pressable>
      ))}

      {working.map(row)}

      {done.length > 0 && (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={showDone ? "Hide finished agents" : "Show finished agents"}
          onPress={() => setShowDone(!showDone)}
          style={({ pressed }) => ({ flexDirection: "row", alignItems: "center", gap: 7, paddingLeft: 18, paddingRight: ROW_RIGHT, paddingVertical: 3, opacity: pressed ? 0.6 : 1 })}
        >
          <Text style={{ color: c.statusSuccess, fontSize: 11 }}>✓</Text>
          <Text style={{ flex: 1, color: c.foregroundMuted, fontSize: 12 }}>
            {done.length} done {showDone ? "▾" : "▸"}
          </Text>
        </Pressable>
      )}
      {showDone && done.map(row)}
    </View>
  );
}
