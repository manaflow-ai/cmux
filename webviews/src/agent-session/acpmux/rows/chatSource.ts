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
import { type ChatFall, ChatRowStore, type ChatRowsSnapshot } from "./store";

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
  }

  /// Whether the page asks the switch at all: not once a host said off, and never of a daemon
  /// without the hold (read from each handshake's capabilities, never remembered).
  asks(capabilities: ReadonlySet<string> | undefined): boolean {
    return state !== "off" && capabilities?.has(HOLD_ATTACH_CAPABILITY) === true;
  }

  /// A host on this page opened a chat on the store: an open asked before its handshake answers
  /// may guess the switch (`direct.ts` `HandshakeGuess`), checked against that handshake after.
  hostSaidOn(): boolean {
    return state === "on";
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
  async choose(chat: string, capabilities: ReadonlySet<string> | undefined): Promise<boolean> {
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
    const ask: Opening = { chat };
    this.opening = ask;
    listenForChatRows();
    ask.answer = this.opened(ask, this.host.open(chat));
    return ask.answer;
  }

  private async opened(ask: Opening, opening: ReturnType<ChatRowsHost["open"]>): Promise<boolean> {
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
    // Its sub fell while the open was out (a brand-new chat whose sub the daemon refused before the
    // host answered, issue 44964): the store let the sid go then, with no chat shown to fall, so
    // the fall is read here. The chat is v1's, as one that falls while shown (`onFall`).
    if (!this.host.store.has(opened.sid)) {
      this.host.close(opened.sid);
      this.fallen.add(chat);
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
  }

  private draw(shown: Shown, snapshot: ChatRowsSnapshot): void {
    if (this.shown !== shown || !snapshot.ready) return;
    clearTimeout(shown.firstWindow);
    shown.view = shown.adapter.adapt(snapshot);
    if (this.drawing?.chat === shown.chat) this.drawing = undefined;
    this.hooks.rows(shown.chat);
  }

  /// A chat's last window as kept: its settled rows (no open row, no row apart, no queue), none of
  /// its read bodies, and no page above it until the store holds the chat again.
  private keep(chat: string, snapshot: ChatRowsSnapshot, adapter: ChatAdapter): void {
    const rows = snapshot.rows.filter((entry) => entry.row !== null && !entry.row.open && !entry.unconfirmed);
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
      },
      adapter,
    });
    for (const old of this.kept.keys()) {
      if (this.kept.size <= KEPT_WINDOWS) break;
      this.kept.delete(old);
    }
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
    this.fallen.add(shown.chat);
    this.toV1(shown.chat);
    this.hooks.fell(shown.chat, code);
  }
}
