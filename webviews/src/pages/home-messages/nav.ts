// The Messages page's view state that the list and the detail share (TopHomePageView's
// `newMessage`, `present*` and the shown conversation): the New Message draft and whether its page
// shows, the sheet over the page, the composer drafts per conversation, the open Message Requests
// and who takes the keyboard. Conversations and messages stay the Channels store's; this holds
// only what the native view held beside them.
//
// The page makes one for its whole life (main.tsx), so a daemon reconnect, which mounts a new store
// and a new shell, keeps what the person typed, the files they attached and what they had open.
// The composer drafts and the finished files are also kept durably by the app (`keeper`,
// `attachmentKeeper`: HomeStore's draft cache, as the native composer kept them), so a relaunch
// finds them too.
import type { HomeConversation } from "../home-channels/types";
import type { MessageRequest } from "./sheets/model";
import { EMPTY_DRAFT, isDraftEmpty, type RecipientDraft } from "./sheets/recipients";
import { AttachmentDrafts, type AttachmentKeeper, type KeeperAck } from "./transcript/attachmentDrafts";

/** Where the composer drafts are kept across launches (the app's HomeStore, host.ts). */
export interface DraftKeeper {
  /** Every kept draft by conversation. */
  load(): Promise<Record<string, string>>;
  /** Keeps `text` as `conversation`'s draft; empty text clears it. Resolves once the app holds it
   * (false: it refused); nothing: it holds it already. */
  save(conversation: string, text: string): KeeperAck;
}

/** Where files dragged over the conversation list go: the shown conversation's transcript, which
 * draws its drop highlight and takes them (HomeSidebarSplitView+Drop.swift). */
export interface FileDropTarget {
  /** A drag with `types` is over the list: true when the files would be taken (the highlight shows). */
  over(types: readonly string[]): boolean;
  /** The drag left the list. */
  leave(): void;
  /** The files were dropped on the list. */
  drop(files: Iterable<File>): void;
  /** The app hands the composer files (Attach Files, `cmux home attach`, a viewer quote, a browser
   * highlight: pageCommands.ts `home.messages.attach`), as a drop: their tray ids, none refused. */
  take(files: Iterable<File>): string[];
  /** The app takes back files it handed (a browser highlight removed): by their tray ids. */
  remove(ids: readonly string[]): void;
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

/** New Message holds the keyboard (its To: field or its message box has it). */
export function newMessageHasKeyboard(doc: Document | undefined = globalThis.document): boolean {
  return !!doc?.activeElement?.closest(".hm-new-message");
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
  /** Each conversation's newest draft save handed to the keeper (its number), until the app answers it. */
  private readonly saving = new Map<string, number>();
  private saves = 0;
  /** Drafts the app refused to keep (too long): they live only in this page. */
  private readonly refusedDrafts = new Set<string>();
  /** The files attached per conversation (they outlive the composer that shows them). */
  readonly attachments: AttachmentDrafts;
  /** The conversation the page last showed: a reconnect's new store opens it again. */
  lastShown: string | undefined;
  /** The New Message page's message box text (it ends with the draft). */
  composeText = "";
  /** The conversation New Message shows under To: (the chosen people already have it), if one:
   * its message box is that conversation's composer, with that conversation's draft. */
  private composeExisting: string | undefined;
  /** What takes the keyboard now (the detail registers it): true when something took it. */
  private focuser: (() => boolean) | undefined;
  /** Where files dropped on the list go now (the detail registers it); none on New Message. */
  private dropTarget: (() => FileDropTarget | undefined) | undefined;
  private replier: (() => boolean) | undefined;

  constructor(
    private readonly keeper?: DraftKeeper,
    attachmentKeeper?: AttachmentKeeper,
  ) {
    this.attachments = new AttachmentDrafts(attachmentKeeper);
  }

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
    if (this.composeIsEmpty()) this.closeCompose();
    else this.set({ compose: { ...compose, shown: false } });
  }

  /** New Message's message box text: the blank page's, or the shown conversation's draft. */
  composeMessage(): string {
    return this.composeExisting ? this.draft(this.composeExisting) : this.composeText;
  }

  /** Nothing chosen and nothing typed (HomeNewMessageView.isEmpty): Escape and leaving end it. */
  composeIsEmpty(): boolean {
    const compose = this.state.compose;
    return !compose || (isDraftEmpty(compose.draft) && !this.composeMessage().trim());
  }

  /** The chosen people changed what New Message shows under To: (`existing`: their conversation,
   * else the blank page). The typed text moves with the message box, as HomeNewMessageView's
   * `recipientsChanged`: the conversation left gives its draft up, and the one shown takes the text
   * unless it has a draft of its own. */
  composeShows(existing: string | undefined): void {
    const previous = this.composeExisting;
    if (existing === previous) return;
    const text = this.composeMessage();
    if (previous) this.keepDraft(previous, "");
    this.composeExisting = existing;
    if (existing) {
      this.composeText = "";
      if (text && !this.draft(existing)) this.replaceDraft(existing, text);
    } else {
      this.composeText = text;
    }
  }

  /** The draft, its page and its row go, whatever was typed (the row's x, `closeNewMessage`).
   * True when there was one. */
  closeCompose(): boolean {
    if (!this.state.compose) return false;
    this.composeText = "";
    this.composeExisting = undefined;
    this.set({ compose: undefined });
    return true;
  }

  /** `home.closeNewMessage`, the draft row's x and Escape (TopHomePageView.closeNewMessage): the
   * draft and its page go, the conversation shown before it comes back (`back`), and its message
   * box takes the keyboard only when New Message had it (`hadKeyboard`). True when there was one. */
  endCompose(hadKeyboard: boolean, back: (conversation: string) => void): boolean {
    const wasShowing = this.state.compose?.shown === true;
    if (!this.closeCompose()) return false;
    if (wasShowing && this.lastShown) back(this.lastShown);
    if (wasShowing && hadKeyboard) this.requestFocus();
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
    for (const conversation of this.unsaved) {
      const call = this.keeper?.save(conversation, this.drafts.get(conversation) ?? "");
      if (!call) {
        this.refusedDrafts.delete(conversation);
        continue;
      }
      const save = ++this.saves;
      this.saving.set(conversation, save);
      const answered = (held: boolean) => {
        if (this.saving.get(conversation) !== save) return;
        this.saving.delete(conversation);
        if (held) this.refusedDrafts.delete(conversation);
        else this.refusedDrafts.add(conversation);
      };
      void call.then(
        (answer) => answered(answer !== false),
        () => answered(false),
      );
    }
    this.unsaved.clear();
  }

  /** Why a web update's reload would lose something the page holds alone (pages/shared/webSwap.ts),
   * or null: a draft typed but not yet saved, or saved but not yet answered, or refused by the
   * app; a hidden New Message with people or text (the app keeps no New Message); a staged file
   * the app does not hold yet (attachmentDrafts.ts). Nothing leaves this page for the app's copy
   * before the app has said it holds it. */
  holdReason = (): string | null => {
    if (this.unsaved.size || this.saving.size || this.refusedDrafts.size) return "home.draft";
    const compose = this.state.compose;
    if (compose && !compose.shown && !this.composeIsEmpty()) return "home.newMessage";
    return this.attachments.holdReason();
  };

  /** Replaces `conversation`'s draft from outside: its composer starts again with `text`. */
  replaceDraft(conversation: string, text: string): void {
    this.keepDraft(conversation, text);
    this.versions.set(conversation, (this.versions.get(conversation) ?? 0) + 1);
    this.set({ draftEpoch: this.state.draftEpoch + 1 });
  }

  /** A gone conversation (a Chief home made again: the owner no longer lists `from`) was replaced
   * by the live Chief `to`: what the person typed and attached there goes with it, after the
   * Chief's own (`own + "\n" + text`, the files one per hash), and `from` empties, as the native
   * page's `replaceGone`. Returns whether anything went. */
  carry(from: string, to: string): boolean {
    if (from === to) return false;
    const text = this.draft(from);
    if (text) {
      const own = this.draft(to);
      this.replaceDraft(to, own ? `${own}\n${text}` : text);
      this.replaceDraft(from, "");
    }
    const files = this.attachments.carry(from, to);
    return !!text || files > 0;
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

  /** The detail says where files dropped on the list go; the returned stop clears it. */
  setFileDrop(target: () => FileDropTarget | undefined): () => void {
    this.dropTarget = target;
    return () => {
      if (this.dropTarget === target) this.dropTarget = undefined;
    };
  }

  /** Where files dropped on the list go now; undefined when nothing takes them. */
  fileDrop(): FileDropTarget | undefined {
    return this.dropTarget?.();
  }

  /** Who answers the host's Reply to Selection (the shown conversation); returns the stop. */
  setReplier(replier: () => boolean): () => void {
    this.replier = replier;
    return () => {
      if (this.replier === replier) this.replier = undefined;
    };
  }

  /** Reply to Selection: the words selected in one message open its reply with them quoted;
   * false when nothing is selected in one shown message. */
  replyToSelection(): boolean {
    return this.replier?.() ?? false;
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
