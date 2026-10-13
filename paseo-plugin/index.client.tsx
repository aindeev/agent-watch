import type { PluginClientContext } from "@getpaseo/plugin/client";
import { setPlayer } from "./client/chime";
import { contributePills } from "./client/pills";
import { AgentWatchScreen } from "./client/screen";
import { AgentWatchItem } from "./client/sidebar";

export default function contribute(client: PluginClientContext) {
  setPlayer((source) => client.playAudio(source));
  const stopScreen = client.addScreen({ id: "agent-watch", title: "Agent watch", Component: AgentWatchScreen });
  const stopItem = client.addSidebarHeaderItem({ id: "agent-watch", title: "Agent watch", Component: AgentWatchItem });
  const stopPills = contributePills(client);
  return () => {
    void stopScreen();
    void stopItem();
    stopPills();
  };
}
