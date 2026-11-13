// One "While you were away" card per chat (Leo, 2026-11-11, of a chat with eight stacked recaps
// that all said the same thing: "oh shit this is way too much"). acpmux now keeps one recap per
// chat and writes none that says nothing new (`hub/away_recap.rs`); a chat logged before that
// still holds a recap per return. Drawn here, only the newest recap shows, and none at or before
// one the person dismissed on this device (recapDismissed.ts): dismissing the newest never brings
// an older one back.
import { SINCE_DIVIDER, type AcpmuxRow } from "../model";
import { dismissedRecapKeys } from "./recapDismissed";

/// A recap key's chat and seq (`chat:seq`, direct.ts).
function parse(key: string): { chat: string; seq: number } | undefined {
  const at = key.lastIndexOf(":");
  const seq = Number(key.slice(at + 1));
  return at >= 0 && Number.isFinite(seq) ? { chat: key.slice(0, at), seq } : undefined;
}

/// `rows` with at most one recap: the newest not dismissed. A recap drawn on "New since you
/// looked" counts as one; when it is not the one kept the divider stays, without it. The same
/// array when there is nothing to drop.
export function oneRecap(rows: AcpmuxRow[], dismissed: () => readonly string[] = dismissedRecapKeys): AcpmuxRow[] {
  const recaps: { row: AcpmuxRow; chat: string; seq: number }[] = [];
  for (const row of rows) {
    const key = row.kind === "recap" ? row.recap?.key : row.id === SINCE_DIVIDER ? row.since?.recap?.key : undefined;
    const parsed = key ? parse(key) : undefined;
    if (parsed) recaps.push({ row, ...parsed });
  }
  if (recaps.length === 0 || (recaps.length === 1 && !dismissedSome(recaps[0]!, dismissed))) return rows;
  // The newest dismissed per chat: it and every older recap of the chat stay hidden.
  const hiddenThrough = new Map<string, number>();
  for (const key of dismissed()) {
    const parsed = parse(key);
    if (parsed && parsed.seq > (hiddenThrough.get(parsed.chat) ?? -1)) hiddenThrough.set(parsed.chat, parsed.seq);
  }
  let keep: AcpmuxRow | undefined;
  let newest = -1;
  for (const recap of recaps) {
    if (recap.seq <= (hiddenThrough.get(recap.chat) ?? -1)) continue;
    if (recap.seq > newest) {
      newest = recap.seq;
      keep = recap.row;
    }
  }
  const drop = new Set(recaps.map((recap) => recap.row).filter((row) => row !== keep));
  if (drop.size === 0) return rows;
  const kept: AcpmuxRow[] = [];
  for (const row of rows) {
    if (!drop.has(row)) kept.push(row);
    else if (row.id === SINCE_DIVIDER && row.since) {
      const { recap: _recap, ...since } = row.since;
      kept.push({ ...row, version: row.version + 1, since });
    }
  }
  return kept;
}

/// Whether the one recap is dismissed, or older than one dismissed in its chat.
function dismissedSome(recap: { chat: string; seq: number }, dismissed: () => readonly string[]): boolean {
  return dismissed().some((key) => {
    const parsed = parse(key);
    return parsed?.chat === recap.chat && parsed.seq >= recap.seq;
  });
}
