// A subagent's own records, read on their own when the chat's loaded page no longer holds that
// subagent (acpmux `_acpmux/events {subagent}`, hub/paging.rs `EventFilter::of_subagent`). A pane
// opened on an old, finished subagent draws that subagent's rows and state, never the chat it
// belongs to. Leo, 2026-11-07, on a subagent tab that drew its parent's transcript: "is this your
// sub-agent, or is this literally just a duplicate of you?"
import { useEffect, useState } from "react";
import type { AcpmuxRow } from "../model";
import { SubagentFold, type Event, type Subagent } from "./subagentFold";
import type { Folds } from "../conversation/viewFolds";
import { SUBAGENT_EMPTY, childView } from "./subagentRows";

/// One record of the log, as `_acpmux/events` sends it.
export type OwnLogRecord = { seq: number; at: number; dir: string; kind: string; msg?: any };
/// What the fold needs of the chat to attribute the records as the chat's own fold does
/// (direct.ts `reduceEvent`): its acpmux session, its harness and its agent's own thread.
export type OwnLogChat = { session?: string; harness?: string; thread?: string };
/// Reads subagent `id`'s records of the chat the pane shows, oldest first.
export type ReadOwnLog = (id: string) => Promise<OwnLogRecord[]>;

/// The rows and views a fold of only subagent `id`'s records draws, in the shape `childView` reads
/// from the chat's snapshot (its groups, and each subagent's own view).
export type OwnLog = { rows: AcpmuxRow[]; views: Record<string, AcpmuxRow[]>; agent?: Subagent };

/// Folds subagent `id`'s records alone, as the chat's fold would have folded them.
export function foldOwnLog(id: string, records: readonly OwnLogRecord[], chat: OwnLogChat): OwnLog {
  const fold = new SubagentFold();
  fold.session = chat.session;
  fold.harness = chat.harness;
  fold.chat = chat.thread;
  const rows: AcpmuxRow[] = [];
  for (const record of records) {
    const update =
      record.dir === "in" && record.msg?.method === "session/update" ? record.msg.params?.update : undefined;
    if (update) fold.reduce(record as Event, update);
  }
  rows.push(...fold.takeRows());
  return { rows, views: fold.views(), agent: fold.all().find((agent) => agent.id === id) };
}

/// The view of a subagent the pane has no rows for: loading while its own records are read, then
/// empty. Never the chat's rows (Leo's ask above).
export function pendingSubagentView(id: string, loading: boolean): AcpmuxRow[] {
  return [
    { id: `${id}:empty`, version: loading ? 1 : 2, at: 0, kind: SUBAGENT_EMPTY, ...(loading && { status: "loading" }) },
  ];
}

/// What a pane showing subagent `id` draws: its view from the chat's rows when they hold it, else
/// from its own records (`own.log`), else loading while those are read and empty after. Never
/// undefined, which would draw the chat's own rows in the subagent's place.
export function subagentPaneView(
  id: string,
  chat: { rows: readonly AcpmuxRow[]; views?: Record<string, AcpmuxRow[]> },
  own: { log?: OwnLog; loading: boolean },
  expanded: Folds,
  chatName: string,
): AcpmuxRow[] {
  return (
    childView(id, chat.rows, chat.views, expanded, chatName) ??
    (own.log && childView(id, own.log.rows, own.log.views, expanded, chatName)) ??
    pendingSubagentView(id, own.loading)
  );
}

type OwnLogState = { key: string; log?: OwnLog; done: boolean; failed?: boolean };

/// Subagent `id`'s own log while the pane needs it (`id` set: a subagent the chat's rows do not
/// hold), read once per chat and subagent while `connected`. `loading` until a read succeeds or
/// comes back empty. A failed read (no link yet, a dropped one) stays loading and reads again when
/// the link is up again, never settles as empty or as the chat.
export function useOwnLog(
  id: string | undefined,
  chat: OwnLogChat,
  read: ReadOwnLog,
  connected = true,
): { log?: OwnLog; loading: boolean } {
  const key = id && chat.session ? `${chat.session}\u001f${id}` : undefined;
  const [state, setState] = useState<OwnLogState>();
  const settled = state?.key === key && state?.done === true;
  useEffect(() => {
    if (!key || !id || !connected || settled) return;
    let live = true;
    setState((now) => (now?.key === key ? now : { key, done: false }));
    read(id).then(
      (records) => live && setState({ key, done: true, log: foldOwnLog(id, records, chat) }),
      () => live && setState({ key, done: false, failed: true }),
    );
    return () => {
      live = false;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- one read per chat, subagent and link; `chat` and `read` are read then
  }, [key, connected, settled]);
  if (!key) return { loading: false };
  const mine = state?.key === key ? state : undefined;
  return { log: mine?.log, loading: !mine?.done };
}
