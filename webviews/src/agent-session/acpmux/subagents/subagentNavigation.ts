import type { Subagent } from "./subagentFold";
import { promptTitle } from "./agentRuns";
import { translate } from "../i18n";

export type SubagentClick = { metaKey: boolean };
export type OpenSubagent = (id: string, event?: SubagentClick) => void;

/** Old records can put the transport id in name: show the task or prompt title instead, else
 * "Subagent". The raw id is never shown, in the label, the hover text or the accessible name
 * (test/subagent-right-pane.test.tsx); the row's click still carries it. A text is the id when it
 * equals the agent's id, whatever its format, or looks like an acpmux/Claude transport id. */
export function subagentName(agent: Subagent): string {
  const readable = (text: string | undefined) => {
    const value = text?.trim();
    if (!value || value === agent.id) return undefined;
    if (/^[0-9a-f]{8}[-/]/i.test(value) || value.includes("/toolu_")) return undefined;
    return value;
  };
  const title = readable(agent.name) ?? readable(agent.task) ?? readable(promptTitle(agent.prompt));
  return title ?? translate("tray.kind.subagent");
}
/** Cmd-click opens a background tab beside the source; ordinary clicks select it. */
export function openChildSession(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  sessionId: string,
  event?: SubagentClick,
) {
  return call("chat.offer.open", { sessionId, ...(event?.metaKey && { focus: false }) });
}
