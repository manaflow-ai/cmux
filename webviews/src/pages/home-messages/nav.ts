// The Messages page's view state that the list and the detail share (TopHomePageView's
// `newMessage`, `present*` and the shown conversation): the New Message draft and whether its page
// shows, the sheet over the page, the composer drafts per conversation, the open Message Requests
// and who takes the keyboard. Conversations and messages stay the Channels store's; this holds
// only what the native view held beside them.
import type { MessageRequest } from "./sheets/model";
import { EMPTY_DRAFT, isDraftEmpty, type RecipientDraft } from "./sheets/recipients";

export type SheetKind = "requests" | "groupInfo" | "newChief" | "invite" | "teamInvite";

/** A sheet over the page, as `home.messages.present` or a control asked for it. */
export interface SheetRequest {
  kind: SheetKind;
  /** Group Info's conversation. */
  conversation?: string;
  /** An invite's address, New Chief's name. */
  prefill?: string;
  /** Group Info opens on Add People. */
  adding?: boolean;
  /** The Team Invite came from an agent, not the person's own gesture. */
  requestedByAgent?: boolean;
}

export interface NavState {
  /** New Message: its To: draft, and whether its page shows (a draft with people or text stays
   * while another conversation shows, its row unselected). */
  compose?: { draft: RecipientDraft; shown: boolean };
  sheet?: SheetRequest;
  requests: readonly MessageRequest[];
  /** Bumped when a conversation's kept draft is replaced from outside (`home.messages.show`
   * with a draft): the composer starts again with it. */
  draftEpoch: number;
  /** Bumped when the composer (or New Message's To: field) should take the keyboard once the
   * page shows what changed (a conversation opened from the list or the host). */
  focusEpoch: number;
}

export class MessagesNav {
  private state: NavState = { requests: [], draftEpoch: 0, focusEpoch: 0 };
  private readonly listeners = new Set<() => void>();
  /** The composer drafts by conversation (not state: the field owns its text while it shows). */
  private readonly drafts = new Map<string, string>();
  /** The New Message page's message box text (it ends with the draft). */
  composeText = "";
  /** What takes the keyboard now (the detail registers it): true when something took it. */
  private focuser: (() => boolean) | undefined;

  getSnapshot = (): NavState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(patch: Partial<NavState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }

  /** New Message shows (a new draft, or the one kept). */
  openCompose(): void {
    this.set({ compose: { draft: this.state.compose?.draft ?? EMPTY_DRAFT, shown: true } });
  }

  setComposeDraft(draft: RecipientDraft): void {
    if (this.state.compose) this.set({ compose: { ...this.state.compose, draft } });
  }

  /** Another conversation shows: an empty draft goes with its row (Messages drops an untouched
   * New Message), one with people or text stays, hidden. */
  leaveCompose(): void {
    const compose = this.state.compose;
    if (!compose?.shown) return;
    if (isDraftEmpty(compose.draft) && !this.composeText.trim()) this.closeCompose();
    else this.set({ compose: { ...compose, shown: false } });
  }

  /** The draft, its page and its row go, whatever was typed (the row's x, `closeNewMessage`).
   * True when there was one. */
  closeCompose(): boolean {
    if (!this.state.compose) return false;
    this.composeText = "";
    this.set({ compose: undefined });
    return true;
  }

  present(sheet: SheetRequest): void {
    this.set({ sheet });
  }

  dismiss(): void {
    if (this.state.sheet) this.set({ sheet: undefined });
  }

  setRequests(requests: readonly MessageRequest[]): void {
    this.set({ requests });
  }

  draft(conversation: string): string {
    return this.drafts.get(conversation) ?? "";
  }

  keepDraft(conversation: string, text: string): void {
    if (text) this.drafts.set(conversation, text);
    else this.drafts.delete(conversation);
  }

  /** Replaces `conversation`'s draft from outside: its composer starts again with `text`. */
  replaceDraft(conversation: string, text: string): void {
    this.keepDraft(conversation, text);
    this.set({ draftEpoch: this.state.draftEpoch + 1 });
  }

  /** The detail says what takes the keyboard; the returned stop clears it. */
  setFocuser(focuser: () => boolean): () => void {
    this.focuser = focuser;
    return () => {
      if (this.focuser === focuser) this.focuser = undefined;
    };
  }

  /** The keyboard goes to the composer after the next commit (the detail's effect). */
  requestFocus(): void {
    this.set({ focusEpoch: this.state.focusEpoch + 1 });
  }

  /** The composer (or New Message's To: field) takes the keyboard now; true when one did. */
  focus(): boolean {
    return this.focuser?.() ?? false;
  }
}
