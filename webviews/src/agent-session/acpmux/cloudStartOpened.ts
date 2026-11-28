import type { CloudStartProgress } from "./cloudStartProgress";

/// A Cloud start the host opened, until its chat shows (Austin, 2026-11-27: "the initial chat loads and then when we
/// do a “transition” to a cloud chat it likes blinks out and then changes the chat… sometimes there is an error and
/// the chat just goes blank and stuff or loads forever").
///
/// A start in place keeps this page (cmux-cloud-start-core `one_pane`): its socket closes, its reconnect starts the
/// chat on the Cloud machine, and `cloud.startChat` answers ok meanwhile. Clearing the card on that answer drew an
/// empty chat (no session, no rows) until the Cloud chat's first frame came: the blink. A start whose Cloud session
/// then failed left that empty chat for good. The card, with the sent prompt, now stays until the Cloud chat's first
/// page has a row of its own, and a failure on the way turns it into the failed card, prompt kept.

/// What the page shows of its chat now, as far as the hand-off reads it.
export type CloudStartOpenedView = {
  /// The chat the snapshot shows (undefined before the Cloud session's first frame).
  sessionId?: string;
  rows: readonly { kind: string; at: number; text?: unknown }[];
  /// The host's failure to hand the page acpmux, once the pane shows it (App.tsx `hostErrorShown`).
  hostError?: string;
};

/// The host answered start `key` ok: the card stays, marked opened, until the chat shows (`cloudStartOpenedSettled`).
export function cloudStartOpened(
  current: CloudStartProgress | undefined,
  key: string,
  now: number = Date.now(),
): CloudStartProgress | undefined {
  if (current?.key !== key || current.state !== "starting") return current;
  const { ask: _ask, signingIn: _signingIn, stalled: _stalled, ...rest } = current;
  return { ...rest, opened: true, advancedAt: now };
}

/// Whether the Cloud chat's first page is drawn: its session, with a row that is not only a notice.
export function cloudChatFirstPage(view: CloudStartOpenedView): boolean {
  return Boolean(view.sessionId) && view.rows.some((row) => row.kind !== "notice");
}

/// An opened start as the chat stands now: gone once the Cloud chat's first page is drawn; failed, in the
/// failure's own words, when the pane's line to the host failed or the chat's start said why (a notice row since the
/// open and nothing else); else as it was (its stall bound, `watchCloudStartStall`, still runs).
export function cloudStartOpenedSettled(
  current: CloudStartProgress | undefined,
  view: CloudStartOpenedView,
): CloudStartProgress | undefined {
  if (!current?.opened || current.state !== "starting") return current;
  if (cloudChatFirstPage(view)) return undefined;
  const since = current.advancedAt ?? 0;
  const notice = view.rows.find(
    (row) => row.kind === "notice" && row.at >= since && typeof row.text === "string" && row.text,
  );
  const message = view.hostError || (notice?.text as string | undefined);
  if (!message) return current;
  const { opened: _opened, stalled: _stalled, ...rest } = current;
  return { ...rest, state: "failed", code: "cloud_chat_open_failed", message, retryable: false };
}

/// Whether the card shows for an opened start: until the Cloud chat's first page is drawn.
export function cloudStartWaitsForFirstPage(
  start: CloudStartProgress | undefined,
  view: CloudStartOpenedView,
): boolean {
  return start?.opened === true && !cloudChatFirstPage(view);
}
