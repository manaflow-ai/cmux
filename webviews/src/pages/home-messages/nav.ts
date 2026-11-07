// The Messages page's view state that the list and the detail share (TopHomePageView's
// `newMessage`, `present*` and the shown conversation): the New Message draft and whether its page
// shows, the sheet over the page, the composer drafts per conversation, the open Message Requests
// and who takes the keyboard. Conversations and messages stay the Channels store's; this holds
// only what the native view held beside them.
//
// The page makes one for its whole life (main.tsx), so a daemon reconnect, which mounts a new store
// and a new shell, keeps what the person typed, the files they attached and what they had open.
// The composer drafts are also kept durably by the app (`keeper`: HomeStore's draft cache, as the
// native composer kept them), so a relaunch finds them too.
import type { ComposerTarget } from "./composerHandoff";
import type { HomeConversation } from "../home-channels/types";
import type { MessageRequest } from "./sheets/model";
import { EMPTY_DRAFT, isDraftEmpty, type RecipientDraft } from "./sheets/recipients";
import { AttachmentDrafts } from "./transcript/attachmentDrafts";

/** Where the composer drafts are kept across launches (the app's HomeStore, host.ts). */
export interface DraftKeeper {
  /** Every kept draft by conversation. */
  load(): Promise<Record<string, string>>;
  /** Keeps `text` as `conversation`'s draft; empty text clears it. */
  save(conversation: string, text: string): void;
}

/** How long typing waits before its draft goes to the keeper (one write per pause, not per key). */
export const DRAFT_SAVE_DELAY_MS = 400;

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
  /** Each conversation's draft version: a draft replaced from outside starts its composer again. */
  private readonly versions = new Map<string, number>();
  /** Drafts typed since their last save, written after a pause (``DRAFT_SAVE_DELAY_MS``). */
  private readonly unsaved = new Set<string>();
  private saveTimer: ReturnType<typeof setTimeout> | undefined;
  /** The files attached per conversation (they outlive the composer that shows them). */
  readonly attachments = new AttachmentDrafts();
  /** The conversation the page last showed: a reconnect's new store opens it again. */
  lastShown: string | undefined;
  /** The New Message page's message box text (it ends with the draft). */
  composeText = "";
  /** What takes the keyboard now (the detail registers it): true when something took it. */
  private focuser: (() => boolean) | undefined;
  /** The composer the app's hand-off reaches now (the detail registers it). */
  private composerTarget: (() => ComposerTarget | null | undefined) | undefined;

  constructor(private readonly keeper?: DraftKeeper) {}

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
    if ((this.drafts.get(conversation) ?? "") === text) return;
    if (text) this.drafts.set(conversation, text);
    else this.drafts.delete(conversation);
    if (!this.keeper) return;
    this.unsaved.add(conversation);
    // One-shot: it ends with the save it runs (or the flush that runs it first).
    this.saveTimer ??= setTimeout(() => this.flushDrafts(), DRAFT_SAVE_DELAY_MS);
  }

  /** Every draft typed since its last save goes to the keeper now (a pause, the page closing). */
  flushDrafts(): void {
    if (this.saveTimer !== undefined) clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    for (const conversation of this.unsaved) this.keeper?.save(conversation, this.drafts.get(conversation) ?? "");
    this.unsaved.clear();
  }

  /** Replaces `conversation`'s draft from outside: its composer starts again with `text`. */
  replaceDraft(conversation: string, text: string): void {
    this.keepDraft(conversation, text);
    this.versions.set(conversation, (this.versions.get(conversation) ?? 0) + 1);
    this.set({ draftEpoch: this.state.draftEpoch + 1 });
  }

  /** `conversation`'s draft version (its composer's key): it changes when the draft is replaced. */
  draftVersion(conversation: string): number {
    return this.versions.get(conversation) ?? 0;
  }

  /** Reads the kept drafts (once, as the page starts). A conversation typed in meanwhile keeps
   * what was typed; any other with a kept draft starts its composer again with it. */
  async loadDrafts(): Promise<void> {
    if (!this.keeper) return;
    let kept: Record<string, string>;
    try {
      kept = await this.keeper.load();
    } catch {
      return;
    }
    let changed = false;
    for (const [conversation, text] of Object.entries(kept)) {
      if (typeof text !== "string" || !text || this.drafts.has(conversation) || this.unsaved.has(conversation))
        continue;
      this.drafts.set(conversation, text);
      this.versions.set(conversation, (this.versions.get(conversation) ?? 0) + 1);
      changed = true;
    }
    if (changed) this.set({ draftEpoch: this.state.draftEpoch + 1 });
  }

  /** What a new store opens by itself once its inbox is read: the conversation the page showed
   * before (a reconnect), while it is listed. Nothing otherwise: the app opens its default
   * conversation (the preferred Chief, HomeDefaultConversation), as for every later choice. */
  restorable(conversations: readonly HomeConversation[]): string | undefined {
    const last = this.lastShown;
    return last && conversations.some((conversation) => conversation.id === last) ? last : undefined;
  }

  /** The detail says what takes the keyboard; the returned stop clears it. */
  setFocuser(focuser: () => boolean): () => void {
    this.focuser = focuser;
    return () => {
      if (this.focuser === focuser) this.focuser = undefined;
    };
  }

  /** The detail says which composer takes what the app hands over; the returned stop clears it. */
  setComposer(target: () => ComposerTarget | null | undefined): () => void {
    this.composerTarget = target;
    return () => {
      if (this.composerTarget === target) this.composerTarget = undefined;
    };
  }

  /** The composer that shows now (New Message's box, else the conversation's), or undefined. */
  composer(): ComposerTarget | undefined {
    return this.composerTarget?.() ?? undefined;
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
