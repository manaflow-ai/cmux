// Jump up (design/transcript-overlays.md): the companion of Jump to latest. Jump to latest goes to
// the newest message; Jump up goes back to where the reader left off (Leo, 2026-11-10: "you get jump
// to bottom, but then jump to, like, the last thread"):
//
// - the "New" line, while it is unread (the reader has a place to pick up from);
// - else where the reader's view was when they went idle, once a full screen of new content came in
//   below it (Leo, 2026-11-12: "it's more so, like, idle detection... when you have, like, at least
//   one full screen of idleness, that's when it starts having that... instead of getting overwritten
//   by some useless noise").
//
// The idle mark (`IdleMark`) is the reader's alone. Their own acts start an idle stretch where they
// are: a scroll by hand (the place a third down the view, where a press puts it back), a send (their
// prompt's row). Nothing else moves it: a restart, a reconnect, an app update or hot reload, the
// view's own moves (follow, anchor corrections, Find, reveals) and notice rows feed it only content
// height. Once a screen of new content lies below the place, the mark is set there and stays pinned
// until the reader acts again by hand.
//
// It shows only while that place is off screen. Pressed, it remembers where the view was; a second
// press or Esc goes back there. Pure: VirtualTranscript.tsx feeds it rows, offsets and acts.

import type { AcpmuxRow } from "./model";

/// A place in the transcript: a row and how far into it, layout px.
export type TranscriptPlace = { rowId: string; offset: number };

/// Where the reader left off: the place their idle stretch began, and when it was pinned.
export type ManualMark = { place: TranscriptPlace; at: number; why: "idle" };

/// Where the view was when Jump up was pressed: a second press or Esc goes back there.
export type JumpBack = { top: number; atLatest: boolean };

/// The reader's idle stretch: where it began (`read`), the content height below that place
/// (`below`, measured on the first layout after the stretch began), the reader's newest own prompt
/// seen (`prompt`: null for none, undefined before the first read), a send whose prompt row has not
/// come yet (`sent`), and the pinned mark.
export type IdleMark = {
  read?: { place: TranscriptPlace; below?: number };
  prompt?: string | null;
  sent?: true;
  mark?: ManualMark;
};

/// The reader scrolled by hand to `place`: a new idle stretch starts there, and the pinned mark goes.
export function readerScrolled(state: IdleMark, place: TranscriptPlace | undefined): IdleMark {
  return { ...(place ? { read: { place } } : {}), ...(state.prompt !== undefined ? { prompt: state.prompt } : {}) };
}

/// The reader sent a prompt: the pinned mark goes, and a stretch starts at the prompt's row once it
/// comes. Only this makes a new own prompt a start: one a reconnect draws (a prompt an earlier
/// connection lost) or a rebuild renames is no act of the reader's. The prompt's row can land in the
/// same commit as the send (`newest`, already noted, drawn within `SENT_ROW_MS` of `now`): the
/// stretch starts there at once.
export const SENT_ROW_MS = 5_000;
export function readerSent(state: IdleMark, newest: { id: string; at: number } | undefined, now: number): IdleMark {
  if (newest && newest.id === state.prompt && Math.abs(now - newest.at) <= SENT_ROW_MS)
    return { read: { place: { rowId: newest.id, offset: 0 } }, prompt: newest.id };
  return { ...(state.prompt !== undefined ? { prompt: state.prompt } : {}), sent: true };
}

/// What the transcript shows now: where a place's row lays out (undefined while it is not loaded),
/// the whole content height, the view's height, the reader's newest own prompt.
export type IdleLayout = {
  topOf: (place: TranscriptPlace) => number | undefined;
  totalHeight: number;
  viewHeight: number;
  lastPrompt?: string;
  now: number;
};

/// The idle stretch read against the layout. A new own prompt after a send (`readerSent`) starts the
/// stretch at its row; any other new prompt is only noted. The first read (a load) only notes the
/// newest prompt, and starts there only when nothing was kept. A full view height of new content
/// below the stretch's place pins the mark there. It is measured from the place, not from the last
/// row: while a turn runs its live line stays last and every row lands above it. Rows paging in
/// above the place, or rows above measuring to their drawn heights, move the place and the total
/// alike, so they never count. Returns `state` itself when nothing changed.
export function settleIdle(state: IdleMark, layout: IdleLayout): IdleMark {
  let next = state;
  const prompt = layout.lastPrompt ?? null;
  if (next.prompt === undefined)
    next =
      next.read || next.mark || prompt === null
        ? { ...next, prompt }
        : { read: { place: { rowId: prompt, offset: 0 } }, prompt };
  else if (prompt !== null && prompt !== next.prompt)
    next = next.sent ? { read: { place: { rowId: prompt, offset: 0 } }, prompt } : { ...next, prompt };
  if (next.mark || !next.read || !(layout.viewHeight > 0)) return next;
  const read = next.read;
  const top = layout.topOf(read.place);
  if (top === undefined || !Number.isFinite(top)) return next;
  const below = layout.totalHeight - top;
  // The first layout measures the stretch's start; content that went (a row folded, an estimate
  // measured shorter, the live line gone at a turn's end) lowers it, so only new content counts.
  if (read.below === undefined || below < read.below) return { ...next, read: { ...read, below } };
  if (below - read.below < layout.viewHeight) return next;
  return { ...next, mark: { place: next.read.place, at: layout.now, why: "idle" } };
}

/// Where Jump up goes: the unread line first (`sinceRowId`, while unread), else the pinned idle mark.
export function jumpUpTarget(
  sinceRowId: string | undefined,
  mark: ManualMark | undefined,
): TranscriptPlace | undefined {
  if (sinceRowId !== undefined) return { rowId: sinceRowId, offset: 0 };
  return mark?.place;
}

/// What a chat keeps of its idle stretch across a reload (an app update, a hot reload, a restart):
/// the place and the pinned mark, never the height measured, so the reload's own layout (estimated
/// rows, pages landing) is measured afresh and never pins a mark by itself, nor the prompt seen, so
/// the prompts already there on load are no send.
export function keptIdle(state: IdleMark): IdleMark {
  return {
    ...(state.read ? { read: { place: state.read.place } } : {}),
    ...(state.mark ? { mark: state.mark } : {}),
  };
}

const IDLE_KEY = "cmux.acpmux.jumpUpIdle";
/// Chats kept, newest first; older ones drop.
const IDLE_KEPT = 64;
type IdleStore = Pick<Storage, "getItem" | "setItem">;
const place = (value: unknown): TranscriptPlace | undefined => {
  const each = value as { rowId?: unknown; offset?: unknown } | undefined;
  return typeof each?.rowId === "string" && typeof each.offset === "number" && Number.isFinite(each.offset)
    ? { rowId: each.rowId, offset: each.offset }
    : undefined;
};
const readAll = (store: IdleStore | undefined): [string, unknown][] => {
  try {
    const parsed: unknown = JSON.parse(store?.getItem(IDLE_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((each): each is [string, unknown] => Array.isArray(each)) : [];
  } catch {
    return [];
  }
};

/// The idle stretch chat `sessionId` kept (`keepIdle`), or an empty one.
export function loadIdle(store: IdleStore | undefined, sessionId: string | undefined): IdleMark {
  if (!sessionId) return {};
  const kept = readAll(store).find(([id]) => id === sessionId)?.[1] as
    | { read?: unknown; mark?: { place?: unknown; at?: unknown } }
    | undefined;
  const read = place(kept?.read);
  const markPlace = place(kept?.mark?.place);
  const at = kept?.mark?.at;
  return {
    ...(read ? { read: { place: read } } : {}),
    ...(markPlace && typeof at === "number" ? { mark: { place: markPlace, at, why: "idle" as const } } : {}),
  };
}

/// Keeps chat `sessionId`'s idle stretch (`keptIdle`) for its next load; storage that is missing or
/// full keeps nothing.
export function keepIdle(store: IdleStore | undefined, sessionId: string | undefined, state: IdleMark): void {
  if (!sessionId || !store) return;
  const kept = keptIdle(state);
  const entry = { ...(kept.read ? { read: kept.read.place } : {}), ...(kept.mark ? { mark: kept.mark } : {}) };
  const rest = readAll(store).filter(([id]) => id !== sessionId);
  const all = entry.read || entry.mark ? [[sessionId, entry], ...rest] : rest;
  try {
    store.setItem(IDLE_KEY, JSON.stringify(all.slice(0, IDLE_KEPT)));
  } catch {
    // Storage unavailable or full: the stretch lives until the page goes.
  }
}

/// Whether a place at `top` (layout px) lies outside the view `[viewTop, viewTop + viewHeight)`,
/// with `margin` px of the view's edges counted as off screen (the header and the dock cover them).
export function placeOffScreen(top: number | undefined, viewTop: number, viewHeight: number, margin = 0): boolean {
  if (top === undefined || !Number.isFinite(top)) return false;
  return top < viewTop + margin || top > viewTop + viewHeight - margin;
}

/// What the reader sees of the rows, in their layout px (VirtualTranscript.tsx): `shownTop` is the
/// layout offset at the view's top edge (the scroll offset less `lift`), and the rows draw `threadTop`
/// under their layout tops, below a floating tab row's `topInset`. The view is `height` tall and the
/// composer dock covers its last `dockSpace`.
export type RowsView = { shownTop: number; height: number; threadTop: number; topInset: number; dockSpace: number };

/// Whether a place at layout `top` is out of the reader's sight: above the view's top edge, or under the
/// dock. Measured where the row draws, not at its bare layout top: that counted the first prompt of a chat
/// scrolled a few px off screen while the whole bubble was in plain sight, and Jump up stood over the
/// running turn's live line (gallery agent-pane.transcript#codex-turn-raw-commands).
export function placeOffView(top: number | undefined, view: RowsView): boolean {
  if (top === undefined) return false;
  return placeOffScreen(top + view.threadTop, view.shownTop, view.height - view.topInset - view.dockSpace);
}

/// Where a press goes: back to `back` when one is held (the second press), else to the target,
/// holding where the view is now.
export type JumpUpPress = { kind: "back"; back: JumpBack } | { kind: "go"; back: JumpBack };
export function pressJumpUp(held: JumpBack | undefined, now: JumpBack): JumpUpPress {
  return held ? { kind: "back", back: held } : { kind: "go", back: now };
}

/// Whether the button shows: while the place is off screen, and while a return is `held` (so the
/// second press is there).
export function jumpUpShown(offScreen: boolean, held: boolean): boolean {
  return offScreen || held;
}

/// Whether a row is a prompt the reader sent by hand: not another agent's message, a task's result,
/// harness bookkeeping or the Chief's message to a subagent (`incoming`, `untyped`, `from`), and in a
/// shared chat not another person's. `me` is the author id this pane sends as
/// (multiplayer/presenceClient.ts `selfId`); the owner's prompts carry no author and acpmux names the
/// owner `owner`.
export function ownPrompt(row: AcpmuxRow, me = "owner"): boolean {
  if (row.kind !== "user" || row.incoming || row.untyped || row.from !== undefined) return false;
  return (row.author?.id ?? "owner") === me;
}

/// What `lastOwnPrompt` read last: whose prompts, how many rows, the last one's id, and the prompt
/// it found.
export type PromptScan = { me?: string; length: number; lastId?: string; found?: { id: string; at: number } };

/// The reader's newest own prompt (`ownPrompt`): where a send's idle stretch starts. The transcript mostly
/// appends: when the rows read last are still the head of these, only the rows after them are
/// scanned, so a render costs O(new rows); otherwise (another chat, a rebuild, another author id)
/// one scan back from the end, which stops at the first own prompt.
export function lastOwnPrompt(
  rows: readonly AcpmuxRow[],
  scan: { current: PromptScan },
  me = "owner",
): { id: string; at: number } | undefined {
  const last = scan.current;
  const appended =
    last.me === me && last.length > 0 && rows.length >= last.length && rows[last.length - 1]?.id === last.lastId;
  const from = appended ? last.length : 0;
  let found = appended ? last.found : undefined;
  for (let i = rows.length - 1; i >= from; i--) {
    const row = rows[i]!;
    if (ownPrompt(row, me)) {
      found = { id: row.id, at: row.at };
      break;
    }
  }
  scan.current = { me, length: rows.length, lastId: rows[rows.length - 1]?.id, found };
  return found;
}

/// How long a changed idle stretch waits before it is kept (`keepIdle`): a hand scroll changes it on
/// every step.
export const IDLE_KEEP_MS = 400;

/// One transcript's idle stretch across its chats (VirtualTranscript.tsx): the chat it is for, the
/// stretch, and its keeping for the next load. A plain object the transcript holds for its life, so
/// the render reads it without refs and the reader's acts (handlers) change it. Keeping is debounced
/// by IDLE_KEEP_MS; a switch to another chat or `keepNow` writes what is waiting at once, a change no
/// render read yet included.
export class IdleTracker {
  private sessionId: string | undefined;
  private opened = false;
  private enabled = false;
  private current: IdleMark = {};
  private kept: string | undefined;
  private timer: ReturnType<typeof setTimeout> | undefined;
  /// The place row's index where it was last found (`settle`'s lookup hint).
  readonly hint = { current: -1 };

  constructor(private readonly store: () => IdleStore | undefined = () => globalThis.localStorage) {}

  /// The stretch for chat `sessionId`: the last chat's is kept first, and this one's loads.
  open(sessionId: string | undefined, enabled: boolean): void {
    if (this.opened && sessionId === this.sessionId && enabled === this.enabled) return;
    if (this.opened) this.keepNow();
    this.opened = true;
    this.sessionId = sessionId;
    this.enabled = enabled;
    this.current = enabled ? loadIdle(this.store(), sessionId) : {};
    this.kept = JSON.stringify(keptIdle(this.current));
    this.hint.current = -1;
  }

  get state(): IdleMark {
    return this.current;
  }

  /// The reader scrolled by hand to `place` (`readerScrolled`).
  scrolled(place: TranscriptPlace | undefined): void {
    if (!this.enabled) return;
    this.current = readerScrolled(this.current, place);
    this.keepSoon();
  }

  /// The reader sent a prompt (`readerSent`); `newest` is their newest own prompt seen.
  sent(newest: { id: string; at: number } | undefined): void {
    if (!this.enabled) return;
    this.current = readerSent(this.current, newest, Date.now());
    this.keepSoon();
  }

  /// The stretch read against the layout (`settleIdle`, `now` its clock). Keeping is the caller's
  /// (`keepSoon` after the render that read it).
  settle(layout: Omit<IdleLayout, "now">): IdleMark {
    if (!this.enabled) return this.current;
    this.current = settleIdle(this.current, { ...layout, now: Date.now() });
    return this.current;
  }

  /// Keeps the stretch after IDLE_KEEP_MS when what is kept changed since the last write.
  keepSoon(): void {
    if (!this.enabled || !this.sessionId) return;
    if (JSON.stringify(keptIdle(this.current)) === this.kept) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.keepNow(), IDLE_KEEP_MS);
  }

  /// Keeps the stretch now when what is kept changed, and drops the write waiting.
  keepNow(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    if (!this.enabled || !this.sessionId) return;
    const key = JSON.stringify(keptIdle(this.current));
    if (key === this.kept) return;
    this.kept = key;
    keepIdle(this.store(), this.sessionId, this.current);
  }
}
