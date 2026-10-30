import type { Subagent } from "./subagentFold";
import { promptTitle } from "./agentRuns";
import { translate } from "../i18n";

export type SubagentClick = { metaKey: boolean };
export type OpenSubagent = (id: string, event?: SubagentClick) => void;

/** Old records can put the transport id in name; the label shows the task instead, and
 * ``subagentFullName`` keeps the id for hover and accessibility text. */
export function subagentName(agent: Subagent): string {
  if (agent.name && !(/^[0-9a-f]{8}[-/]/i.test(agent.name) || agent.name.includes("/toolu_"))) return agent.name;
  return agent.task?.trim() || promptTitle(agent.prompt) || translate("tray.kind.subagent");
}
/** The label plus the transport id it hid (so two "Subagent" rows stay distinct to a screen reader
 * and on hover); the label alone when it is the record's own name. */
export function subagentFullName(agent: Subagent): string {
  const name = subagentName(agent);
  return name === agent.name ? name : `${name} (${agent.name || agent.id})`;
}
/** A row's hover text: its task, or with a hidden transport id the label with that id. */
export function subagentTitle(agent: Subagent): string | undefined {
  const full = subagentFullName(agent);
  return full === subagentName(agent) ? agent.task : full;
}
/** Cmd-click opens a background tab beside the source; ordinary clicks select it. */
export function openChildSession(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  sessionId: string,
  event?: SubagentClick,
) {
  return call("chat.offer.open", { sessionId, ...(event?.metaKey && { focus: false }) });
}
