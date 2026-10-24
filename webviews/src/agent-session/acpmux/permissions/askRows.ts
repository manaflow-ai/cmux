import type { AcpmuxRow } from "../model";
import type { PermissionClientState } from "./protocol";

/// The transcript without the tool calls a permission ask waits on (`groupAskedCalls`): while it
/// waits, the ask's row names the call, so the command is drawn once (Leo 2026-10-14: the chat
/// showed "Ran <command>" over a card that repeated it). Answered, the call is back in its place.
export function withoutAskedCalls(rows: AcpmuxRow[], asked: ReadonlySet<string>): AcpmuxRow[] {
  if (asked.size === 0) return rows;
  let changed = false;
  const kept: AcpmuxRow[] = [];
  for (const row of rows) {
    const items = row.items?.filter((item) => !(item.tool && asked.has(item.tool.id)));
    if (!items || items.length === row.items?.length) {
      kept.push(row);
      continue;
    }
    changed = true;
    // A half version: never one the row reaches by itself, so the whole row draws again when the
    // ask is answered.
    if (items.length > 0) kept.push({ ...row, items, version: row.version + 0.5 });
  }
  return changed ? kept : rows;
}

/// The tool calls the grouped permission panel shows in its rows. Only that panel names the call;
/// the older single-ask card does not, so its call stays in the transcript.
export function groupAskedCalls(groups: PermissionClientState | undefined): Set<string> {
  const calls = new Set<string>();
  if (!groups?.supported) return calls;
  for (const group of groups.groups)
    if (group.state === "pending" || group.state === "collecting")
      for (const item of group.items) {
        const request = item.request as {
          toolCall?: { toolCallId?: unknown };
          subject?: { type?: unknown; toolCall?: { toolCallId?: unknown } };
        };
        const id =
          request.toolCall?.toolCallId ??
          (request.subject?.type === "tool_call" ? request.subject.toolCall?.toolCallId : undefined);
        if (item.state === "pending" && typeof id === "string" && id) calls.add(id);
      }
  return calls;
}
