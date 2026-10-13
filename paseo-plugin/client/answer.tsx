import type { PluginPopoverProps } from "@getpaseo/plugin/client";
import { useRpc } from "@getpaseo/plugin/client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Pressable, ScrollView, Text, TextInput, View } from "react-native";
import { act, type Need } from "../shared/rpc";
import { callWhen } from "./time";

const KIND: Record<Need["kind"], string> = {
  question: "It asked you a question",
  permission: "It wants approval",
  waiting: "It is waiting on you",
  stalled: "It has stopped",
  finished: "It finished: what next?",
  closed: "It is not running",
};

// Answer an agent from the sidebar: pick an option or type a reply; or call now / handle it yourself.
export function AnswerPopover({ need, theme, close }: PluginPopoverProps & { need: Need }) {
  const c = theme.colors;
  const [text, setText] = useState("");
  const queryClient = useQueryClient();
  const run = useRpc(act);
  const action = useMutation({
    mutationFn: (input: { action: "reply" | "callnow" | "dismiss"; text?: string }) => run({ sid: need.sid, ...input }),
    onSuccess: (result) => {
      void queryClient.invalidateQueries({ queryKey: ["agent-watch", "state"] });
      if (result.ok) close();
    },
  });
  const reply = (t: string) => t.trim() && action.mutate({ action: "reply", text: t.trim() });
  const btn = (bg: string) => ({ backgroundColor: bg, borderRadius: 7, paddingHorizontal: 11, paddingVertical: 7 });

  return (
    <ScrollView style={{ maxHeight: 520 }} contentContainerStyle={{ padding: 14, gap: 10, width: 340 }}>
      <Text style={{ color: c.statusDanger, fontSize: 11, fontWeight: "800", letterSpacing: 0.5 }}>{KIND[need.kind].toUpperCase()}</Text>
      <Text style={{ color: c.foreground, fontSize: 15, fontWeight: "700" }}>{need.title}</Text>
      <Text style={{ color: c.foreground, fontSize: 13, lineHeight: 19 }}>{need.need}</Text>

      {need.options.length > 0 && (
        <View style={{ gap: 6 }}>
          {need.options.map((option) => (
            <Pressable key={option} accessibilityRole="button" onPress={() => reply(option)} style={btn(c.surface2)}>
              <Text style={{ color: c.foreground, fontSize: 13, fontWeight: "600" }}>{option}</Text>
            </Pressable>
          ))}
        </View>
      )}

      <TextInput
        value={text}
        onChangeText={setText}
        placeholder={need.options.length ? "Or type something else…" : "Your answer…"}
        placeholderTextColor={c.foregroundMuted}
        multiline
        // Return sends, Shift-Return adds a line (a multiline input otherwise swallows Return as a newline)
        submitBehavior="submit"
        onSubmitEditing={() => reply(text)}
        onKeyPress={(e) => {
          const ev = e.nativeEvent as unknown as { key: string; shiftKey?: boolean; preventDefault?: () => void };
          if (ev.key === "Enter" && !ev.shiftKey) {
            (e as unknown as { preventDefault?: () => void }).preventDefault?.();
            reply(text);
          }
        }}
        style={{ color: c.foreground, borderColor: c.border, borderWidth: 1, borderRadius: 7, padding: 8, minHeight: 56, fontSize: 13 }}
      />
      <View style={{ flexDirection: "row", gap: 6, flexWrap: "wrap" }}>
        <Pressable accessibilityRole="button" disabled={!text.trim() || action.isPending} onPress={() => reply(text)} style={[btn(c.accent), !text.trim() && { opacity: 0.5 }]}>
          <Text style={{ color: c.accentForeground, fontSize: 13, fontWeight: "700" }}>Send</Text>
        </Pressable>
        <Pressable accessibilityRole="button" onPress={() => action.mutate({ action: "callnow" })} style={btn(c.surface2)}>
          <Text style={{ color: c.foreground, fontSize: 13 }}>Call me now</Text>
        </Pressable>
        <Pressable accessibilityRole="button" onPress={() => action.mutate({ action: "dismiss" })} style={btn(c.surface2)}>
          <Text style={{ color: c.foreground, fontSize: 13 }}>I'll handle it</Text>
        </Pressable>
      </View>
      <Text style={{ color: c.foregroundMuted, fontSize: 11.5 }}>
        {action.isPending ? "Sending…" : action.data && !action.data.ok ? `Didn't work: ${action.data.message}` : callWhen(need)}
      </Text>
    </ScrollView>
  );
}
