// Where a chat's rows come from (decision 276): the row store, over the host's `chat.rows.*`, or v1's
// attach. One chat on the store a pane at a time. The pane's client (direct.ts) asks `choose` once
// what it draws through the kept draw is on screen, and sends its v1 attach after the answer: the
// hold for a chat on the store (holdKinds.ts), its plain attach otherwise.
//
// A chat left keeps its last window here (`kept`), settled rows only, for its next select to draw
// where v1's kept tail would be; the store's first window then replaces it in one step.
import { type AdaptedChat, ChatAdapter, type ChatRowsContext } from "./adapter";
import { CHAT_ROWS_OFF, CHAT_ROWS_OTHER_SID, CHAT_ROWS_SLOW, ChatRowsHost, type ChatRowsPost } from "./host";
import { addChatRowsHost, listenForChatRows, receiveChatRows, removeChatRowsHost } from "./receiver";
import { type ChatAnchor, type ChatFall, ChatRowStore, type ChatRowsSnapshot } from "./store";

/// What this document knows of the host's switch: `off` once a host said it has no such operation
/// (`chat.rows.off`: the page host's `unknown_op` or the old bridge's `unsupported`), and then no
/// open is asked again; `on` once one opened. Page memory only.
export type ChatRowsState = "unknown" | "off" | "on";
let state: ChatRowsState = "unknown";
export const chatRowsState = (): ChatRowsState => state;
/// Opens this document's host answered with a sid other than the one the page named
/// (`CHAT_ROWS_OTHER_SID`): each fell that chat to v1 once, and left the switch as it was.
let otherSids = 0;
export const chatRowsOtherSids = (): number => otherSids;
/// A test's fresh page.
export function resetChatRowsState(): void {
  state = "unknown";
  otherSids = 0;
}

/// The daemon's capability for the hold (acpmux capabilities.rs `HOLD_ATTACH`).
export const HOLD_ATTACH_CAPABILITY = "attach-hold-v1";
/// Chats whose last window a page keeps, as v1 keeps its tails (tailCache.ts `KEPT_TAILS`).
export const KEPT_WINDOWS = 20;
/// The longest a chat on the store waits on its first window after its open's answer (decision
/// 276d): past it the chat falls to v1 (`CHAT_ROWS_SLOW`), so a quiet host never leaves the pane
/// with no rows once the switch's hold ends. For now the switch's hold limit (direct.ts
/// `SWITCH_HOLD_MS`); 6d's measurement of the first window sets the number.
export const FIRST_WINDOW_MS = 1_500;
/// How far from where the pane rests a window's unconfirmed rows are asked for again, in screens.
export const REREAD_SCREENS = 2;
/// The list's line height for the store's height unit (`est`, lines): the transcript's body line.
const LINE_PX = 20;

export type ChatSourceHooks = {
  /// The page's context for a chat's adapter (adapter.ts `ChatRowsContext`).
  context(chat: string): ChatRowsContext;
  /// The chat on screen has new rows: one call a batch.
  rows(chat: string): void;
  /// The chat on screen fell to v1 (`chat.rows.limit`, the host's sub ended): it attaches as v1.
  fell(chat: string, code: string): void;
};

type Shown = {
  chat: string;
  sid: string;
  adapter: ChatAdapter;
  stop: () => void;
  view?: AdaptedChat;
  /// `FIRST_WINDOW_MS` running, until the first window is in.
  firstWindow?: ReturnType<typeof setTimeout>;
  /// The edition whose page of turns was asked: one ask an edition (decision 378).
  turnsAsked?: number;
  /// Each waits on the page out: told when it lands or is refused, or the chat is left.
  pageWaits: (() => void)[];
  /// The row the sub opened around, until its first window: a window that does not hold it (the
  /// daemon no longer has the row) opens the chat again at the end, once, as v1's missed place does.
  restingAt?: number;
  /// The row the pane rests on, from its anchor report; undefined at the latest row.
  reading?: number;
};
/// An open out: its answer is every choose of its chat's until it settles.
type Opening = { chat: string; answer?: Promise<boolean> };
type Kept = { snapshot: ChatRowsSnapshot; adapter: ChatAdapter; view?: AdaptedChat };

export class ChatSource {
  readonly host: ChatRowsHost;
  private shown: Shown | undefined;
  /// The open out, if any: a later choose or close makes it stale, and its sid is closed on answer.
  private opening: Opening | undefined;
  /// `FIRST_WINDOW_MS`, set lower by a test.
  firstWindowMs = FIRST_WINDOW_MS;
  /// The kept window drawn for the chat being opened, until its first window or its fall.
  private drawing: { chat: string; kept: Kept } | undefined;
  /// Least recently left first.
  private kept = new Map<string, Kept>();
  /// Chats that fell while shown: v1 until another chat is chosen.
  private fallen = new Set<string>();

  constructor(
    post: ChatRowsPost,
    private hooks: ChatSourceHooks,
    name?: () => string,
  ) {
    this.host = new ChatRowsHost(post, new ChatRowStore({ onFall: (fall) => this.onFall(fall) }), name);
    // Before the first open: the host's batches reach this store through the document's receiver.
    addChatRowsHost(this.host, post);
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", this.onVisible);
  }

  /// Whether the page asks the switch at all: not once a host said off, and never of a daemon
  /// without the hold (read from each handshake's capabilities, never remembered).
  asks(capabilities: ReadonlySet<string> | undefined): boolean {
    return state !== "off" && capabilities?.has(HOLD_ATTACH_CAPABILITY) === true;
  }

  /// The chat's rows come from the store: its v1 attach is the hold.
  holds(chat: string): boolean {
    return this.shown?.chat === chat;
  }

  /// Draws the chat's kept window, if it has one: true when it did. The window stays its until the
  /// store's first one, or until it falls to v1.
  drawKept(chat: string, capabilities: ReadonlySet<string> | undefined): boolean {
    const kept = this.kept.get(chat);
    if (!kept || !this.asks(capabilities)) return false;
    this.drawing = { chat, kept };
    return true;
  }

  /// Opens the chat on the store, or says it is v1: true when its rows come from the store. One
  /// chat at a time, so any other is closed first; a chat already on it stays (a reconnect).
  async choose(chat: string, capabilities: ReadonlySet<string> | undefined, at?: string): Promise<boolean> {
    if (this.shown?.chat === chat && this.asks(capabilities)) return true;
    // This chat's open is out already (the attach asked with the list asked it): its answer is this
    // choose's too, with no second open posted.
    const out = this.opening;
    if (out?.chat === chat && out.answer && this.asks(capabilities)) return out.answer;
    // Kept by `drawKept` for this chat: closing the chat before it must not drop it.
    const drawing = this.drawing?.chat === chat ? this.drawing : undefined;
    this.close();
    this.drawing = drawing;
    // A chat that fell while shown stays v1 until another chat is chosen.
    if (!this.fallen.has(chat)) this.fallen.clear();
    if (!this.asks(capabilities) || this.fallen.has(chat)) return this.toV1(chat);
    listenForChatRows();
    return this.open(chat, restingRow(at));
  }

  /// Opens the chat's sub: at the row the pane rested on (`around` it, so the rows both sides are
  /// held), else at the end.
  private open(chat: string, at: number | undefined): Promise<boolean> {
    const ask: Opening = { chat };
    this.opening = ask;
    const anchor: ChatAnchor = at === undefined ? "end" : { rowId: at, side: "around" };
    ask.answer = this.opened(ask, this.host.open(chat, anchor), at);
    return ask.answer;
  }

  private async opened(ask: Opening, opening: ReturnType<ChatRowsHost["open"]>, at?: number): Promise<boolean> {
    const chat = ask.chat;
    const opened = await opening;
    if (this.opening !== ask) {
      if ("sid" in opened) this.host.close(opened.sid);
      return false;
    }
    this.opening = undefined;
    if ("fallen" in opened) {
      if (opened.fallen === CHAT_ROWS_OFF) state = "off";
      if (opened.fallen === CHAT_ROWS_OTHER_SID) otherSids += 1;
      return this.toV1(chat);
    }
    state = "on";
    const kept = this.kept.get(chat);
    this.kept.delete(chat);
    const shown: Shown = {
      chat,
      sid: opened.sid,
      adapter: kept?.adapter ?? new ChatAdapter(this.hooks.context(chat)),
      stop: () => {},
      pageWaits: [],
      ...(at !== undefined ? { restingAt: at } : {}),
    };
    shown.stop = this.host.store.subscribe(opened.sid, (snapshot) => this.draw(shown, snapshot));
    this.shown = shown;
    // A window that came before the answer is held already, with no one told of it.
    const first = this.host.store.snapshot(opened.sid);
    if (first?.ready) this.draw(shown, first);
    else shown.firstWindow = setTimeout(() => this.slow(shown), this.firstWindowMs);
    return true;
  }

  /// The view of the chat on screen: its store's rows once its first window is in, else its kept
  /// window. None for a chat drawn by v1.
  view(chat: string | undefined): AdaptedChat | undefined {
    if (chat === undefined) return undefined;
    if (this.shown?.chat === chat && this.shown.view) return this.shown.view;
    const drawing = this.drawing;
    if (drawing?.chat !== chat) return undefined;
    drawing.kept.view ??= drawing.kept.adapter.adapt(drawing.kept.snapshot);
    return drawing.kept.view;
  }

  /// Asks for the page before the rows held: false when there is none to ask or one is out.
  page(chat: string): boolean {
    const shown = this.shown;
    return shown?.chat === chat && shown.view !== undefined && this.host.page(shown.sid, "before");
  }

  /// The list's ask for older rows (`loadOlder`): the page before the rows held, resolved when it
  /// lands or is refused, the sub goes off, the chat is left or its edition changes (a window lets go
  /// of the page out). With a page already out, it resolves with that one; with none to ask, at once.
  /// Nothing leaves it pending, so the list's read time (OlderAhead) is the page's.
  pageOlder(chat: string): Promise<void> {
    const shown = this.shown;
    if (shown?.chat !== chat || !shown.view) return Promise.resolve();
    this.host.page(shown.sid, "before");
    return this.pageSettled(shown);
  }

  /// Where the pane rests on `chat`, as its settled anchor report has it (`row-<id>`, or null at
  /// the latest row). Rows a window of the same edition left unconfirmed within two screens of it
  /// are asked for in one page (decision 377); the rest wait until the pane reads near them.
  readingAt(chat: string, rowId: string | null): void {
    const shown = this.shown;
    if (shown?.chat !== chat) return;
    shown.reading = rowId === null ? undefined : restingRow(rowId);
    this.reconfirm(shown);
  }

  /// One page for the unconfirmed rows within `REREAD_SCREENS` screens of the row the pane rests
  /// on: a page before the newest of them, which covers them back to the oldest within its bound.
  /// None with none there, or with a page out (its landing calls this again).
  private reconfirm(shown: Shown): void {
    const snapshot = this.host.store.snapshot(shown.sid);
    if (!snapshot?.ready || !snapshot.unconfirmed.size || this.host.store.pageOut(shown.sid)) return;
    const rows = snapshot.rows;
    if (!rows.length) return;
    const at =
      shown.reading === undefined ? rows.length - 1 : Math.min(lowerIndex(rows, shown.reading), rows.length - 1);
    const reach = REREAD_SCREENS * this.screenLines();
    let newest: number | undefined;
    for (const step of [-1, 1]) {
      let lines = 0;
      for (let index = at; index >= 0 && index < rows.length && lines <= reach; index += step) {
        const entry = rows[index]!;
        lines += entry.est;
        if (snapshot.unconfirmed.has(entry.id) && (newest === undefined || entry.id > newest)) newest = entry.id;
      }
    }
    if (newest !== undefined) this.host.page(shown.sid, "before", { from: newest + 1 });
  }

  /// A screen in the store's height unit (`est`, lines): the window's height over a line's.
  private screenLines(): number {
    const height = typeof window !== "undefined" && window.innerHeight > 0 ? window.innerHeight : 800;
    return Math.ceil(height / LINE_PX);
  }

  /// A rail jump to a turn older than the rows held (`loadThrough`): pages from its prompt's row
  /// (`row-<prompt>`, the rail's earlier prompt) until a page holds it. Resolves true once it is
  /// held, false when the page was refused, held no such row, or the chat was left or fell.
  async through(chat: string, prompt: number): Promise<boolean> {
    for (;;) {
      const shown = this.shown;
      if (shown?.chat !== chat || !shown.view) return false;
      if (this.holdsRow(shown, prompt)) return true;
      if (this.host.page(shown.sid, "after", { from: prompt - 1 })) {
        await this.pageSettled(shown);
        return this.shown === shown && this.holdsRow(shown, prompt);
      }
      // Another page is out: this one is asked once it is in.
      if (!this.host.store.pageOut(shown.sid)) return false;
      await this.pageSettled(shown);
    }
  }

  private holdsRow(shown: Shown, id: number): boolean {
    const rows = this.host.store.snapshot(shown.sid)?.rows ?? [];
    let lo = 0;
    let hi = rows.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (rows[mid]!.id < id) lo = mid + 1;
      else hi = mid;
    }
    return rows[lo]?.id === id && rows[lo]!.row !== null;
  }

  /// Resolves once no page is out for the chat on screen, or it is no longer on screen.
  private pageSettled(shown: Shown): Promise<void> {
    if (this.shown !== shown || !this.host.store.pageOut(shown.sid)) return Promise.resolve();
    return new Promise((resolve) => shown.pageWaits.push(resolve));
  }

  private settlePageWaits(shown: Shown, left = false): void {
    if (!shown.pageWaits.length || (!left && this.host.store.pageOut(shown.sid))) return;
    for (const resolve of shown.pageWaits.splice(0)) resolve();
  }

  /// The page of turns, once an edition, after its first window is drawn and while the page is
  /// seen: from the open turn's group row (the page before it holds every settled turn), else from
  /// past the last row held. Behind a page out (a person's page goes first); asked at the snapshot
  /// that ends it.
  private askTurns(shown: Shown, snapshot: ChatRowsSnapshot): void {
    const edition = snapshot.edition;
    if (edition === undefined || shown.turnsAsked === edition || this.hidden()) return;
    if (this.host.store.pageOut(shown.sid)) return;
    const from = openGroup(snapshot) ?? (snapshot.rows[snapshot.rows.length - 1]?.id ?? 0) + 1;
    if (this.host.page(shown.sid, "before", { from, turns: true })) shown.turnsAsked = edition;
  }

  private hidden(): boolean {
    return typeof document !== "undefined" && document.visibilityState === "hidden";
  }

  /// The page is seen again: a page of turns not asked while it was hidden is asked now.
  private onVisible = (): void => {
    const shown = this.shown;
    const snapshot = shown && shown.view ? this.host.store.snapshot(shown.sid) : undefined;
    if (shown && snapshot?.ready) this.askTurns(shown, snapshot);
  };

  /// Leaves the chat on the store, keeping its last window: on a select of another chat and at the
  /// client's close. A fall leaves it too, keeping nothing (`onFall`).
  close(): void {
    const drawing = this.drawing;
    this.opening = undefined;
    this.drawing = undefined;
    const shown = this.shown;
    if (!shown) return;
    this.shown = undefined;
    clearTimeout(shown.firstWindow);
    shown.stop();
    this.settlePageWaits(shown, true);
    const snapshot = this.host.store.snapshot(shown.sid);
    if (snapshot?.ready) this.keep(shown.chat, snapshot, shown.adapter);
    // Left before its first window: the window it drew is still its last.
    else if (drawing?.chat === shown.chat) this.kept.set(shown.chat, drawing.kept);
    this.host.close(shown.sid);
  }

  /// A batch from the host, as the document's receiver (`window.cmuxChatRows`) takes it.
  receive(event: { batch: number; changes: readonly string[] }): void {
    receiveChatRows(event);
  }

  /// The pane client is dropped: its chat on the store is closed and its host takes no more batches.
  dispose(): void {
    this.close();
    removeChatRowsHost(this.host);
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.onVisible);
  }

  private draw(shown: Shown, snapshot: ChatRowsSnapshot): void {
    if (this.shown !== shown || !snapshot.ready) return;
    const at = shown.restingAt;
    if (at !== undefined) {
      shown.restingAt = undefined;
      if (!this.holdsRow(shown, at)) return this.reopenAtEnd(shown);
    }
    clearTimeout(shown.firstWindow);
    shown.view = shown.adapter.adapt(snapshot);
    if (this.drawing?.chat === shown.chat) this.drawing = undefined;
    this.hooks.rows(shown.chat);
    this.settlePageWaits(shown);
    if (this.shown !== shown) return;
    // A person's re-read goes before the page of turns: both wait on the one page slot.
    this.reconfirm(shown);
    this.askTurns(shown, snapshot);
  }

  /// A chat's last window as kept: its settled rows (no open row, no row apart, no queue), none of
  /// its read bodies, and no page above it until the store holds the chat again.
  private keep(chat: string, snapshot: ChatRowsSnapshot, adapter: ChatAdapter): void {
    const rows = snapshot.rows.filter(
      (entry) => entry.row !== null && !entry.row.open && !snapshot.unconfirmed.has(entry.id),
    );
    this.kept.delete(chat);
    this.kept.set(chat, {
      snapshot: {
        ...snapshot,
        rows,
        apart: [],
        hasBefore: false,
        hasAfter: false,
        queue: { entries: [], count: 0 },
        bodies: new Map(),
        unconfirmed: new Set(),
        // A kept chat keeps no heads: the next open asks its edition's page of turns.
        heads: null,
      },
      adapter,
    });
    for (const old of this.kept.keys()) {
      if (this.kept.size <= KEPT_WINDOWS) break;
      this.kept.delete(old);
    }
  }

  /// The pane's resting row is not in the chat's first window: its sub is closed and the chat
  /// opened again at the end. What was drawn for it (its kept window) stays drawn meanwhile.
  private reopenAtEnd(shown: Shown): void {
    this.shown = undefined;
    clearTimeout(shown.firstWindow);
    shown.stop();
    this.settlePageWaits(shown, true);
    this.host.close(shown.sid);
    void this.open(shown.chat, undefined);
  }

  /// A chat drawn by v1 keeps no window: one kept thing a chat, and v1's tail is that.
  private toV1(chat: string): false {
    this.kept.delete(chat);
    if (this.drawing?.chat === chat) this.drawing = undefined;
    return false;
  }

  private onFall(fall: ChatFall): void {
    const shown = this.shown;
    if (shown?.sid !== fall.sid) return;
    this.fall(shown, fall.code);
  }

  /// No first window within `firstWindowMs` of the open's answer: the chat falls to v1 and its sid
  /// is closed, so what comes for it after is dropped.
  private slow(shown: Shown): void {
    if (this.shown !== shown || shown.view) return;
    this.host.close(shown.sid);
    this.fall(shown, CHAT_ROWS_SLOW);
  }

  private fall(shown: Shown, code: string): void {
    this.shown = undefined;
    clearTimeout(shown.firstWindow);
    shown.stop();
    this.settlePageWaits(shown, true);
    this.fallen.add(shown.chat);
    this.toV1(shown.chat);
    this.hooks.fell(shown.chat, code);
  }
}

/// The open turn's group row: the last group row held, while it is open. The rows after it are
/// that turn's, so the walk back is one turn long.
function openGroup(snapshot: ChatRowsSnapshot): number | undefined {
  for (const entries of [snapshot.apart, snapshot.rows])
    for (let at = entries.length - 1; at >= 0; at -= 1) {
      const row = entries[at]!.row;
      if (row?.kind !== "group") continue;
      if (row.open) return row.id;
      if (entries === snapshot.rows) return undefined;
    }
  return undefined;
}

/// The store's rowId of the view row the pane rested on (`row-<id>`, the adapter's ids); undefined
/// for none, or a v1 id (`user-<seq>`, ...), which opens at the end.
function restingRow(at: string | undefined): number | undefined {
  const match = at === undefined ? null : /^row-(\d+)$/.exec(at);
  const id = match ? Number(match[1]) : NaN;
  return Number.isSafeInteger(id) && id >= 0 ? id : undefined;
}

/// The index of the first entry at or above `id`.
function lowerIndex(rows: readonly { id: number }[], id: number): number {
  let lo = 0;
  let hi = rows.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (rows[mid]!.id < id) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}
