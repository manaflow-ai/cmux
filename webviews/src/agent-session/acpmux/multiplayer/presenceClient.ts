// The pane's side of a shared chat's presence (hq plans/cmux-next/chat-multiplayer/DESIGN.md
// section 5; hb-acpmux's `_acpmux/presence` and `_acpmux/typing`). It holds the open chat's
// presence from the attach reply and each `_acpmux/presence`, and tells acpmux when this pane types:
// on at the first keystroke, again before acpmux's 8 s expiry while typing goes on, off on send,
// clear or 5 s without a keystroke. Only on/off crosses, never the draft. An acpmux that answered
// no `presence` on attach has neither method, so this pane then sends nothing.
//
// acpmux takes at most two typing calls a second from a connection (`typing.rate_limited`): a
// refused off is sent again, at most STOP_RETRIES times, so others never see this pane typing
// until acpmux's expiry; a refused on is sent again with the next keystroke.
//
// Two timers: the idle one, armed on a keystroke and cleared on off, on a chat switch and on close;
// and a refused off's retry, cleared when it lands, gives up, or typing starts again.
import { chatPresence, type ChatPresence } from "./participants";

/// acpmux drops an `on` after 8 s; a pane still typing says so again before that.
export const TYPING_REFRESH_MS = 5_000;
/// No keystroke for this long and the pane says it stopped.
export const TYPING_IDLE_MS = 5_000;

/// A refused off goes again this long after, at most STOP_RETRIES times.
export const STOP_RETRY_MS = 600;
export const STOP_RETRIES = 3;

type Send = (method: "_acpmux/typing", params: { sessionId: string; on: boolean }) => Promise<unknown> | void;

const rateLimited = (error: unknown) => (error as { reason?: unknown } | null)?.reason === "typing.rate_limited";

export class PresenceClient {
  private sessionId: string | undefined;
  /// This pane's own id in the open chat: the attach reply's `you.id` (a teammate the host daemon
  /// admitted), else the one the pane was made with.
  private self: string;
  private supported = false;
  private current: ChatPresence = { viewing: [], typing: [] };
  private typingOn = false;
  private sentAt = 0;
  private idle: ReturnType<typeof setTimeout> | undefined;
  private stopRetry: ReturnType<typeof setTimeout> | undefined;
  /// Bumped when the pane leaves a chat: a stop still out for it is not sent again after.
  private attachment = 0;

  constructor(
    private readonly send: Send,
    private readonly changed: () => void,
    /// This pane's author id: a local pane sends none, which acpmux names `owner`.
    private readonly me: () => string = () => "owner",
    private readonly now: () => number = Date.now,
  ) {
    this.self = me();
  }

  /// The open chat's presence, or undefined when nobody else is here.
  get presence(): ChatPresence | undefined {
    return this.current.viewing.length > 0 || this.current.typing.length > 0 ? this.current : undefined;
  }

  /// The chat this presence is for: the one attached, which a switch's attach makes the next chat
  /// before the pane shows it.
  get chat(): string | undefined {
    return this.sessionId;
  }

  /// The presence to draw for `sessionId` (the shown chat), so a switch never shows the last chat's.
  presenceOf(sessionId: string | undefined): ChatPresence | undefined {
    return sessionId !== undefined && sessionId === this.sessionId ? this.presence : undefined;
  }

  /// A chat opened (its attach reply): presence when acpmux sends it, else none.
  attached(sessionId: string, reply: unknown): void {
    this.stopTyping();
    this.sessionId = sessionId;
    const { presence, you } = (reply ?? {}) as { presence?: unknown; you?: { id?: unknown } };
    this.self = typeof you?.id === "string" && you.id ? you.id : this.me();
    this.supported = presence !== undefined;
    // Always told, even when nobody else is here: the pane then draws this chat's (empty) set,
    // never a presence its snapshot kept from before.
    this.set(this.supported ? chatPresence(presence, this.self) : { viewing: [], typing: [] }, true);
  }

  /// `_acpmux/presence` for any chat; only the open chat's counts, and only when its attach reply
  /// said acpmux serves presence.
  notification(params: unknown): void {
    const sessionId = (params as { sessionId?: unknown } | undefined)?.sessionId;
    if (!this.supported || sessionId !== this.sessionId) return;
    this.set(chatPresence(params, this.self));
  }

  /// The composer's text changed: typing while it holds text, stopped when it is empty. `shown` is
  /// the chat whose composer it is: a keystroke in the chat still on screen while the next one's
  /// attach lands says nothing to the next one.
  typed(text: string, shown?: string): void {
    if (!this.supported || !this.sessionId) return;
    if (shown !== undefined && shown !== this.sessionId) return;
    if (!text.trim()) return this.stopTyping();
    const now = this.now();
    if (!this.typingOn || now - this.sentAt >= TYPING_REFRESH_MS) {
      this.typingOn = true;
      this.sentAt = now;
      this.cancelStopRetry();
      const sessionId = this.sessionId;
      void Promise.resolve(this.send("_acpmux/typing", { sessionId, on: true })).catch((error) => {
        // Refused: the next keystroke says it again.
        if (rateLimited(error) && this.sessionId === sessionId && this.sentAt === now) this.sentAt = -Infinity;
      });
    }
    if (this.idle) clearTimeout(this.idle);
    this.idle = setTimeout(() => this.stopTyping(), TYPING_IDLE_MS);
  }

  /// A prompt went, or the chat closes: this pane is no longer typing.
  stopTyping(): void {
    if (this.idle) clearTimeout(this.idle);
    this.idle = undefined;
    if (!this.typingOn) return;
    this.typingOn = false;
    if (this.sessionId) this.sendStop(this.sessionId, 0);
  }

  /// Off for `sessionId`; refused for the rate, again later, until typing starts there again.
  private sendStop(sessionId: string, tries: number): void {
    this.cancelStopRetry();
    const attachment = this.attachment;
    // Only while the pane still shows that chat and is not typing there again: once it leaves,
    // its attachment ends and acpmux drops it from that chat's presence (detach), so a refused
    // off for a chat no longer shown is not sent again.
    const still = () => this.attachment === attachment && this.sessionId === sessionId && !this.typingOn;
    void Promise.resolve(this.send("_acpmux/typing", { sessionId, on: false })).catch((error) => {
      if (!rateLimited(error) || tries >= STOP_RETRIES || this.stopRetry !== undefined || !still()) return;
      this.stopRetry = setTimeout(() => {
        this.stopRetry = undefined;
        if (still()) this.sendStop(sessionId, tries + 1);
      }, STOP_RETRY_MS);
    });
  }

  private cancelStopRetry(): void {
    if (this.stopRetry) clearTimeout(this.stopRetry);
    this.stopRetry = undefined;
  }

  /// The pane leaves the chat (a switch or close).
  detached(): void {
    this.stopTyping();
    this.attachment += 1;
    this.cancelStopRetry();
    this.sessionId = undefined;
    this.supported = false;
    this.set({ viewing: [], typing: [] }, true);
  }

  private set(next: ChatPresence, always = false): void {
    const same = (a: ChatPresence, b: ChatPresence) =>
      a.viewing.map((p) => `${p.id}:${p.name}`).join() === b.viewing.map((p) => `${p.id}:${p.name}`).join() &&
      a.typing.map((p) => p.id).join() === b.typing.map((p) => p.id).join();
    if (!always && same(this.current, next)) return;
    this.current = next;
    this.changed();
  }
}
