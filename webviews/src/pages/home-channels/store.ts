// The channels Home's view state: the inbox rows, the selected conversation's message window, the
// open thread and typing. All data comes from the host's `cmux.home.*` ops over the same Home
// owners the native Home reads; the page keeps only a bounded window (WINDOW messages of the open
// conversation, pages of PAGE older ones on demand) and refetches on a gap. Writes go to the host
// with an idempotency key; the owner's event is what shows them.
import { isPageError, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import { AttachmentService, messageGroups } from "./attachmentService";
import { AvatarService } from "./avatars";
import { DraftBook, type HomeDraft } from "./drafts";
import { hashLink, mergeMessages, parseConversationLink, threadOf } from "./model";
import { conversationHash, hashConversation, setHash } from "./panes";
import { LiveBook } from "./live";
import { readPresentation } from "./presentation";
import { RunBook } from "./runs";
import { HomeSheets } from "./sheets";
import {
  HomeOps,
  type HomeAttachment,
  type HomeAttachmentSupport,
  type HomeConversation,
  type HomeEventBatch,
  type HomeHistory,
  type HomeInbox,
  type HomeLiveFrame,
  type HomeLiveSnapshot,
  type HomeMarkUnreadRequest,
  type HomeMessage,
  type HomePage,
  type HomeParticipant,
  type HomePinRequest,
  type HomeResolvedLink,
  type HomeRun,
  type HomeRunList,
  type HomeRunPage,
  type HomeRunStep,
  type HomeThreadPage,
  type HomeThreadStats,
  type HomeThreadStatus,
  type HomeThreadUpdate,
} from "./types";

export const PAGE = 100;
/** Most pages a link loads to reach its message (older history, or later thread replies). */
const LINK_PAGES = 20;
/** Timeline messages (not thread replies) an opened conversation pages back to, about a screen:
 * a Chief answers in threads, so its newest page can be all replies the timeline does not draw,
 * and older history loads only on a scroll the short timeline never has (#25570). */
const FILL_TOP_LEVEL = 30;
export const WINDOW = 1500;

export type Connection = "connecting" | "online" | "offline";

/** The open thread as the owner's thread read returned it (`cmux.home.thread`), kept current by
 * events. Absent on a host without the read: the panel shows the window's replies. */
export interface ThreadView {
  root: string;
  /** The root and the loaded replies, ascending by seq. */
  messages: readonly HomeMessage[];
  /** More replies follow the last loaded one. */
  hasMore: boolean;
  loading: boolean;
}

/** A message I sent that the owner has not shown yet (optimistic): it shows at once, marked
 * sending; the owner's event with the same client message id replaces it. A failed send stays,
 * marked, until it is retried (same idempotency key) or discarded. */
export interface PendingSend {
  key: string;
  conversation: string;
  text: string;
  /** Files the message names, already stored by the owner. */
  attachments?: readonly HomeAttachment[];
  /** One send past the owner's parts per message: its messages share this id and go in their
   * order in `pending`, one after another (`HomeChannelsStore.retry`). */
  chain?: string;
  threadRoot?: string;
  replyTo?: string;
  createdAt: number;
  failed: boolean;
}

/** Pending sends that outlive one store: the page makes a new store on every reconnect, and a
 * send that failed with the old connection keeps its "Not sent" row and Retry in the new one. */
export class PendingCarry {
  entries: readonly PendingSend[] = [];
}

export interface HomeSnapshot {
  connection: Connection;
  loading: boolean;
  me?: HomeParticipant;
  conversations: ReadonlyMap<string, HomeConversation>;
  selected?: string;
  /** The open conversation's window, ascending by seq. */
  messages: readonly HomeMessage[];
  /** Older messages exist before the window's first seq. */
  hasOlder: boolean;
  loadingOlder: boolean;
  thread?: string;
  /** The open thread's owner read (root and every reply page loaded so far). */
  threadView?: ThreadView;
  /** The owner's stats of thread roots (from pages, history and thread reads), by root id. */
  threadStats: ReadonlyMap<string, HomeThreadStats>;
  /** Participant ids typing in the open conversation. */
  typing: readonly string[];
  /** Participant ids viewing the open conversation (ephemeral). */
  viewing: readonly string[];
  /** What showed as new when the conversation opened: messages after my read cursor (`after`) up
   * to the newest one then (`through`). Messages that arrive while it is open are read live. */
  unseen?: { after: number; through: number };
  /** Threads opened in this visit: their new replies are read. */
  threadsSeen: ReadonlySet<string>;
  /** The open conversation's running agent reply (shown until the reply posts). */
  draft?: HomeDraft;
  /** The message a link opened: the timeline or thread panel scrolls to it and marks it. */
  highlight?: string;
  /** My sends the owner has not shown yet, oldest first. */
  pending: readonly PendingSend[];
  /** Participants typing or writing a reply, by conversation (every conversation, not only the
   * open one): a Chief's row shows it as working. */
  activity: ReadonlyMap<string, ReadonlySet<string>>;
  /** The owner keeps my pins and marks (Pin and Mark as Unread are offered only then). */
  inboxState: boolean;
  /** Which owners take files through this host (asked once at start; absent until it answers). */
  fileSupport?: HomeAttachmentSupport;
  error?: string;
}

const describe = (error: unknown) => (isPageError(error) || error instanceof Error ? error.message : String(error));

export class HomeChannelsStore {
  private snapshot: HomeSnapshot;
  private readonly listeners = new Set<() => void>();
  private stops: Array<() => void> = [];
  private starting?: Promise<void>;
  /** Bumped by `stop`: a `begin` that a teardown overtook undoes what it set up and ends. */
  private life = 0;
  /** Between `begin` and `stop`: only a running page says that the person views something. */
  private running = false;
  private generation = 0;
  private nextKey = 0;
  /** The read cursor this page last sent per conversation (one read per new seq). */
  private readonly readSeq = new Map<string, number>();
  private readonly drafts = new DraftBook();
  /** Split sends (`PendingSend.chain`) whose messages are being delivered now. */
  private readonly chainsInFlight = new Set<string>();
  /** Agent runs (`cmux.home.runs`, `cmux.home.run`, run events): rows read them through `useRun`. */
  readonly runs = new RunBook();
  /** A Chief's live run text (`chief-live-v1`): the run card and the typing row read it. */
  readonly live = new LiveBook();
  /** Runs whose steps are being read now (one read at a time per run). */
  private readonly loadingRuns = new Set<string>();
  /** Serialize historical step reads, including reads requested by mounted run cards. */
  private runReadTail: Promise<void> = Promise.resolve();
  /** Runs whose step read failed, with the run revision it failed at: read again only after the
   * run changed (a missing run or an owner without runs is not asked in a loop). */
  private readonly failedRuns = new Map<string, number>();
  /** Who types in each conversation (typing events); activity adds the running drafts. */
  private readonly typingBy = new Map<string, Set<string>>();
  private readonly viewingBy = new Map<string, Set<string>>();

  /** Participants' pictures through this store's client (none without a client: initials). */
  readonly avatars: AvatarService | undefined;
  /** Uploads and reads of attachments through this store's client (none without a client). */
  readonly attachments: AttachmentService | undefined;
  /** The page's sheets (new message, new Chief, invite, archive) and the Chief records. */
  readonly sheets: HomeSheets;

  /** `host`: the page's host, when there is one (the app): it relays the person's click for a
   * Chief's grant and delete. */
  constructor(
    private readonly client: PageClient | null,
    private readonly carry: PendingCarry = new PendingCarry(),
    /** The page's host bridge (the app), or null in a browser: the page serves it hostSelection.ts. */
    readonly host: PageClient | null = null,
  ) {
    this.attachments = client ? new AttachmentService(client) : undefined;
    this.avatars = client ? new AvatarService(client) : undefined;
    this.sheets = new HomeSheets(client, host, {
      open: async (conversation) => {
        await this.reloadInbox();
        await this.select(conversation);
        // The page shows the conversation the sheet made (the narrow page's pane follows the hash).
        if (this.routed) setHash(conversationHash(conversation), true);
      },
      fail: (message) => this.set({ error: message }),
    });
    this.snapshot = {
      connection: client ? "connecting" : "offline",
      loading: client !== null,
      conversations: new Map(),
      messages: [],
      hasOlder: false,
      loadingOlder: false,
      typing: [],
      viewing: [],
      threadsSeen: new Set(),
      threadStats: new Map(),
      // A send still in flight on the old connection did not reach the owner as far as this
      // store knows: it shows as failed, with Retry (the same idempotency key, never twice).
      pending: carry.entries.map((entry) => ({ ...entry, failed: true })),
      activity: new Map(),
      inboxState: false,
    };
    carry.entries = this.snapshot.pending;
  }

  getSnapshot = (): HomeSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  start(): Promise<void> {
    if (!this.client) return Promise.resolve();
    this.starting ??= this.begin(this.client);
    return this.starting;
  }

  private async begin(client: PageClient): Promise<void> {
    const life = this.life;
    const live = () => life === this.life;
    // A teardown while a subscribe was pending: its stop runs now and the start goes no further.
    const keep = (stop: () => void): boolean => {
      if (live()) this.stops.push(stop);
      else stop();
      return live();
    };
    this.running = true;
    void this.attachments?.support().then((fileSupport) => this.set({ fileSupport }));
    try {
      const streams = await subscribePageStreams(client, {
        onConnection: (connected) => {
          if (!connected) {
            // The daemon ends a lost connection's viewing; a new one says it again.
            this.viewingSent = undefined;
            this.set({ connection: "offline" });
          } else if (this.snapshot.connection === "offline") void this.reloadInbox();
        },
      });
      if (!keep(streams)) return;
      const events = await client.subscribe<HomeEventBatch>(HomeOps.events, (batch) => this.apply(batch));
      if (!keep(events)) return;
      // The New and Edit Chief pages cover the conversation: not viewed while one is open.
      let covered = this.chiefPageOpen();
      const sheetChanged = () => {
        if (covered === this.chiefPageOpen()) return;
        covered = !covered;
        this.syncViewing();
      };
      this.stops.push(this.sheets.subscribe(sheetChanged));
      // Replies that came while the page was hidden are read once the person sees them.
      const shown = () => {
        if (document.visibilityState === "visible") this.readOpen();
        this.syncViewing();
      };
      document.addEventListener("visibilitychange", shown);
      this.stops.push(() => document.removeEventListener("visibilitychange", shown));
      // A closing page stops viewing (the daemon also ends it when the connection closes).
      if (typeof window !== "undefined") {
        const hidden = () => this.syncViewing(false);
        window.addEventListener("pagehide", hidden);
        this.stops.push(() => window.removeEventListener("pagehide", hidden));
      }
    } catch (error) {
      if (!live()) return;
      this.set({ error: describe(error), loading: false });
    }
    await this.reloadInbox();
    if (!live()) return;
    void this.sheets.start();
    this.followHash();
  }

  /** Opens the link in the page URL's hash (`#/conversation/<id>[/message/<id>]`) now and on every
   * change, so a host (the Messages Home's switch, a pasted URL) opens the page at one message. */
  private followHash(): void {
    if (typeof window === "undefined") return;
    const open = () => {
      // A sheet route (routes.ts) opens its sheet over the open conversation.
      if (this.sheets.follow(window.location.hash)) return;
      // A conversation the page knows opens at once (no link read: a Cloud conversation's link
      // has no resolver yet); a message link, or one the page does not know, is resolved.
      const known = hashConversation(window.location.hash);
      if (known && this.snapshot.conversations.has(known)) {
        // The page opened it already (a row click records the hash after it selects).
        if (known !== this.snapshot.selected) void this.select(known);
        return;
      }
      const link = hashLink(window.location.hash);
      if (link) void this.openLink(link);
    };
    window.addEventListener("hashchange", open);
    this.stops.push(() => window.removeEventListener("hashchange", open));
    open();
  }

  /** Opens a conversation or message link (`cmux://conversation/<id>[/message/<id>]`): the
   * conversation, the message's thread, and the message marked. Resolves true when it opened. */
  async openLink(url: string): Promise<boolean> {
    if (!this.client) return false;
    let link: HomeResolvedLink;
    try {
      link = await this.client.call<HomeResolvedLink>(HomeOps.resolveLink, { url });
    } catch (error) {
      // No resolver for this owner (a Cloud conversation, G4) or an older daemon: a conversation
      // the page knows opens at the message from its own pages (the Messages view's switch hands
      // off this way). Any other refusal of a local link (a deleted message) stays an error.
      const known = parseConversationLink(url);
      const listed = known ? this.snapshot.conversations.get(known.conversation) : undefined;
      const noResolver = isPageError(error) && error.code === "cmux.protocol.unknown_op";
      if (known && listed && (listed.owner === "cloud" || noResolver)) return this.openKnown(known);
      this.set({ error: describe(error) });
      return false;
    }
    try {
      if (!this.snapshot.conversations.has(link.conversation)) await this.reloadInbox();
      await this.select(link.conversation);
      const target = link.message;
      // A reply from before threads has no owner root; the page shows it in its reply_to thread.
      const root = link.threadRoot ?? (target ? threadOf(target) : undefined);
      if (target && root) await this.pageThreadTo(root, target.id);
      else if (target) await this.pageTimelineTo(link.conversation, target.id);
      this.set({ highlight: target?.id });
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Opens a known conversation at a message without the owner's link read: the timeline's pages
   * until the message shows, then its thread when it is a reply. */
  private async openKnown(link: { conversation: string; message?: string }): Promise<boolean> {
    try {
      await this.select(link.conversation);
      const id = link.message;
      if (id) {
        await this.pageTimelineTo(link.conversation, id);
        const found = this.snapshot.messages.find((message) => message.id === id);
        const root = found ? threadOf(found) : undefined;
        if (root) await this.pageThreadTo(root, id);
        this.set({ highlight: found ? id : undefined });
      }
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  private async pageThreadTo(root: string, id: string): Promise<void> {
    await this.openThread(root);
    await this.pageTo(
      () => this.snapshot.threadView?.messages,
      id,
      async () => {
        const view = this.snapshot.threadView;
        if (!view?.hasMore || view.root !== root) return false;
        await this.loadThread(root, view.messages.at(-1)?.seq ?? 0);
        return true;
      },
    );
  }

  private async pageTimelineTo(conversation: string, id: string): Promise<void> {
    await this.pageTo(
      () => this.snapshot.messages,
      id,
      async () => {
        if (!this.snapshot.hasOlder || this.snapshot.selected !== conversation) return false;
        await this.loadOlder();
        return true;
      },
    );
  }

  /** Loads more pages (at most LINK_PAGES) until message `id` is in `loaded()`. */
  private async pageTo(
    loaded: () => readonly HomeMessage[] | undefined,
    id: string,
    more: () => Promise<boolean>,
  ): Promise<void> {
    for (let page = 0; page < LINK_PAGES; page += 1) {
      if (loaded()?.some((message) => message.id === id)) return;
      if (!(await more())) return;
    }
  }

  private stop(): void {
    this.life++;
    this.running = false;
    this.syncViewing();
    for (const stop of this.stops) stop();
    this.stops = [];
    this.starting = undefined;
  }

  async reloadInbox(): Promise<void> {
    if (!this.client) return;
    try {
      const inbox = await this.client.call<HomeInbox>(HomeOps.inbox, {});
      const conversations = new Map(inbox.conversations.map((c) => [c.id, c]));
      const selected =
        this.snapshot.selected && conversations.has(this.snapshot.selected)
          ? this.snapshot.selected
          : defaultSelection(inbox.conversations);
      this.set({
        me: inbox.me,
        conversations,
        connection: "online",
        loading: false,
        error: undefined,
        inboxState: inbox.inboxState === true,
      });
      // The open conversation's owner is known now (a reconnect says the viewing again), and an
      // open row the list dropped is no longer viewed (even with nothing to open instead).
      this.syncViewing();
      if (selected && selected !== this.snapshot.selected) await this.select(selected, false);
      else if (selected) await this.reloadPage(selected);
    } catch (error) {
      this.set({ error: describe(error), loading: false });
    }
  }

  /** Opens a conversation: its newest page, then marks it read. */
  async select(id: string, opened = true): Promise<void> {
    if (id === this.snapshot.selected && this.snapshot.messages.length > 0) return;
    // Opening a conversation I marked unread reads it: the mark goes (not the page's own first
    // pick at load: a mark stays until I open the conversation).
    if (opened && this.snapshot.conversations.get(id)?.markedUnread) void this.setMarkedUnread(id, false);
    this.set({
      selected: id,
      messages: [],
      hasOlder: false,
      thread: undefined,
      threadView: undefined,
      threadStats: new Map(),
      typing: [],
      viewing: [...(this.viewingBy.get(id) ?? [])],
      unseen: undefined,
      threadsSeen: new Set(),
      draft: this.drafts.draft(id),
      highlight: undefined,
    });
    this.syncViewing();
    await this.reloadPage(id);
  }

  private async reloadPage(id: string): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    this.failedRuns.clear();
    try {
      const page = await this.client.call<HomePage>(HomeOps.page, { conversation: id, tail: PAGE });
      if (generation !== this.generation || this.snapshot.selected !== id) return;
      const conversations = new Map(this.snapshot.conversations).set(id, page.conversation);
      // Keep what events merged while the page was in flight (and older pages already read);
      // the snapshot wins for a message both have unless the event copy was edited later. Kept
      // messages that end before the page starts (more than a page came in since, a reconnect)
      // would leave a hole no older page fills: the window starts at the page then (#25570).
      const kept = joining(
        this.snapshot.messages.filter((m) => m.conversation === id),
        page.messages[0]?.seq,
      );
      const fresh = page.messages.map((m) => {
        const event = kept.find((k) => k.seq === m.seq);
        return event && (event.editedAt ?? 0) > (m.editedAt ?? 0) ? event : m;
      });
      const messages = mergeMessages(kept, fresh, WINDOW);
      const unseen = this.snapshot.unseen ?? {
        after: page.conversation.lastSeq - page.conversation.unread,
        through: page.conversation.lastSeq,
      };
      // A reply that came in with this page (not as an event: a gap, a large batch) ends its draft.
      const live = this.drafts.draft(id);
      const reply = live && messages.find((m) => m.clientMessageId === live.turn && m.author === live.participant);
      if (reply) this.drafts.posted(reply);
      if (reply) this.set({ activity: this.currentActivity() });
      this.set({
        conversations,
        messages,
        pending: this.settled(messages) ?? this.snapshot.pending,
        hasOlder: (messages[0]?.seq ?? 1) > 1,
        unseen,
        draft: this.drafts.draft(id),
        threadStats: withStats(this.snapshot.threadStats, page.threads),
      });
      this.runs.noteMessages(messages);
      void this.loadRuns(id, messages, true);
      void this.loadLive(id);
      if (this.shown) this.markRead(page.conversation, messages.at(-1)?.seq ?? 0);
    } catch (error) {
      if (generation === this.generation) this.set({ error: describe(error) });
      return;
    }
    await this.fillTimeline(id, generation);
  }

  /** Pages older history (at most LINK_PAGES) until the timeline has FILL_TOP_LEVEL messages
   * to show or the conversation's start is in. */
  private async fillTimeline(id: string, generation: number): Promise<void> {
    const life = this.life;
    for (let page = 0; page < LINK_PAGES; page += 1) {
      const { selected, messages, hasOlder } = this.snapshot;
      if (generation !== this.generation || life !== this.life || selected !== id || !hasOlder) return;
      if (messages.filter((m) => !threadOf(m)).length >= FILL_TOP_LEVEL) return;
      const before = messages[0]?.seq;
      await this.loadOlder();
      if (this.snapshot.messages[0]?.seq === before) return;
    }
  }

  /** One page of older messages before the window (scrolling to the top). */
  async loadOlder(): Promise<void> {
    const { selected, messages, hasOlder, loadingOlder } = this.snapshot;
    if (!this.client || !selected || !hasOlder || loadingOlder) return;
    const before = messages[0]?.seq ?? 1;
    const generation = this.generation;
    const life = this.life;
    this.set({ loadingOlder: true });
    try {
      if (this.life !== life) return;
      const older = await this.client.call<HomeHistory>(HomeOps.history, {
        conversation: selected,
        beforeSeq: before,
        limit: PAGE,
      });
      // A reload since (a reconnect) may have moved the window: this page goes before the old one.
      if (this.snapshot.selected !== selected || this.generation !== generation || this.life !== life) return;
      if ((this.snapshot.messages[0]?.seq ?? 1) !== before) return;
      const merged = mergeMessages(this.snapshot.messages, older.messages, this.snapshot.messages.length + PAGE);
      this.set({
        messages: merged,
        hasOlder: older.messages.length === PAGE && (merged[0]?.seq ?? 1) > 1,
        threadStats: withStats(this.snapshot.threadStats, older.threads),
      });
      this.runs.noteMessages(older.messages);
      void this.loadRuns(selected, older.messages, false);
    } catch (error) {
      this.set({ error: describe(error) });
    } finally {
      this.set({ loadingOlder: false });
    }
  }

  /** Opens (or closes) a thread; resolves when its first replies are loaded. */
  openThread(root: string | undefined): Promise<void> {
    const threadView = root ? { root, messages: [], hasMore: false, loading: true } : undefined;
    if (!root || this.snapshot.threadsSeen.has(root)) this.set({ thread: root, threadView });
    else this.set({ thread: root, threadView, threadsSeen: new Set(this.snapshot.threadsSeen).add(root) });
    return root ? this.loadThread(root, 0) : Promise.resolve();
  }

  /** The next page of the open thread's replies (the owner's thread read). */
  loadMoreReplies(): void {
    const view = this.snapshot.threadView;
    if (!view || view.loading || !view.hasMore) return;
    this.set({ threadView: { ...view, loading: true } });
    void this.loadThread(view.root, view.messages.at(-1)?.seq ?? 0);
  }

  private async loadThread(root: string, afterSeq: number): Promise<void> {
    const conversation = this.snapshot.selected;
    if (!this.client || !conversation) return;
    const current = () => this.snapshot.selected === conversation && this.snapshot.threadView?.root === root;
    try {
      const page = await this.client.call<HomeThreadPage>(HomeOps.thread, {
        conversation,
        root,
        afterSeq,
        limit: PAGE,
      });
      if (!current()) return;
      const view = this.snapshot.threadView!;
      const messages = mergeMessages(view.messages, [page.root, ...page.replies], Number.MAX_SAFE_INTEGER);
      this.runs.noteMessages(messages);
      void this.loadRuns(conversation, messages, false);
      this.set({
        threadView: { root, messages, hasMore: page.hasMore, loading: false },
        threadStats: withStats(this.snapshot.threadStats, [page.thread]),
      });
    } catch (error) {
      if (!current()) return;
      // A host without the read: the panel shows the window's replies (no view).
      const unknown = isPageError(error) && error.code === "cmux.protocol.unknown_op";
      this.set({ threadView: undefined, ...(unknown ? {} : { error: describe(error) }) });
    }
  }

  /** Sends text to the open conversation, or in the open thread as a reply to `parent` (the root
   * or any reply: threads nest without a limit). Optimistic: the message shows at once as pending
   * and the composer clears; the owner's event replaces it. Any number of files goes: past the
   * owner's parts per message they go as several messages, in order (`messageGroups`), each its
   * own pending row and idempotency key. Resolves false only when nothing was sent (no
   * conversation, empty text). */
  async send(
    text: string,
    thread?: string,
    parent?: string,
    attachments?: readonly HomeAttachment[],
  ): Promise<boolean> {
    const conversation = this.snapshot.selected;
    const trimmed = text.trim();
    if (!this.client || !conversation || (!trimmed && !attachments?.length)) return false;
    const createdAt = Date.now();
    const groups = messageGroups(trimmed, attachments ?? []);
    const keys = groups.map(() => this.key("send"));
    const chain = groups.length > 1 ? keys[0] : undefined;
    const sends = groups.map((group, index): PendingSend => ({
      key: keys[index]!,
      ...(chain ? { chain } : {}),
      conversation,
      text: group.text,
      createdAt,
      failed: false,
      ...(group.files.length ? { attachments: group.files } : {}),
      ...(thread ? { threadRoot: thread } : {}),
      ...(parent ? { replyTo: parent } : {}),
    }));
    this.set({ pending: [...this.snapshot.pending, ...sends] });
    void this.deliverInOrder(sends);
    return true;
  }

  /** Delivers messages of one send strictly one after another, so the owner orders them as they
   * were sent. The first that fails stops it: it and the rest of `sends` show "Not sent" (held),
   * and a Retry of any of them goes on from the earliest (`retry`). */
  private async deliverInOrder(sends: readonly PendingSend[]): Promise<void> {
    const chain = sends[0]?.chain;
    if (chain) this.chainsInFlight.add(chain);
    try {
      for (const [index, pending] of sends.entries()) {
        if (await this.deliver(pending)) continue;
        const held = new Set(sends.slice(index + 1).map((entry) => entry.key));
        if (held.size > 0) {
          this.set({
            pending: this.snapshot.pending.map((entry) => (held.has(entry.key) ? { ...entry, failed: true } : entry)),
          });
        }
        return;
      }
    } finally {
      if (chain) this.chainsInFlight.delete(chain);
    }
  }

  /** Sends a failed pending message again with its own idempotency key (never twice). A message of
   * a send split into several goes again with every other failed one of that send, from the
   * earliest, in order (so a held one never passes the one it waits for); a chain already going
   * is left alone. The chain id rides on the pending row, so this holds after a reconnect too. */
  retry(key: string): void {
    const pending = this.snapshot.pending.find((entry) => entry.key === key);
    if (!pending) return;
    if (pending.chain) return this.resumeChain(pending.chain);
    const again = { ...pending, failed: false };
    this.set({ pending: this.snapshot.pending.map((entry) => (entry.key === key ? again : entry)) });
    void this.deliver(again);
  }

  /** Drops a pending message. The rest of its send, if held behind it, goes on. */
  discard(key: string): void {
    const pending = this.snapshot.pending.find((entry) => entry.key === key);
    this.set({ pending: this.snapshot.pending.filter((entry) => entry.key !== key) });
    if (pending?.chain) this.resumeChain(pending.chain);
  }

  /** Delivers the failed messages of split send `chain` again, in their order, unless it is
   * going already. */
  private resumeChain(chain: string): void {
    if (this.chainsInFlight.has(chain)) return;
    const sends = this.snapshot.pending
      .filter((entry) => entry.chain === chain && entry.failed)
      .map((entry) => ({ ...entry, failed: false }));
    if (sends.length === 0) return;
    this.set({
      pending: this.snapshot.pending.map((entry) => sends.find((send) => send.key === entry.key) ?? entry),
    });
    void this.deliverInOrder(sends);
  }

  /** Resolves true when the owner took it. */
  private async deliver(pending: PendingSend): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(HomeOps.send, {
        conversation: pending.conversation,
        text: pending.text,
        attachments: pending.attachments,
        threadRoot: pending.threadRoot,
        replyTo: pending.replyTo,
        idempotencyKey: pending.key,
      });
      // The owner's event may have come first (or a retry was a replay of a message already in
      // the window): settle from what the page holds now.
      const held = [...this.snapshot.messages, ...(this.snapshot.threadView?.messages ?? [])];
      const left = this.settled(held);
      if (left) this.set({ pending: left });
      return true;
    } catch (error) {
      // Gone already: the owner's event settled it (the answer was lost), or it was discarded.
      if (!this.snapshot.pending.some((entry) => entry.key === pending.key)) return true;
      this.set({
        error: describe(error),
        pending: this.snapshot.pending.map((entry) => (entry.key === pending.key ? { ...entry, failed: true } : entry)),
      });
      return false;
    }
  }

  /** Drops the pending sends these owner messages show (same client message id). */
  private settled(messages: readonly HomeMessage[]): readonly PendingSend[] | undefined {
    if (this.snapshot.pending.length === 0 || messages.length === 0) return undefined;
    const keys = new Set(messages.map((message) => message.clientMessageId).filter(Boolean));
    const left = this.snapshot.pending.filter((entry) => !keys.has(entry.key));
    return left.length === this.snapshot.pending.length ? undefined : left;
  }

  /** Adds my reaction, or takes it back when I already reacted with it. */
  async react(message: HomeMessage, value: string): Promise<void> {
    if (!this.client) return;
    const mine = message.reactions.find((r) => r.value === value && r.author === this.snapshot.me?.id);
    try {
      await this.client.call(HomeOps.react, {
        conversation: message.conversation,
        message: message.id,
        partIndex: mine?.partIndex ?? 0,
        value,
        tapback: mine?.tapback,
        remove: mine !== undefined,
        idempotencyKey: this.key("react"),
      });
    } catch (error) {
      this.set({ error: describe(error) });
    }
  }

  /** Replaces my message's text. Resolves true when the owner took it. */
  async edit(message: HomeMessage, text: string): Promise<boolean> {
    const trimmed = text.trim();
    if (!this.client || !trimmed) return false;
    try {
      await this.client.call(HomeOps.edit, {
        conversation: message.conversation,
        message: message.id,
        text: trimmed,
        idempotencyKey: this.key("edit"),
      });
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Sets a thread's title, status or owner (any participant; an empty title or owner clears it).
   * The owner answers with the root's message-updated event. Resolves true when the owner took it. */
  async updateThread(
    root: HomeMessage,
    fields: { title?: string; status?: HomeThreadStatus; owner?: string },
  ): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(HomeOps.updateThread, {
        conversation: root.conversation,
        root: root.id,
        ...fields,
        idempotencyKey: this.key("thread"),
      } satisfies HomeThreadUpdate);
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Pins or unpins a conversation in my list. Optimistic: the row moves at once (a new pin goes
   * last); the owner's change replaces it, and a refusal puts the row back. Resolves true when the
   * owner took it. */
  async setPinned(id: string, pinned: boolean): Promise<boolean> {
    const before = this.snapshot.conversations.get(id);
    if (!this.client || !before || before.pinned === pinned) return false;
    const last = Math.max(0, ...[...this.snapshot.conversations.values()].map((c) => c.pinPosition ?? 0));
    this.patchConversation(
      id,
      pinned ? { pinned, pinPosition: Math.max(Date.now(), last + 1) } : { pinned, pinPosition: undefined },
    );
    try {
      await this.client.call(HomeOps.pin, {
        conversation: id,
        pinned,
        idempotencyKey: this.key("pin"),
      } satisfies HomePinRequest);
      return true;
    } catch (error) {
      // Back, unless the owner's own change came meanwhile.
      if (this.snapshot.conversations.get(id)?.pinned === pinned)
        this.patchConversation(id, { pinned: before.pinned, pinPosition: before.pinPosition });
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Flags a conversation unread (the read cursor stays) or clears the flag. Optimistic, as a pin. */
  async setMarkedUnread(id: string, unread: boolean): Promise<boolean> {
    const before = this.snapshot.conversations.get(id);
    if (!this.client || !before || (before.markedUnread === true) === unread) return false;
    this.patchConversation(id, { markedUnread: unread });
    try {
      await this.client.call(HomeOps.markUnread, {
        conversation: id,
        unread,
        idempotencyKey: this.key("unread"),
      } satisfies HomeMarkUnreadRequest);
      return true;
    } catch (error) {
      if ((this.snapshot.conversations.get(id)?.markedUnread === true) === unread)
        this.patchConversation(id, { markedUnread: before.markedUnread });
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Mark as Read: my read cursor to the newest message, and my unread mark cleared. */
  markConversationRead(id: string): void {
    const conversation = this.snapshot.conversations.get(id);
    if (!conversation) return;
    if (conversation.markedUnread) void this.setMarkedUnread(id, false);
    this.markRead(conversation, conversation.lastSeq);
  }

  private patchConversation(id: string, patch: Partial<HomeConversation>): void {
    const current = this.snapshot.conversations.get(id);
    if (!current) return;
    const next: HomeConversation = { ...current, ...patch };
    if (next.pinPosition === undefined) delete next.pinPosition;
    if (!next.markedUnread) delete next.markedUnread;
    this.set({ conversations: new Map(this.snapshot.conversations).set(id, next) });
  }

  /** Deletes my message for everyone (the owner keeps a "deleted" row). */
  async retract(message: HomeMessage): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(HomeOps.retract, {
        conversation: message.conversation,
        message: message.id,
        idempotencyKey: this.key("retract"),
      });
    } catch (error) {
      this.set({ error: describe(error) });
    }
  }

  dismissError(): void {
    this.set({ error: undefined });
  }

  /** Whether the open conversation is on screen: the narrow page's list pane hides it, and a
   * conversation nobody sees is not read (its unread count stays). */
  private shown = true;
  /** The page's hash names the open conversation (false: the gallery, which owns its window hash). */
  routed = true;

  setShown(shown: boolean): void {
    if (shown === this.shown) return;
    this.shown = shown;
    if (shown) this.readOpen();
    this.syncViewing();
  }

  /** Whether the New or Edit Chief page covers the conversation. */
  private chiefPageOpen(): boolean {
    const route = this.sheets.getSnapshot().route?.kind;
    return route === "newChief" || route === "editChief";
  }

  /** The Cloud conversation this page last said the person views (cmux.home.view). */
  private viewingSent?: string;
  /** Bumped by each change `syncViewing` sends: a late answer applies only to its own attempt. */
  private viewAttempt = 0;

  /** Tells the owner which Cloud conversation the person views: the open one while the page and
   * its pane show it, none otherwise (a row that left the list, a page torn down). Only a change
   * goes out; a local conversation sends nothing (its owner has no viewing presence). `active`
   * false: the page stops viewing (it closes). */
  private syncViewing(active = true): void {
    const { selected } = this.snapshot;
    const visible = typeof document === "undefined" || document.visibilityState !== "hidden";
    const cloud = selected !== undefined && this.snapshot.conversations.get(selected)?.owner === "cloud";
    const covered = this.chiefPageOpen();
    const want = active && this.running && this.shown && visible && cloud && !covered ? selected : undefined;
    const before = this.viewingSent;
    if (want === before || !this.client) return;
    this.viewingSent = want;
    const attempt = ++this.viewAttempt;
    const view = (conversation: string, viewing: boolean) =>
      this.client?.call<{ sent?: boolean }>(HomeOps.view, { conversation, viewing }).catch(() => undefined);
    if (before) void view(before, false);
    if (want)
      void view(want, true)?.then((answer) => {
        // Not sent (the subscribe was refused): the owner never heard it, so the next show,
        // switch or reconnect says it again.
        if (answer?.sent === false && attempt === this.viewAttempt) this.viewingSent = undefined;
      });
  }

  /** Reads the open conversation through its newest loaded message. */
  private readOpen(): void {
    if (!this.shown) return;
    const { selected, messages } = this.snapshot;
    const open = selected ? this.snapshot.conversations.get(selected) : undefined;
    if (open) this.markRead(open, messages.at(-1)?.seq ?? 0);
  }

  /** Moves my read cursor to the newest seq I have seen, once per new seq. */
  private markRead(conversation: HomeConversation, seen: number): void {
    const seq = Math.max(conversation.lastSeq, seen);
    const cursor = Math.max(conversation.lastSeq - conversation.unread, this.readSeq.get(conversation.id) ?? 0);
    if (!this.client || seq <= cursor) return;
    this.readSeq.set(conversation.id, seq);
    void this.client
      .call(HomeOps.read, { conversation: conversation.id, seq, idempotencyKey: this.key("read") })
      .catch(() => this.readSeq.delete(conversation.id));
  }

  /** Applies one coalesced host batch. */
  private apply(batch: HomeEventBatch): void {
    const patch: Partial<HomeSnapshot> = {};
    if (batch.connection) patch.connection = batch.connection;
    // Typing is ephemeral: a reconnect or an inbox refetch ends every indicator.
    if (batch.connection || batch.inboxStale) patch.typing = [];
    // Each presence frame is the whole set, so only lost frames make it stale: a lost connection
    // or a stream overflow (an inbox refetch keeps it: the conversation sockets stay subscribed).
    // Unknown shows as nobody, never as someone who left; the owner's next set brings them back.
    if (batch.connection || batch.presenceLost) {
      this.viewingBy.clear();
      patch.viewing = [];
    }
    if (batch.connection === "offline") {
      this.drafts.clear();
      this.live.clear();
    }
    // Drafts first, then typing off and the posted messages: a reply that posts in the same
    // batch as its last draft item ends the draft, and a late item cannot bring it back.
    for (const item of batch.drafts ?? []) this.drafts.apply(item);
    for (const entry of batch.typing ?? []) if (!entry.on) this.drafts.typingOff(entry.conversation, entry.participant);
    for (const message of batch.messages ?? []) this.drafts.posted(message);
    if (batch.runs?.length) this.runs.apply(batch.runs);
    if (batch.avatars?.length) this.avatars?.changed(batch.avatars);
    if (batch.messages?.length) this.runs.noteMessages(batch.messages);
    this.applyLive(batch);
    let conversations: Map<string, HomeConversation> | undefined;
    for (const conversation of batch.conversations ?? []) {
      conversations ??= new Map(this.snapshot.conversations);
      conversations.set(conversation.id, conversation);
    }
    for (const id of batch.removed ?? []) {
      conversations ??= new Map(this.snapshot.conversations);
      conversations.delete(id);
    }
    for (const change of batch.inbox ?? []) {
      const current = (conversations ?? this.snapshot.conversations).get(change.conversation);
      if (!current) continue;
      conversations ??= new Map(this.snapshot.conversations);
      const next: HomeConversation = { ...current, pinned: change.pinned };
      delete next.pinPosition;
      delete next.markedUnread;
      if (change.pinPosition !== undefined) next.pinPosition = change.pinPosition;
      if (change.markedUnread) next.markedUnread = true;
      conversations.set(change.conversation, next);
    }
    if (conversations) patch.conversations = conversations;
    const selected = this.snapshot.selected;
    const incoming = (batch.messages ?? []).filter((message) => message.conversation === selected);
    if (incoming.length > 0) patch.messages = mergeMessages(this.snapshot.messages, incoming, WINDOW);
    const left = this.settled(batch.messages ?? []);
    if (left) patch.pending = left;
    const activity = this.activityAfter(batch);
    if (activity) patch.activity = activity;
    // The open thread's view takes its root and replies from events too (a reply, an edit).
    const view = this.snapshot.threadView;
    // The merged copies: a reply without a root has its thread's root there (model `withThreadRoots`).
    const merged = new Map((patch.messages ?? []).map((m) => [m.id, m]));
    const threadIncoming = view
      ? incoming.map((m) => merged.get(m.id) ?? m).filter((m) => m.id === view.root || threadOf(m) === view.root)
      : [];
    if (view && threadIncoming.length > 0) {
      // Only what follows the loaded pages: a reply between pages comes with the next page.
      const tail = view.hasMore
        ? threadIncoming.filter((m) => view.messages.some((k) => k.seq === m.seq))
        : threadIncoming;
      patch.threadView = { ...view, messages: mergeMessages(view.messages, tail, Number.MAX_SAFE_INTEGER) };
    }
    if (batch.presence)
      for (const entry of batch.presence) {
        const people = new Set(entry.participants.filter((p) => p.viewing).map((p) => p.participant));
        if (people.size) this.viewingBy.set(entry.conversation, people);
        else this.viewingBy.delete(entry.conversation);
        if (entry.conversation === selected) patch.viewing = [...people];
      }
    if (batch.typing && selected) {
      const typing = new Set(this.snapshot.typing);
      for (const entry of batch.typing) {
        if (entry.conversation !== selected) continue;
        if (entry.on) typing.add(entry.participant);
        else typing.delete(entry.participant);
      }
      patch.typing = [...typing];
    }
    if (selected) {
      const draft = this.drafts.draft(selected);
      if (draft?.text !== this.snapshot.draft?.text || draft?.turn !== this.snapshot.draft?.turn) patch.draft = draft;
    }
    this.set(patch);
    // The open row left the list (removed, archived): the person no longer views it.
    if (conversations) this.syncViewing();
    const open = selected ? this.snapshot.conversations.get(selected) : undefined;
    if (open && incoming.length > 0 && document.visibilityState === "visible") {
      if (this.shown) this.markRead(open, Math.max(...incoming.map((m) => m.seq)));
    }
    if (batch.inboxStale) void this.reloadInbox();
    else if (selected && batch.stale?.includes(selected)) void this.reloadPage(selected);
  }

  /** A batch's live frames, then what ends live text: a run that left `running`, a posted reply
   * (it replaces the streaming text). A missed frame asks for the conversation's snapshot. */
  private applyLive(batch: HomeEventBatch): void {
    if (batch.live?.length) {
      for (const conversation of this.live.apply(batch.live.map((frame) => this.withAuthor(frame))))
        void this.loadLive(conversation);
    }
    for (const { run, steps } of batch.runs ?? []) {
      if (run.status !== "running") this.live.end(run.conversation, run.author, run.id);
      const rows = steps.filter((step) => step.kind === "talk" || step.kind === "thought").map((step) => step.id);
      if (rows.length) this.live.rowsWritten(run.conversation, run.author, run.id, rows);
    }
    for (const message of batch.messages ?? []) this.live.posted(message, (m) => this.runs.forReply(m)?.run.id);
  }

  /** A frame from an owner that does not stamp the author: its run's (the running run with that id). */
  private withAuthor(frame: HomeLiveFrame): HomeLiveFrame {
    if (frame.type === "run.live") {
      const runs = frame.runs.map((run) =>
        run.author ? run : { ...run, author: this.runAuthor(frame.conversation, run.run) },
      );
      return { ...frame, runs };
    }
    return frame.author ? frame : { ...frame, author: this.runAuthor(frame.conversation, frame.run) };
  }

  /** Best effort: the first running run with that id (an owner that stamps no author; two Cloud
   * Chiefs with the same run id could be confused there). */
  private runAuthor(conversation: string, run: string): string | undefined {
    return this.runs.running(conversation).find((candidate) => candidate.id === run)?.author;
  }

  /** The owner's `run.live` snapshot of a conversation (open, reconnect, gap). A Cloud owner
   * answers with a live event instead; a host without live frames answers nothing. */
  private async loadLive(conversation: string): Promise<void> {
    if (!this.client) return;
    try {
      const snapshot = await this.client.call<HomeLiveSnapshot | null>(HomeOps.live, { conversation });
      if (snapshot && snapshot.type === "run.live") this.live.snapshot(this.withAuthor(snapshot) as HomeLiveSnapshot);
    } catch {
      // No live text: the run card and the typing row show what the runs and typing say.
    }
  }

  /** Who types or writes a reply in each conversation after this batch (undefined: no change).
   * Rebuilt from the typing map and the live drafts each time, so a draft that ends with no
   * posted message, or a reply that ends its draft through a page reload, clears it too. */
  private activityAfter(batch: HomeEventBatch): ReadonlyMap<string, ReadonlySet<string>> | undefined {
    // A reconnect or an inbox refetch ends every indicator (typing is ephemeral).
    if (batch.connection || batch.inboxStale) this.typingBy.clear();
    for (const entry of batch.typing ?? []) {
      const people = this.typingBy.get(entry.conversation) ?? new Set<string>();
      if (entry.on) people.add(entry.participant);
      else people.delete(entry.participant);
      if (people.size > 0) this.typingBy.set(entry.conversation, people);
      else this.typingBy.delete(entry.conversation);
    }
    // A posted message ends its author's typing.
    for (const message of batch.messages ?? []) this.typingBy.get(message.conversation)?.delete(message.author);
    const touched =
      batch.connection ||
      batch.inboxStale ||
      batch.typing?.length ||
      batch.drafts?.length ||
      batch.messages?.length ||
      batch.runs?.length;
    return touched ? this.currentActivity() : undefined;
  }

  /** Typing plus the running drafts, by conversation. */
  private currentActivity(): ReadonlyMap<string, ReadonlySet<string>> {
    const next = new Map<string, ReadonlySet<string>>();
    const conversations = new Set([...this.typingBy.keys(), ...this.snapshot.conversations.keys()]);
    for (const conversation of conversations) {
      const people = new Set(this.typingBy.get(conversation) ?? []);
      const draft = this.drafts.draft(conversation);
      if (draft) people.add(draft.participant);
      // A Chief whose run still works is working, also between its tool calls.
      for (const run of this.runs.running(conversation)) people.add(run.author);
      if (people.size > 0) next.set(conversation, people);
    }
    return next;
  }

  /** Reads the runs of these messages' replies (agent messages carry their run's key), then pages
   * run history far enough to include silent runs attached to the messages in this window. A host
   * without runs answers nothing: the page shows no run cards. */
  private async loadRuns(conversation: string, messages: readonly HomeMessage[], newest: boolean): Promise<void> {
    if (!this.client) return;
    // A newest reload with no messages still needs background-run discovery. An empty older
    // page has no new anchors and must not start an unrelated history scan.
    if (messages.length === 0 && !newest) return;
    const generation = this.generation;
    const life = this.life;
    const agents = new Set(
      (this.snapshot.conversations.get(conversation)?.participants ?? [])
        .filter((participant) => participant.kind === "agent")
        .map((participant) => participant.id),
    );
    const active = () => generation === this.generation && life === this.life;
    const replyKeys = new Set(
      messages
        .filter((message) => message.clientMessageId && agents.has(message.author))
        .map((message) => `${message.author}\0${message.clientMessageId}`),
    );
    const turns = [
      ...new Set(
        messages
          .filter((message) => agents.has(message.author))
          .flatMap((message) => (message.clientMessageId ? [message.clientMessageId] : [])),
      ),
    ];
    const messageIds = new Set(messages.map((message) => message.id));
    const unresolvedReplies = new Set(replyKeys);
    const published = new Map<string, HomeRun>();
    // With no messages there are no direct answer keys to resolve, but the newest-runs
    // query still restores background activity when a conversation is reopened.
    let answersComplete = true;
    // Publish and hydrate each successful batch before asking for more history. A slow or failed
    // later page must not hold back the rows already found for the visible conversation.
    const publish = async (runs: readonly HomeRun[], direct = false) => {
      if (!active()) return;
      const fresh: HomeRun[] = [];
      for (const run of runs) {
        const reply = run.turn ? `${run.author}\0${run.turn}` : undefined;
        if (reply) unresolvedReplies.delete(reply);
        const key = `${run.author}\0${run.id}`;
        const previous = published.get(key);
        // Direct queries and history often return the same summary. Invalidate unversioned
        // cached steps only once per load, otherwise a later duplicate undoes hydration.
        if (
          previous &&
          previous.rev >= run.rev &&
          previous.updatedAt >= run.updatedAt &&
          previous.stepCount >= run.stepCount &&
          previous.status === run.status
        )
          continue;
        published.set(key, run);
        fresh.push(run);
      }
      this.runs.setRuns(fresh);
      for (const run of fresh) {
        if (!active()) return;
        const reply = run.turn ? `${run.author}\0${run.turn}` : undefined;
        if (direct || run.answers.some((answer) => messageIds.has(answer)) || (reply && replyKeys.has(reply))) {
          // Cloud has no increasing revision to unlock a failed read. Each fresh lookup is a
          // retry boundary; mounted cards alone must not retry failures in a loop.
          if (run.rev === 0) this.failedRuns.delete(`${run.conversation}\0${run.author}\0${run.id}`);
          if (readPresentation(conversation) !== "transcript") await this.loadRunSteps(run);
        }
      }
    };
    try {
      for (const [field, ids] of [
        ["turns", turns],
        ["answers", [...messageIds]],
      ] as const) {
        for (let offset = 0; offset < ids.length; offset += 200) {
          if (!active()) return;
          const list: HomeRunList = await this.client
            .call<HomeRunList>(HomeOps.runs, {
              conversation,
              [field]: ids.slice(offset, offset + 200),
            })
            .catch(() => ({ runs: [], hasMore: false }));
          if (!active()) return;
          if (field === "answers" && list.answersComplete !== true) answersComplete = false;
          await publish(list.runs, true);
        }
      }
      // Local answer lookups cover silent reports regardless of their assignment's start time.
      // Cloud lacks direct lookups: scan past the timestamp boundary until loaded reply keys
      // resolve, while making each page visible immediately.
      const oldestMessageAt = messages.reduce<number | undefined>(
        (oldest, message) => (oldest === undefined ? message.createdAt : Math.min(oldest, message.createdAt)),
        undefined,
      );
      let beforeStartedAt: number | undefined;
      let page = 0;
      for (;;) {
        if (!active()) return;
        const params: Record<string, unknown> = { conversation, limit: newest && page === 0 ? 20 : 50 };
        page += 1;
        if (beforeStartedAt !== undefined) params.beforeStartedAt = beforeStartedAt;
        let list: HomeRunList;
        try {
          list = await this.client.call<HomeRunList>(HomeOps.runs, params);
        } catch {
          break;
        }
        if (!active()) return;
        await publish(list.runs);
        const oldestRun = list.runs.reduce<number | undefined>(
          (oldest, run) => (oldest === undefined ? run.startedAt : Math.min(oldest, run.startedAt)),
          undefined,
        );
        if (
          !list.hasMore ||
          oldestRun === undefined ||
          (unresolvedReplies.size === 0 &&
            (answersComplete || (oldestMessageAt !== undefined && oldestRun <= oldestMessageAt)))
        )
          break;
        // The protocol uses a strict less-than cursor; guard malformed owners that do not move it.
        if (beforeStartedAt !== undefined && oldestRun >= beforeStartedAt) break;
        beforeStartedAt = oldestRun;
      }
    } catch {
      // Runs are display only; a host or owner without them shows plain messages.
    }
  }

  /** Reads every step of a run from its owner (pages of steps by revision). */
  loadRunSteps = async (run: HomeRun): Promise<void> => {
    const key = `${run.conversation}\0${run.author}\0${run.id}`;
    const readKey = `${this.generation}\0${this.life}\0${key}`;
    if (!this.client || this.loadingRuns.has(readKey)) return;
    const failed = this.failedRuns.get(key);
    if (failed !== undefined && failed >= run.rev) return;
    const held = this.runs.get(run.conversation, run.author, run.id);
    if (held?.complete && held.run.rev >= run.rev && held.run.stepCount >= run.stepCount) return;
    const generation = this.generation;
    const life = this.life;
    const previous = this.runReadTail;
    let release!: () => void;
    this.runReadTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    this.loadingRuns.add(readKey);
    try {
      await previous;
      if (generation !== this.generation || life !== this.life) return;
      // The local owner pages by revision; a Cloud brain (keyed by its Chief) by seq.
      let afterRev = 0;
      let afterSeq = 0;
      const steps: HomeRunStep[] = [];
      let latest = run;
      let complete = false;
      for (;;) {
        const read = await this.client.call<HomeRunPage>(HomeOps.run, {
          conversation: run.conversation,
          run: run.id,
          agent: run.author,
          afterRev,
          afterSeq,
        });
        if (generation !== this.generation || life !== this.life) return;
        latest = read.run;
        steps.push(...read.steps);
        const nextRev = Math.max(afterRev, ...read.steps.map((step) => step.rev));
        const nextSeq = Math.max(afterSeq, ...read.steps.map((step) => step.seq));
        const advanced = nextRev > afterRev || nextSeq > afterSeq;
        afterRev = nextRev;
        afterSeq = nextSeq;
        if (!read.hasMore) {
          complete = true;
          break;
        }
        // An owner that claims another page but returns no new cursor must not spin forever. Keep
        // this partial read retryable so a later event can advance the owner's revision/sequence.
        if (read.steps.length === 0 || !advanced) break;
      }
      if (complete) this.failedRuns.delete(key);
      else this.failedRuns.set(key, latest.rev);
      this.runs.setSteps(latest, steps, complete);
    } catch {
      // Display only: the card keeps the summary and the steps events brought.
      if (generation === this.generation && life === this.life) this.failedRuns.set(key, run.rev);
    } finally {
      this.loadingRuns.delete(readKey);
      release();
    }
  };

  private key(kind: string): string {
    return `home-channels-${kind}-${Date.now().toString(36)}-${(this.nextKey++).toString(36)}`;
  }

  private set(patch: Partial<HomeSnapshot>): void {
    const previous = this.snapshot;
    this.snapshot = { ...previous, ...patch };
    if (
      previous.messages !== this.snapshot.messages ||
      previous.threadView?.messages !== this.snapshot.threadView?.messages
    )
      this.runs.setLoadedMessages([...this.snapshot.messages, ...(this.snapshot.threadView?.messages ?? [])]);
    if (patch.pending) this.carry.entries = patch.pending;
    for (const listener of this.listeners) listener();
  }
}

/** The stats map with these owner stats replacing the roots they name. */
function withStats(
  current: ReadonlyMap<string, HomeThreadStats>,
  stats: readonly HomeThreadStats[] | undefined,
): ReadonlyMap<string, HomeThreadStats> {
  if (!stats || stats.length === 0) return current;
  const next = new Map(current);
  for (const entry of stats) next.set(entry.root, entry);
  return next;
}

/** The Chief DM first, else the newest conversation. */
function defaultSelection(conversations: readonly HomeConversation[]): string | undefined {
  const chief = conversations.find((c) => c.kind === "chief");
  if (chief) return chief.id;
  return [...conversations].sort((a, b) => b.updatedAt - a.updatedAt)[0]?.id;
}

/** The window's messages a page starting at `first` keeps: those from `first` on (events merged
 * while the page was read), and older ones only while they run without a gap up to the page. A
 * window that ends before the page starts (more than a page came in, a reconnect) would leave a
 * hole no older page fills, so the window then starts at the page (#25570). */
function joining(window: readonly HomeMessage[], first: number | undefined): HomeMessage[] {
  if (first === undefined) return [...window];
  const older = window.filter((m) => m.seq < first).sort((a, b) => b.seq - a.seq);
  const kept: HomeMessage[] = [];
  let next = first - 1;
  for (const message of older) {
    if (message.seq !== next) break;
    kept.push(message);
    next -= 1;
  }
  return [...kept.reverse(), ...window.filter((m) => m.seq >= first)];
}
