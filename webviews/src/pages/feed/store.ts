// The Feed page's state owner on the page side. The feed is a projection of the daemon's feed
// client (`cmux.feed.view.read`): the page reads it on open and again on every
// `cmux.feed.view.changed`, a newer read supersedes an older reply, and nothing polls. Every
// change (an answer, triage, read) is an intent the owner settles; while it waits, the owner's
// `pending` dims the item. The page keeps only client view state: the route, the Inbox filter, the
// selection, unsent drafts and the reports basket's reply. React reads it through
// `useSyncExternalStore`; tests drive it directly.
import { createNoticeQueue, type NoticeQueue } from "../../ui/NoticeStack";
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import {
  Answers,
  clearDrafts,
  DEFAULT_FILTER,
  EMPTY_DRAFTS,
  allItems,
  isOpenRequest,
  isRequest,
  isUnread,
  normalizedChoice,
  parseRoute,
  reconcileReportSelection,
  reportReply,
  setOther,
  setReply,
  setScope,
  snoozeUntil,
  toggleChoice,
  type ChoiceIssue,
  type Drafts,
  type FeedRoute,
  type InboxConnection,
  type InboxFilter,
  type ReportReply,
  type SnoozeFor,
  choiceIssues,
} from "./model";
import {
  ACTION_RUN,
  FeedActions,
  FeedOps,
  FeedRejectCodes,
  type FeedApproveScope,
  type FeedCategory,
  type FeedChoiceQuestion,
  type FeedIntentParams,
  type FeedReport,
  type FeedReportsResult,
  type FeedView,
  type FeedViewParams,
  type GitHubAction,
  type ViewItem,
} from "./types";

export type PageLink = "connecting" | "connected" | "disconnected";

/** Why the owner refused an intent, for the toast (FeedReject). */
export type FeedReject =
  | { kind: "closed"; item?: ViewItem }
  | { kind: "moving" }
  | { kind: "disconnected" }
  | { kind: "refused"; message?: string };

export interface FeedSnapshot {
  route: FeedRoute;
  view?: FeedView;
  /** True until the first reply for the current read arrives. */
  loading: boolean;
  /** The page's link to its host (and through it to the daemon). */
  link: PageLink;
  filter: InboxFilter;
  selection?: string;
  drafts: Drafts;
  /** Items with an intent this page sent that the owner has not settled yet. */
  inflight: ReadonlySet<string>;
  /** When the page last heard from the owner or acted: relative times advance only then. */
  now: number;
  github: { pending: boolean; error?: string };
  reports: FeedReport[];
  reportsLoaded: boolean;
  reportSelection?: string;
  reportDraft: string;
  /** Reports whose reply is being sent (Reply waits, so a second press sends nothing). */
  reportSending: ReadonlySet<string>;
  /** The report whose last reply was not sent (its draft stays). */
  reportNotSent?: string;
}

export interface FeedStoreOptions {
  /** The host's document attributes (`data-feed-surface`, `data-feed-style`); the route query wins. */
  attributes?: { surface?: string; style?: string };
  /** The refusal toast's text (the page's strings; FeedStrings.reject). */
  rejectText?: (reject: FeedReject) => string;
  newKey?: () => string;
  clock?: () => number;
  /** The reader's offset from UTC in minutes (Today and Earlier are the reader's days). */
  tzOffsetMin?: () => number;
}

const NO_SET: ReadonlySet<string> = new Set();
/** The owner reads at most this many ids per intent (FeedWireEncode). */
const INTENT_IDS = 256;

export class FeedStore {
  private snapshot: FeedSnapshot;
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private reportsGeneration = 0;
  private lifetime = 0;
  private starting = false;
  private stops: Array<() => void> = [];
  /** The first Inbox read picks GitHub when it is connected, once (FeedInboxView.pickedConnection). */
  private pickedConnection = false;
  /** Each report's last reply that was not sent: sent again, it keeps its id. */
  private readonly unsent = new Map<string, ReportReply>();
  readonly notices: NoticeQueue = createNoticeQueue();

  constructor(
    private readonly client: PageClient | null,
    hash = "#/inbox",
    private readonly options: FeedStoreOptions = {},
  ) {
    this.snapshot = {
      route: parseRoute(hash, options.attributes),
      loading: client !== null,
      link: client ? "connecting" : "disconnected",
      filter: DEFAULT_FILTER,
      drafts: EMPTY_DRAFTS,
      inflight: NO_SET,
      now: this.clock(),
      github: { pending: false },
      reports: [],
      reportsLoaded: false,
      reportDraft: "",
      reportSending: NO_SET,
    };
  }

  getSnapshot = (): FeedSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Subscribes to the owner's changes and reads the first view. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.stops.length || this.starting) return;
    const lifetime = ++this.lifetime;
    const alive = () => lifetime === this.lifetime;
    this.starting = true;
    try {
      const watch = async (stream: string, onEvent: () => void) => {
        try {
          const stop = await this.client!.subscribe(stream, () => {
            if (alive()) onEvent();
          });
          if (alive()) this.stops.push(stop);
          else stop();
        } catch (error) {
          // An owner without the stream still answers reads; a lost link says so.
          if (alive() && !(isPageError(error) && error.code === "cmux.protocol.unknown_op")) this.fail(error);
        }
      };
      await watch(FeedOps.viewChanged, () => void this.reload());
      if (this.snapshot.route.view === "inbox") await watch(FeedOps.reportsChanged, () => void this.reloadReports());
      try {
        const stop = await subscribePageStreams(this.client, {
          onConnection: (connected) => {
            if (alive()) this.onLink(connected);
          },
        });
        if (alive()) this.stops.push(stop);
        else stop();
      } catch (error) {
        if (alive()) this.fail(error);
      }
      if (!alive()) return;
      const reads = [this.reload()];
      if (this.snapshot.route.view === "inbox") reads.push(this.reloadReports());
      await Promise.all(reads);
    } finally {
      if (alive()) this.starting = false;
    }
  }

  stop(): void {
    ++this.lifetime;
    ++this.generation;
    ++this.reportsGeneration;
    this.starting = false;
    for (const stop of this.stops.splice(0)) stop();
  }

  /** The host moves an open page to another route (`#/list`, `#/needs-you?style=bar`). */
  applyRoute(hash: string): void {
    const route = parseRoute(hash, this.options.attributes);
    const before = this.snapshot.route;
    if (JSON.stringify(route) === JSON.stringify(before)) return;
    this.set({ route });
    if (route.view !== before.view || route.limit !== before.limit) void this.reload();
  }

  /** The host's link: down shows the banner and refuses changes; back up re-reads. */
  private onLink(connected: boolean): void {
    if (!connected) this.set({ link: "disconnected", loading: false });
    else if (this.snapshot.link === "disconnected") {
      this.set({ link: "connecting" });
      void this.reload();
      if (this.snapshot.route.view === "inbox") void this.reloadReports();
    }
  }

  // MARK: - Reads

  private params(): FeedViewParams {
    const { route, filter } = this.snapshot;
    const tz_offset_min = this.options.tzOffsetMin?.() ?? -new Date(this.clock()).getTimezoneOffset();
    if (route.view === "list") return { layout: "list", tz_offset_min };
    if (route.view === "needs-you") return { layout: "needs_you", limit: route.limit, tz_offset_min };
    const connection = filter.connection === "github" ? "github" : "feed";
    return {
      layout: "inbox",
      filter: { connection, category: filter.category, ...(filter.query ? { query: filter.query } : {}) },
      tz_offset_min,
    };
  }

  /** Re-reads the view; an older reply that arrives late is dropped. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const view = await this.client.call<FeedView>(FeedOps.viewRead, this.params());
      if (generation !== this.generation) return;
      // The first Inbox read: GitHub is the first tab when it is connected. Read it before drawing,
      // so the Feed's rows never show and then swap.
      if (this.snapshot.route.view === "inbox" && !this.pickedConnection) {
        this.pickedConnection = true;
        if (view.github.enabled && this.snapshot.filter.connection === "feed") {
          this.set({ filter: { ...this.snapshot.filter, connection: "github" } });
          return this.reload();
        }
      }
      this.set({
        view,
        loading: false,
        link: "connected",
        now: this.clock(),
      });
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false });
      this.fail(error);
    }
  }

  async reloadReports(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.reportsGeneration;
    try {
      const { reports } = await this.client.call<FeedReportsResult>(FeedOps.reportsRead, {});
      if (generation !== this.reportsGeneration) return;
      this.set({
        reports,
        reportsLoaded: true,
        reportSelection: reconcileReportSelection(reports, this.snapshot.reportSelection),
      });
    } catch (error) {
      if (generation !== this.reportsGeneration) return;
      this.set({ reportsLoaded: true });
      if (isPageError(error) && error.code === LINK_CLOSED) this.fail(error);
    }
  }

  // MARK: - Inbox filter

  setConnection(connection: InboxConnection): void {
    if (connection === this.snapshot.filter.connection) return;
    this.pickedConnection = true;
    this.set({ filter: { ...this.snapshot.filter, connection } });
    // The reports basket filters no items: the item list keeps its last read under it.
    if (connection !== "reports") void this.reload();
  }

  setCategory(category: FeedCategory): void {
    if (category === this.snapshot.filter.category) return;
    this.set({ filter: { ...this.snapshot.filter, category } });
    void this.reload();
  }

  setQuery(query: string): void {
    if (query === this.snapshot.filter.query) return;
    this.set({ filter: { ...this.snapshot.filter, query } });
    void this.reload();
  }

  // MARK: - Selection and opening

  /** A person selected an item (click, arrow keys): select it and read it. */
  select(id: string | undefined): void {
    if (id !== this.snapshot.selection) this.set({ selection: id, now: this.clock() });
    if (id) this.markRead([id]);
  }

  /** A person opened an item (double click, Return, Open, Sign In): select, read, and hand its
   * context to the app. */
  open(id: string): void {
    this.select(id);
    this.run(FeedActions.openItem, { item: id });
  }

  /** Opens the Feed (Needs you's "N more", its bar with more than one request). */
  showFeed(): void {
    this.run("feed.show", {});
  }

  addConnection(): void {
    this.run(FeedActions.addConnection, {});
  }

  refresh(): void {
    if (this.client) void this.client.call(FeedOps.githubRefresh, {}).catch((error: unknown) => this.fail(error));
  }

  private run(action: string, args: Record<string, unknown>): void {
    if (this.client)
      void this.client.call(ACTION_RUN, { action, args }).catch((error: unknown) => {
        if (isPageError(error) && error.code === LINK_CLOSED) this.fail(error);
      });
  }

  // MARK: - Intents

  item(id: string): ViewItem | undefined {
    return this.snapshot.view ? allItems(this.snapshot.view.groups).find((item) => item.id === id) : undefined;
  }

  /** Answers an open request; a closed one says how it closed instead. */
  answer(id: string, value: unknown): void {
    const item = this.item(id);
    if (!item || !isRequest(item)) return;
    if (item.state !== "open") return this.reject({ kind: "closed", item });
    this.set({ drafts: clearDrafts(this.snapshot.drafts, id) });
    void this.intent({ kind: "answer", item: id, answer: value }, [id]);
  }

  decline(id: string): void {
    const item = this.item(id);
    if (!item || !isRequest(item)) return;
    if (item.state !== "open") return this.reject({ kind: "closed", item });
    void this.intent({ kind: "decline", item: id }, [id]);
  }

  /** Allow at the drafted scope (the first offered by default), or Deny. */
  approve(id: string, decision: "allow" | "deny", scope?: FeedApproveScope): void {
    this.answer(id, Answers.approve(decision, scope));
  }

  markRead(ids: readonly string[]): void {
    const unread = ids.filter((id) => {
      const item = this.item(id);
      return item !== undefined && isUnread(item);
    });
    if (unread.length) void this.intent({ kind: "read", items: unread.slice(0, INTENT_IDS) }, []);
  }

  /** The Inbox's Mark All Read: the items it shows. */
  markShownRead(): void {
    const view = this.snapshot.view;
    if (view) this.markRead(allItems(view.groups).map((item) => item.id));
  }

  /** The list's Mark All Read: every unread item at the owner's commit. */
  markAllRead(): void {
    if (!this.snapshot.view?.counts.unread) return;
    void this.intent({ kind: "mark_all_read", before: this.clock() }, []);
  }

  /** Done. An open request can only be answered or declined (feed.md 3.6). */
  archive(id: string): void {
    const item = this.item(id);
    if (item && !isOpenRequest(item) && item.archived_at == null)
      void this.intent({ kind: "archive", items: [id] }, [id]);
  }

  snooze(id: string, length: SnoozeFor): void {
    const item = this.item(id);
    if (item && !isOpenRequest(item))
      void this.intent({ kind: "snooze", items: [id], until: snoozeUntil(this.clock(), length) }, [id]);
  }

  private async intent(params: Omit<FeedIntentParams, "idempotency_key">, items: readonly string[]): Promise<void> {
    if (!this.client) return;
    const lifetime = this.lifetime;
    if (items.length) this.set({ inflight: new Set([...this.snapshot.inflight, ...items]), now: this.clock() });
    try {
      await this.client.call(FeedOps.intent, { ...params, idempotency_key: this.key() });
    } catch (error) {
      if (lifetime !== this.lifetime) return;
      this.reject(rejectOf(error));
      if (isPageError(error) && error.code === LINK_CLOSED) this.fail(error);
    } finally {
      if (lifetime === this.lifetime && items.length) {
        const inflight = new Set(this.snapshot.inflight);
        for (const id of items) inflight.delete(id);
        this.set({ inflight });
      }
    }
  }

  private reject(reject: FeedReject): void {
    const message = this.options.rejectText?.(reject);
    if (message) this.notices.show({ id: "feed.reject", kind: "toast", message });
  }

  // MARK: - Drafts

  toggleChoice(id: string, question: FeedChoiceQuestion, option: string, oneTap: boolean): void {
    this.set({ drafts: toggleChoice(this.snapshot.drafts, id, question, option) });
    if (oneTap) this.submitChoice(id);
  }

  setOther(id: string, question: FeedChoiceQuestion, text: string): void {
    this.set({ drafts: setOther(this.snapshot.drafts, id, question, text) });
  }

  setReply(id: string, text: string): void {
    this.set({ drafts: setReply(this.snapshot.drafts, id, text) });
  }

  setScope(id: string, scope: FeedApproveScope): void {
    this.set({ drafts: setScope(this.snapshot.drafts, id, scope) });
  }

  /** Sends the drafted choice answer, or returns why it cannot be sent. */
  submitChoice(id: string): ChoiceIssue[] {
    const questions = this.item(id)?.prompt?.questions;
    if (!questions) return [];
    const drafted = this.snapshot.drafts.choices[id] ?? {};
    const normalized = normalizedChoice(drafted, questions);
    if (!normalized) return choiceIssues(drafted, questions);
    this.answer(id, Answers.choice(normalized));
    return [];
  }

  /** Sends the drafted reply of a question. */
  sendReply(id: string): void {
    const text = (this.snapshot.drafts.replies[id] ?? "").trim();
    if (text) this.answer(id, Answers.text(text));
  }

  review(id: string, verdict: "approve" | "request_changes"): void {
    const comment = (this.snapshot.drafts.replies[id] ?? "").trim();
    this.answer(id, Answers.review(verdict, comment || undefined));
  }

  // MARK: - GitHub

  /** A GitHub item's action, run by the app (it types into a terminal or opens the browser). */
  async githubAction(id: string, action: GitHubAction, comment?: string): Promise<boolean> {
    if (!this.client || this.snapshot.github.pending) return false;
    const lifetime = this.lifetime;
    this.set({ github: { pending: true } });
    try {
      await this.client.call(ACTION_RUN, {
        action: FeedActions.githubAction,
        args: { item: id, action, ...(comment ? { comment } : {}) },
      });
      if (lifetime === this.lifetime) this.set({ github: { pending: false } });
      return true;
    } catch (error) {
      if (lifetime === this.lifetime) this.set({ github: { pending: false, error: message(error) } });
      return false;
    }
  }

  // MARK: - Reports basket

  selectReport(id: string): void {
    this.set({ reportSelection: id, reportDraft: "", reportNotSent: undefined });
  }

  setReportDraft(text: string): void {
    this.set({ reportDraft: text });
  }

  /** Sends the draft to the selected report's sender. A refused reply keeps the draft, and the same
   * reply sent again keeps its id. */
  async sendReportReply(): Promise<void> {
    const { reports, reportSelection, reportDraft, reportSending } = this.snapshot;
    const report = reports.find((r) => r.id === reportSelection);
    const text = reportDraft.trim();
    if (!this.client || !report || !text || reportSending.has(report.id)) return;
    const reply = reportReply(report.sender, text, this.unsent.get(report.id), () => this.key());
    this.set({ reportSending: new Set([...reportSending, report.id]), reportNotSent: undefined });
    let sent = false;
    try {
      const result = await this.client.call<{ sent: boolean }>(FeedOps.reportsReply, {
        session: reply.session,
        text: reply.text,
        prompt_id: reply.promptId,
      });
      sent = result?.sent === true;
    } catch {
      sent = false;
    }
    const sending = new Set(this.snapshot.reportSending);
    sending.delete(report.id);
    if (!sent) {
      this.unsent.set(report.id, reply);
      this.set({ reportSending: sending, reportNotSent: report.id });
      return;
    }
    this.unsent.delete(report.id);
    // A sent reply clears the draft unless the person typed on or chose another report.
    const keep = this.snapshot.reportSelection !== report.id || this.snapshot.reportDraft.trim() !== text;
    this.set({ reportSending: sending, ...(keep ? {} : { reportDraft: "" }) });
  }

  // MARK: - Plumbing

  private fail(error: unknown): void {
    if (isPageError(error) && error.code === LINK_CLOSED) this.set({ link: "disconnected", loading: false });
  }

  private clock(): number {
    return this.options.clock?.() ?? Date.now();
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<FeedSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** A refusal frame as the page's reject (FeedWireEncode.reject). */
export function rejectOf(error: unknown): FeedReject {
  if (!isPageError(error)) return { kind: "refused", message: message(error) };
  switch (error.code) {
    case FeedRejectCodes.closed: {
      const details = error.details as { item?: ViewItem } | undefined;
      return { kind: "closed", item: details?.item };
    }
    case FeedRejectCodes.moving:
      return { kind: "moving" };
    case FeedRejectCodes.disconnected:
    case LINK_CLOSED:
      return { kind: "disconnected" };
    default:
      return { kind: "refused", message: error.message };
  }
}
