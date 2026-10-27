import type { Subagent } from "./subagentFold";
import { promptTitle } from "./agentRuns";
import { translate } from "../i18n";

export type SubagentClick = { metaKey: boolean };
export type OpenSubagent = (id: string, event?: SubagentClick) => void;

/** Old records can put the transport id in name; keep it in the tooltip, not the label. */
export function subagentName(agent: Subagent): string {
  if (agent.name && !(/^[0-9a-f]{8}[-/]/i.test(agent.name) || agent.name.includes("/toolu_"))) return agent.name;
  return agent.task?.trim() || promptTitle(agent.prompt) || translate("tray.kind.subagent");
}
/** Cmd-click opens a background tab beside the source; ordinary clicks select it. */
export function openChildSession(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  sessionId: string,
  event?: SubagentClick,
) {
  return call("chat.offer.open", { sessionId, ...(event?.metaKey && { focus: false }) });
}
