// A finished subagent's report, whole, for the cards that open to it (SubagentDoneLine.tsx,
// SubagentReportLine.tsx). Leo, 2026-11-09, on a "Subagent finished" card that stopped at
// `**24 clean, f…`: "whoa this isn't rendering the full message nor having a show more as it
// shuold". A Claude subagent's `lastMessage` is acpmux's 240-character preview (subagents.rs
// `truncate_last_message`), not its reply. The whole reply is its `result` when acpmux has it, else
// the last reply in its own transcript: the chat's loaded rows, else its own records, read once
// when Show more asks. Until then the card shows the preview's whole blocks, never a cut span
// (conversation/markdownCut.ts), and Show more.
import { createContext, useContext, useEffect, useState } from "react";
import type { AcpmuxRow } from "../model";
import { isCappedPreview, shownOfCut, wholeBlocksAfter } from "../conversation/markdownCut";
import { SubagentViewsContext } from "./subagentGroupModel";

/// acpmux's cap on a subagent's `lastMessage` (subagents.rs `LAST_MESSAGE_CHARS`).
export const LAST_MESSAGE_CHARS = 240;

/// A subagent's last reply, read from its own records (App.tsx, direct.ts `readSubagentLog`):
/// what Show more opens when the chat's loaded rows no longer hold the subagent.
export const SubagentReplyContext = createContext<((id: string) => Promise<string | undefined>) | undefined>(undefined);

/// The last reply in a subagent's own transcript, whole.
export function lastReply(view: readonly AcpmuxRow[] | undefined): string | undefined {
  for (let at = (view?.length ?? 0) - 1; at >= 0; at -= 1) {
    const entry = view![at]!;
    if (entry.kind === "assistant" && entry.text?.trim()) return entry.text.trim();
  }
  return undefined;
}

/// What a report card shows: `text`, Markdown to render; `cut` when that is not all of it, so the
/// card offers Show more (`more`), which reads the rest and opens it in place. `away` when the rest
/// is only in the subagent's own view (a reply whose head acpmux dropped, or a read that found
/// nothing): Show more opens that view.
export type WholeReport = { text: string; cut: boolean; loading: boolean; away: boolean; more(): void };

type Source = { id: string; result?: string; lastMessage?: string };

/// The report of `agent`, read only while `open` (a closed card never walks a transcript).
/// `fallback` is the text a card has with no subagent output at all (an error, a summary).
export function useWholeReport(agent: Source | undefined, open: boolean, fallback?: string): WholeReport | undefined {
  const readView = useContext(SubagentViewsContext);
  const readReply = useContext(SubagentReplyContext);
  const id = agent?.id;
  // Show more pressed, and what reading the subagent's records found (null: nothing).
  const [read, setRead] = useState<{ id: string; wanted: boolean; reply?: string | null }>();
  const mine = read?.id === id ? read : undefined;
  const result = agent?.result?.trim() || undefined;
  const preview = agent?.lastMessage?.trim() || undefined;
  const capped = !result && preview !== undefined && isCappedPreview(preview, LAST_MESSAGE_CHARS);
  // Its own transcript's last reply is whole wherever `lastMessage` is not: read before it. It
  // also outranks a `result` it extends: acpmux snapshots `result` at the end, and the reply's last
  // chunks may land after it (subagentFold.test.ts "late chunks ... across completion").
  const viewed = open && id ? lastReply(readView?.(id)) : undefined;
  const reply = viewed && (!result || (viewed !== result && viewed.startsWith(result))) ? viewed : undefined;
  const asks = !!(open && id && capped && !reply && mine?.wanted && mine.reply === undefined && readReply);
  useEffect(() => {
    if (!asks || !id || !readReply) return;
    let live = true;
    readReply(id).then(
      (found) => live && setRead({ id, wanted: true, reply: found ?? null }),
      () => live && setRead({ id, wanted: true, reply: null }),
    );
    return () => {
      live = false;
    };
  }, [asks, id, readReply]);
  // A report whose subagent the loaded rows do not hold still shows what its card has.
  if (!id)
    return open && fallback?.trim()
      ? { text: fallback.trim(), cut: false, loading: false, away: false, more: () => {} }
      : undefined;
  const more = () => setRead((now) => (now?.id === id ? { ...now, wanted: true } : { id, wanted: true }));
  const whole = (text: string): WholeReport => ({ text, cut: false, loading: false, away: false, more });
  // A reply acpmux kept only the tail of (hub/subsession_results.rs): its whole blocks after the cut.
  if (result?.startsWith("…"))
    return { text: wholeBlocksAfter(result) || result.slice(1).trim(), cut: true, loading: false, away: true, more };
  if (reply) return whole(reply);
  if (result) return whole(result);
  if (preview && !capped) return whole(preview);
  if (preview) {
    if (mine?.wanted && mine.reply) return whole(mine.reply);
    const loading = !!mine?.wanted && mine.reply === undefined && !!readReply;
    const away = !!mine?.wanted && !loading;
    return { text: shownOfCut(preview), cut: true, loading, away, more };
  }
  return fallback?.trim() ? whole(fallback.trim()) : undefined;
}
