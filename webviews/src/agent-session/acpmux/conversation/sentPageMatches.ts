import type { AcpmuxActivity } from "../model";
import { activityText, foldFind } from "./chatFind";
import type { SentEntry } from "./toolGroups";

/// The rows of a paged group Find mounts for `reveal`, ascending. A recipient's target matches on its
/// own row; a payload (text, file) the call's messages share, as a tag send's do, matches on the first
/// message that carries it alone, so one word in a 1,025-recipient send mounts one row, not every row.
export function sentPageMatches(entries: readonly SentEntry[], reveal: { toolId?: string; needle: string }): number[] {
  const firsts = new Map<AcpmuxActivity, number>();
  for (const [at, { item }] of entries.entries()) if (!firsts.has(item)) firsts.set(item, at);
  if (reveal.toolId !== undefined)
    return [...firsts].filter(([item]) => item.tool?.id === reveal.toolId).map(([, at]) => at);
  const hit = (value: string | undefined) => value !== undefined && foldFind(value).includes(reveal.needle);
  const payloads = new Map<AcpmuxActivity, Set<string>>();
  const own = (entry: SentEntry) => {
    if (entry.type !== "send") return false;
    if (hit(entry.send.target)) return true;
    if (!hit(entry.send.text) && !hit(entry.send.file)) return false;
    const key = `${entry.send.text ?? ""}\0${entry.send.file ?? ""}`;
    const seen = payloads.get(entry.item) ?? new Set<string>();
    payloads.set(entry.item, seen);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  };
  // Every message of a batch shares its call: each call's text is folded once, not per message.
  const calls = new Map<AcpmuxActivity, boolean>();
  const inCall = (item: AcpmuxActivity) => {
    let found = calls.get(item);
    if (found === undefined) calls.set(item, (found = foldFind(activityText(item)).includes(reveal.needle)));
    return found;
  };
  const out = new Set<number>();
  const reached = new Set<AcpmuxActivity>();
  for (const [at, entry] of entries.entries())
    if (own(entry) || (entry.type !== "send" && inCall(entry.item))) {
      out.add(at);
      reached.add(entry.item);
    }
  for (const [item, at] of firsts) if (!reached.has(item) && inCall(item)) out.add(at);
  return [...out].sort((x, y) => x - y);
}
