// One "While you were away" card per chat (Leo, 2026-11-11, of a chat with eight stacked recaps
// that all said the same thing: "oh shit this is way too much"). acpmux now keeps one recap per
// chat and writes none that says nothing new (`hub/away_recap.rs`); a chat logged before that
// still holds a recap per return. Drawn here, only the newest recap shows, and none at or before
// one the person dismissed on this device (recapDismissed.ts): dismissing the newest never brings
// an older one back.
import { SINCE_DIVIDER, type AcpmuxRow } from "../model";
import { PrefixFilter, PrefixFlatCache } from "./prefixFlatMap";
import { dismissedRecapKeys } from "./recapDismissed";

/// A recap key's chat and seq (`chat:seq`, direct.ts).
function parse(key: string): { chat: string; seq: number } | undefined {
  const at = key.lastIndexOf(":");
  const seq = Number(key.slice(at + 1));
  return at >= 0 && Number.isFinite(seq) ? { chat: key.slice(0, at), seq } : undefined;
}

/// The recap key a row carries: a recap's own, or the one drawn on "New since you looked".
function recapKey(row: AcpmuxRow): string | undefined {
  return row.kind === "recap" ? row.recap?.key : row.id === SINCE_DIVIDER ? row.since?.recap?.key : undefined;
}

/// The rows that carry a recap, read again only past the rows the last snapshot kept
/// (prefixFlatMap.ts): a streamed token in a chat of 35,000 rows reads the rows it changed, not
/// every row (bench/transcript-replay.bench.ts, god log: this pass was 1.9 ms of each token).
const carriers = new PrefixFilter<AcpmuxRow>((row) => recapKey(row) !== undefined);

/// The divider without the recap it drew, the same object for the same divider.
const withoutRecap = new WeakMap<AcpmuxRow, AcpmuxRow>();
function dividerWithout(row: AcpmuxRow): AcpmuxRow {
  let out = withoutRecap.get(row);
  if (!out) {
    const { recap: _recap, ...since } = row.since!;
    out = { ...row, version: row.version + 1, since };
    withoutRecap.set(row, out);
  }
  return out;
}

/// The pass that drops recaps, one per set of rows it drops (a recap shown or dismissed is a new
/// set): it too reads only the rows past the kept prefix.
let dropping: { key: string; pass: PrefixFlatCache<AcpmuxRow, AcpmuxRow> } | undefined;
function dropPass(drop: ReadonlySet<AcpmuxRow>): PrefixFlatCache<AcpmuxRow, AcpmuxRow> {
  const key = [...drop].map((row) => `${row.id}@${row.version}`).join("\n");
  if (dropping?.key !== key)
    dropping = {
      key,
      pass: new PrefixFlatCache<AcpmuxRow, AcpmuxRow>((row) =>
        !drop.has(row) ? [row] : row.id === SINCE_DIVIDER && row.since ? [dividerWithout(row)] : [],
      ),
    };
  return dropping.pass;
}

/// `rows` with at most one recap: the newest not dismissed. A recap drawn on "New since you
/// looked" counts as one; when it is not the one kept the divider stays, without it. The same
/// array when there is nothing to drop. Costs the rows a snapshot changed, not the chat's rows.
export function oneRecap(rows: AcpmuxRow[], dismissed: () => readonly string[] = dismissedRecapKeys): AcpmuxRow[] {
  const recaps: { row: AcpmuxRow; chat: string; seq: number }[] = [];
  for (const row of carriers.read(rows).items) {
    const key = recapKey(row);
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
  return dropPass(drop).read(rows).items as AcpmuxRow[];
}

/// Whether the one recap is dismissed, or older than one dismissed in its chat.
function dismissedSome(recap: { chat: string; seq: number }, dismissed: () => readonly string[]): boolean {
  return dismissed().some((key) => {
    const parsed = parse(key);
    return parsed?.chat === recap.chat && parsed.seq >= recap.seq;
  });
}
