// A subagent's own view (the child view): its updates as transcript rows, by the parent
// transcript's rules in direct.ts. Its text is a reply, its thoughts and tool calls fold into
// activity rows, and the subagents it spawned between two pieces of its text draw as one group
// row, so nesting reads the same at every level.
import { appendThought, mergeToolItem, textFromContent } from "../direct";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { hiddenCall } from "../hiddenTools";
import { SUBAGENTS, type Event, type Subagent } from "./subagentFold";

/// One of a subagent's own updates, or the point where it spawned a subagent.
export type ChildEntry = { event: Event; update?: any; spawned?: string; settled?: boolean };

/// The rows of subagent `id`'s view, in the order its updates came.
/// `version` is the view's version: a group row redraws whenever its subagents change.
export function childRows(
  id: string,
  entries: readonly ChildEntry[],
  agents: ReadonlyMap<string, Subagent>,
  version: number,
): AcpmuxRow[] {
  return new ChildRowView(id).update(entries, agents, version);
}

type Group = { row: string; ids: string[] };

/// One subagent's append-only source log, folded once per entry. Keep unchanged rows and tool
/// items by identity so an expanded child group does no sibling render/output work per chunk.
/// A rebuilt session owns a fresh view; previously published rows/items are never mutated.
export class ChildRowView {
  private readonly rows = new Map<string, AcpmuxRow>();
  private readonly tools = new Map<string, string>();
  private readonly hidden = new Set<string>();
  private readonly groups: Group[] = [];
  private reply: string | undefined;
  private replyMessageId: string | undefined;
  private activity: string | undefined;
  private group: Group | undefined;
  private cursor = 0;
  /// The published streaming copy of the current reply, kept while its source row holds.
  private streamed: { source: AcpmuxRow; row: AcpmuxRow } | undefined;

  constructor(private readonly id: string) {}

  update(entries: readonly ChildEntry[], agents: ReadonlyMap<string, Subagent>, version: number): AcpmuxRow[] {
    const { id, rows, tools, hidden, groups } = this;
    let { reply, replyMessageId, activity, group } = this;
    // A resume marks the already-folded tail entry settled after the fact.
    if (this.cursor > 0 && entries[this.cursor - 1]?.settled) reply = activity = undefined;
    for (; this.cursor < entries.length; this.cursor += 1) {
      const { event, update, spawned, settled } = entries[this.cursor]!;
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
      if (kind === "omitted") {
        rows.set(`${id}:omitted-${event.seq}`, {
          id: `${id}:omitted-${event.seq}`,
          version,
          at: event.at,
          kind: "notice",
          text: translate("workflow.contentOmitted"),
        });
        reply = undefined;
        activity = undefined;
        group = undefined;
      } else if (kind === "user_message_chunk" && text) {
        rows.set(`${id}:user-${event.seq}`, {
          id: `${id}:user-${event.seq}`,
          version,
          at: event.at,
          kind: "user",
          text,
        });
        reply = undefined;
        activity = undefined;
        group = undefined;
      } else if (kind === "agent_message_chunk" && text) {
        const messageId = typeof update.messageId === "string" ? update.messageId : undefined;
        if (messageId && replyMessageId && messageId !== replyMessageId) {
          if (reply) {
            const prior = rows.get(reply);
            if (prior) rows.set(reply, { ...prior, version: prior.version + 1, streaming: false });
          }
          reply = undefined;
        }
        const rowId = reply ?? `${id}:assistant-${event.seq}`;
        const existing = rows.get(rowId);
        rows.set(rowId, {
          id: rowId,
          version: (existing?.version ?? 0) + 1,
          at: existing?.at ?? event.at,
          kind: "assistant",
          text: `${existing?.text ?? ""}${text}`,
          streaming: false,
        });
        reply = rowId;
        if (messageId) replyMessageId = messageId;
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
        if (hiddenCall(hidden, callId, update)) {
          if (settled) reply = activity = undefined;
          continue;
        }
        // A fresh start belongs to its current segment; delayed updates keep their recorded row.
        const recorded = tools.get(callId);
        const known = kind === "tool_call" && recorded !== activity ? undefined : recorded;
        // An update to a call whose start this view never saw, with no title, names nothing but the
        // call's raw id (Leo's subagent view opened on "toolu_01Rq…"): it draws no row.
        if (kind === "tool_call_update" && !known && !update.title) {
          if (settled) reply = activity = undefined;
          continue;
        }
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
      if (settled) reply = activity = undefined;
    }
    this.reply = reply;
    this.replyMessageId = replyMessageId;
    this.activity = activity;
    this.group = group;
    // Group rows list their subagents as they are now; a metadata-only update redraws the group
    // without replaying any child message, thought or tool content.
    for (const { row, ids } of groups) {
      const subagents = ids.flatMap((agent) => {
        const found = agents.get(agent);
        return found ? [{ ...found }] : [];
      });
      rows.set(row, { ...rows.get(row)!, version, subagents });
    }
    const out = [...rows.values()];
    // A running child's open reply streams. Publish a copy so the folded row stays immutable,
    // and keep that copy while its source row holds.
    const source = reply && agents.get(id)?.state === "running" ? rows.get(reply) : undefined;
    if (!source) this.streamed = undefined;
    else {
      if (this.streamed?.source !== source) this.streamed = { source, row: { ...source, streaming: true } };
      const at = out.indexOf(source);
      if (at >= 0) out[at] = this.streamed.row;
    }
    return out;
  }
}
