// A subagent's own view (the child view): its updates as transcript rows, by the parent
// transcript's rules in direct.ts. Its text is a reply, its thoughts and tool calls fold into
// activity rows, and the subagents it spawned between two pieces of its text draw as one group
// row, so nesting reads the same at every level.
import { appendThought, mergeToolItem, textFromContent } from "../direct";
import type { AcpmuxRow } from "../model";
import { hiddenCall } from "../hiddenTools";
import { SUBAGENTS, type Event, type Subagent } from "./subagentFold";

/// One of a subagent's own updates, or the point where it spawned a subagent.
export type ChildEntry = { event: Event; update?: any; spawned?: string };

/// The rows of subagent `id`'s view, in the order its updates came.
/// `version` is the view's version: a group row redraws whenever its subagents change.
export function childRows(
  id: string,
  entries: readonly ChildEntry[],
  agents: ReadonlyMap<string, Subagent>,
  version: number,
): AcpmuxRow[] {
  const rows = new Map<string, AcpmuxRow>();
  const tools = new Map<string, string>();
  const hidden = new Set<string>();
  const groups: { row: string; ids: string[] }[] = [];
  let reply: string | undefined;
  let activity: string | undefined;
  let group: { row: string; ids: string[] } | undefined;
  for (const { event, update, spawned } of entries) {
    if (spawned) {
      if (!group) {
        group = { row: `${id}:${SUBAGENTS}-${event.seq}`, ids: [] };
        groups.push(group);
        rows.set(group.row, { id: group.row, version: 1, at: event.at, kind: SUBAGENTS, subagents: [] });
      }
      group.ids.push(spawned);
      reply = undefined;
      activity = undefined;
      continue;
    }
    const kind = update?.sessionUpdate;
    const text = textFromContent(update?.content);
    if (kind === "agent_message_chunk" && text) {
      const rowId = reply ?? `${id}:assistant-${event.seq}`;
      const existing = rows.get(rowId);
      rows.set(rowId, {
        id: rowId,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "assistant",
        text: `${existing?.text ?? ""}${text}`,
      });
      reply = rowId;
      activity = undefined;
      group = undefined;
    } else if (kind === "agent_thought_chunk" && text) {
      const rowId = activity ?? `${id}:activity-${event.seq}`;
      const existing = rows.get(rowId);
      rows.set(rowId, {
        id: rowId,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: existing?.toolCount ?? 0,
        items: appendThought(existing?.items ?? [], text, event.at),
      });
      activity = rowId;
      reply = undefined;
    } else if (kind === "tool_call" || kind === "tool_call_update") {
      const callId = String(update.toolCallId ?? `tool-${event.seq}`);
      // Plumbing (Claude Code's ToolSearch) draws no row here either (hiddenTools.ts).
      if (hiddenCall(hidden, callId, update)) continue;
      const known = tools.get(callId);
      // An update to a call whose start this view never saw, with no title, names nothing but the
      // call's raw id (Leo's subagent view opened on "toolu_01Rq…"): it draws no row.
      if (kind === "tool_call_update" && !known && !update.title) continue;
      const rowId = known ?? activity ?? `${id}:activity-${event.seq}`;
      const existing = rows.get(rowId);
      const items = [...(existing?.items ?? [])];
      const index = items.findIndex((item) => item.tool?.id === callId);
      const item = mergeToolItem(index >= 0 ? items[index] : undefined, update, callId, text, event.at);
      if (index >= 0) items[index] = item;
      else items.push(item);
      rows.set(rowId, {
        id: rowId,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: items.filter((entry) => entry.kind === "tool").length,
        items,
      });
      tools.set(callId, rowId);
      if (!known) activity = rowId;
      reply = undefined;
    }
  }
  // Group rows list their subagents as they are now; a change redraws the group.
  for (const { row, ids } of groups) {
    const subagents = ids.flatMap((agent) => {
      const found = agents.get(agent);
      return found ? [{ ...found }] : [];
    });
    rows.set(row, { ...rows.get(row)!, version, subagents });
  }
  return [...rows.values()];
}
