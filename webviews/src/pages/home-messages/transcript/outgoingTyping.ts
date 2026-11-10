// My typing indicator from the Messages page's composer, as the native composer reported it
// (HomeProjection `homeStore.composing`): each change of the message box tells the app whether I
// type (`cmux.home.messages.composing {conversation, typing}`), and HomeStore keeps its own throttle
// (an `on` at most every 3 s, an `off` after 5 s idle, HomeStore+Typing.swift). The page sends a
// change of state at once and, while I keep typing, one `typing: true` a second at most, so
// HomeStore's idle clock stays within a second of the last key with no call per key. A send, an
// emptied field and leaving the conversation end it.
//
// Cost: at most one host call a second while typing, one per start and stop.
import type { PageClient } from "../../shared/pageClient";

export const COMPOSING_OP = "cmux.home.messages.composing";
/** How often a held `typing: true` goes again while the text keeps changing. */
export const TYPING_REPEAT_MS = 1000;

export class OutgoingTyping {
  private typing = false;
  private last = 0;

  constructor(
    private readonly host: PageClient | null,
    private readonly conversation: string,
    private readonly now: () => number = Date.now,
  ) {}

  /** The message box now holds `text` (whitespace alone is not typing). */
  changed(text: string): void {
    if (!text.trim()) return this.stop();
    const at = this.now();
    if (this.typing && at - this.last < TYPING_REPEAT_MS) return;
    this.typing = true;
    this.last = at;
    this.tell(true);
  }

  /** A send, the field emptied, or the conversation closed: my typing ends. */
  stop(): void {
    if (!this.typing) return;
    this.typing = false;
    this.tell(false);
  }

  private tell(typing: boolean): void {
    void this.host?.call(COMPOSING_OP, { conversation: this.conversation, typing }).catch(() => undefined);
  }
}
