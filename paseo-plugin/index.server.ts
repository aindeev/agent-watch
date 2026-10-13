import type { PluginServerContext } from "@getpaseo/plugin/server";
import { handleAct, handleGetState, handleSetQuiet } from "./server/state";
import { act, getState, setQuiet } from "./shared/rpc";

export default function contribute(server: PluginServerContext) {
  server.handle(getState, handleGetState);
  server.handle(setQuiet, handleSetQuiet);
  server.handle(act, handleAct);
  return () => {};
}
