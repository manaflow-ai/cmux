// l10n-allow-file: sample feed content (poster text is content, not chrome), for the dev loop and gallery.
// An in-memory `cmux.feed` provider for the browser dev loop (`/feed/?mock`), the gallery and tests.
// It is not the backend: the daemon's feed client (cmux-feed-core::client) owns ordering, grouping,
// the row text and the intent lifecycle. The mock keeps only enough of it to drive the page, and its
// seed is the Swift Feed's (MockFeedSeed): every request kind, notices, closed requests, GitHub items
// with details, and reports.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { LINK_CLOSED, MockPageStreams } from "../shared/pageStreams";
import {
  ACTION_RUN,
  FeedOps,
  OPERATION_FAILED,
  type FeedEntry,
  type FeedGroup,
  type FeedIntentParams,
  type FeedReport,
  type FeedRow,
  type FeedView,
  type FeedViewParams,
  type GitHubAction,
  type GitHubDetail,
  type ViewItem,
} from "./types";

/** A feed refusal as the daemon sends it through the relay: the catalog's `operation.failed`
 * with the feed code (and `feed.closed`'s item) in `details.extra`. */
export function feedRefusal(code: string, reason: string, item?: ViewItem): Error {
  const extra: Record<string, unknown> = { code };
  if (item) extra.details = { item };
  return pageError(OPERATION_FAILED, reason, false, { operation: "feed.intent", reason, extra });
}

/** An item as the owner stores it: the view adds `row` and `pending`. */
export type MockItem = Omit<ViewItem, "row" | "pending">;

export interface MockCall {
  op: string;
  params: unknown;
}

const DAY = 86_400_000;
const PRIORITY = { low: 0, normal: 1, high: 2, urgent: 3 } as const;

const fold = (text: string) => text.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase("en");
const firstLine = (text = "") =>
  text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean) ?? "";
const plain = (text: string) => {
  let out = text.replaceAll("**", "").replaceAll("__", "").replaceAll("`", "");
  if (out.startsWith("#")) out = out.replace(/^#+/, "").trim();
  return out;
};
const host = (origin = "") => origin.replace("https://", "");

const isRequest = (item: MockItem) => item.kind !== "notice";
const isOpen = (item: MockItem) => isRequest(item) && item.state === "open";
const priorityOf = (item: MockItem) =>
  PRIORITY[item.priority ?? (item.kind === "notice" || item.kind === "review" ? "normal" : "high")];
export const isGitHubItem = (item: MockItem) =>
  item.dedupe_key?.startsWith("github:") === true || item.poster.label === "GitHub";

/** The kind's one line of detail (FeedRowContent.detail). */
function detailOf(item: MockItem): { text: string; code: boolean } {
  const p = item.prompt ?? {};
  switch (item.kind) {
    case "approve": {
      const command = firstLine(p.action?.command);
      if (command) return { text: command, code: true };
      const summary = firstLine(p.action?.summary);
      return { text: summary || plain(firstLine(item.body)), code: false };
    }
    case "question":
      return { text: plain(firstLine(p.question)), code: false };
    case "choice":
      return { text: plain(firstLine(p.questions?.[0]?.question)), code: false };
    case "confirm":
      return { text: plain(firstLine(p.statement)), code: false };
    case "sign-in":
      return { text: host(p.origin), code: false };
    case "passkey":
      return { text: host(p.rp_id ?? p.origin), code: false };
    case "file":
      return { text: plain(firstLine(p.purpose)), code: false };
    case "handoff":
      return { text: plain(firstLine(p.resume_hint ?? p.reason)), code: false };
    default:
      return { text: plain(firstLine(item.body)), code: false };
  }
}

/** The registry icon of an item (FeedRowContent.icon). */
export function iconOf(item: MockItem): string {
  switch (item.kind) {
    case "notice":
      switch (item.poster.kind) {
        case "integration":
          return "integration";
        case "server":
        case "vm":
          return "machine.remote";
        case "automation":
          return "automation";
        case "system":
          return item.context?.terminal ? "terminal" : "notification";
        default:
          return "notification";
      }
    case "approve":
      switch (item.prompt?.action?.type) {
        case "command":
          return "terminal";
        case "edit":
          return "action.edit";
        case "network":
          return "network";
        case "install":
          return "package";
        default:
          return "tools";
      }
    case "question":
      return "agent.question";
    case "choice":
      return "feed.choice";
    case "confirm":
      return "action.confirm";
    case "sign-in":
      return "account.signin";
    case "passkey":
      return "account.passkey";
    case "review":
      return "action.review";
    case "input":
      return "feed.input";
    case "file":
      return "file.new";
    case "handoff":
      return "agent.handoff";
    default:
      return "feed.custom";
  }
}

/** What the owner's row says (FeedRowContent, with the place from the item's context). */
export function rowOf(item: MockItem): FeedRow {
  const detail = detailOf(item);
  const title = item.title.trim();
  const generic = !title || title === item.poster.label || title === item.poster.harness;
  const headline = generic && detail.text ? detail.text : title;
  const shown = generic || !detail.text || fold(title).includes(fold(detail.text)) ? "" : detail.text;
  const label = item.poster.label.trim();
  const isAgentPlaceholder = label.toLowerCase() === "agent";
  const who =
    item.poster.harness?.trim() ||
    ((item.poster.kind === "agent" || item.poster.kind === "harness") && isAgentPlaceholder ? "" : label);
  const place = [item.context?.workspace, item.context?.tab].filter(Boolean).join(" › ");
  const where = place || (label && label !== who && item.poster.harness?.trim() && !isAgentPlaceholder ? label : "");
  return {
    headline,
    ...(shown ? { detail: shown } : {}),
    detail_is_code: !generic && detail.code,
    ...(who ? { who } : {}),
    ...(where ? { where } : {}),
    icon: iconOf(item),
    urgent: isOpen(item) && priorityOf(item) >= PRIORITY.high,
    dimmed: item.state === "expired" || item.state === "cancelled",
    local: item.home.startsWith("local:"),
  };
}

export interface MockFeedOptions {
  now?: () => number;
  githubEnabled?: boolean;
  reports?: FeedReport[];
  /** Items the owner has not settled yet (drawn dimmed). */
  pending?: string[];
  /** The owner's cloud link (the banner says it). */
  connection?: FeedView["connection"];
  /** The cloud owner's snapshot has come (default true); false: a first connection that failed. */
  loaded?: boolean;
  /** Every intent is refused with this code (`feed.moving`, `feed.closed`...). */
  refuse?: string;
  /** The reports reply is not sent. */
  replyFails?: boolean;
  /** A GitHub action fails with this message. */
  githubError?: string;
}

export class MockFeedProvider implements PageClient {
  items: MockItem[];
  reports: FeedReport[];
  readonly calls: MockCall[] = [];
  readonly page = new MockPageStreams();
  /** Set to make every call reject as if the host went away. */
  offline = false;
  private revision = 1;
  private nextSub = 1;
  private readonly subs = new Map<number, { stream: string; listener: (data: unknown, seq: number) => void }>();
  private readonly handlers = new Map<string, PageHandler>();
  private readonly pending: Set<string>;
  private readonly now: () => number;

  constructor(
    items: MockItem[] = sampleFeed(Date.now()),
    private readonly options: MockFeedOptions = {},
  ) {
    this.items = items;
    this.now = options.now ?? Date.now;
    this.reports = options.reports ?? sampleReports(this.now());
    this.pending = new Set(options.pending ?? []);
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    switch (op) {
      case FeedOps.viewRead:
        return this.view(params as FeedViewParams) as R;
      case FeedOps.intent:
        return this.intent(params as FeedIntentParams) as R;
      case FeedOps.reportsRead:
        return { reports: this.reports.slice(0, 200) } as R;
      case FeedOps.reportsReply:
        return { sent: !this.options.replyFails } as R;
      case FeedOps.githubRefresh:
        return {} as R;
      case ACTION_RUN: {
        const { action, args } = params as { action: string; args?: { item?: string; action?: GitHubAction } };
        if (action === "feed.githubAction" && this.options.githubError)
          throw pageError("feed.github.failed", this.options.githubError);
        if (action === "feed.openItem" && args?.item) this.read([args.item]);
        return { ok: true } as R;
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    if (stream !== FeedOps.viewChanged && stream !== FeedOps.reportsChanged)
      throw pageError("cmux.protocol.unknown_op", stream);
    const sub = this.nextSub++;
    this.subs.set(sub, { stream, listener: onEvent as (data: unknown, seq: number) => void });
    return () => void this.subs.delete(sub);
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => this.handlers.delete(op);
  }

  get subscriberCount(): number {
    return this.subs.size;
  }

  /** Posts an item as an owner commit would, and notifies. */
  post(item: MockItem): void {
    this.items = [item, ...this.items.filter((other) => other.id !== item.id)];
    this.emit(FeedOps.viewChanged);
  }

  /** A report arrives in the mailbox. */
  report(report: FeedReport): void {
    this.reports = [report, ...this.reports];
    this.emit(FeedOps.reportsChanged);
  }

  // MARK: - The view

  private active(): MockItem[] {
    const now = this.now();
    return this.items.filter((item) => item.archived_at == null && !(item.snoozed_until && item.snoozed_until > now));
  }

  private toView(item: MockItem): ViewItem {
    const view: ViewItem = { ...item, row: rowOf(item), pending: this.pending.has(item.id) };
    return view;
  }

  private matches(item: MockItem, params: FeedViewParams): boolean {
    const filter = params.filter;
    if (!filter) return true;
    if (filter.connection === "github" && !isGitHubItem(item)) return false;
    switch (filter.category) {
      case "unread":
        if (item.read_at != null) return false;
        break;
      case "needs_you":
        if (!isOpen(item)) return false;
        break;
      case "notices":
        if (isRequest(item)) return false;
        break;
    }
    const haystack = fold([item.title, item.body, item.poster.harness, item.poster.label, item.context?.url].join(" "));
    return (filter.query ?? "")
      .split(/\s+/)
      .filter(Boolean)
      .every((term) => haystack.includes(fold(term)));
  }

  view(params: FeedViewParams): FeedView {
    const active = this.active();
    const newest = (a: MockItem, b: MockItem) => b.created_at - a.created_at || (a.id < b.id ? -1 : 1);
    const shown = active.filter((item) => this.matches(item, params));
    const requests = shown.filter(isOpen).sort((a, b) => priorityOf(b) - priorityOf(a) || newest(a, b));
    const rest = shown.filter((item) => !isOpen(item)).sort(newest);
    const single = (item: MockItem): FeedEntry => ({
      id: item.id,
      item: this.toView(item),
      members: [],
      unread: item.read_at == null,
    });
    let groups: FeedGroup[];
    if (params.layout === "list") {
      groups = [
        { id: "requests", entries: requests.map(single) },
        { id: "rest", entries: rest.map(single) },
      ];
    } else if (params.layout === "needs_you") {
      groups = [{ id: "needs_you", entries: requests.slice(0, params.limit ?? requests.length).map(single) }];
    } else {
      const offset = (params.tz_offset_min ?? 0) * 60_000;
      const day = (at: number) => Math.floor((at + offset) / DAY);
      const today = day(this.now());
      groups = [
        { id: "needs_you", entries: requests.map(single) },
        { id: "today", entries: this.threads(rest.filter((item) => day(item.created_at) === today)) },
        { id: "earlier", entries: this.threads(rest.filter((item) => day(item.created_at) !== today)) },
      ];
    }
    const open = active.filter(isOpen).length;
    const unreadNotices = active.filter((item) => !isRequest(item) && item.read_at == null).length;
    return {
      revision: this.revision,
      loaded: this.options.loaded ?? true,
      connection: this.options.connection ?? { state: "connected" },
      counts: {
        open_requests: open,
        unread_notices: unreadNotices,
        badge: open + unreadNotices,
        unread: active.filter((item) => item.read_at == null).length,
      },
      github: { enabled: this.options.githubEnabled ?? false },
      reports: { available: true },
      groups,
      total: params.layout === "needs_you" ? open : shown.length,
    };
  }

  /** Collapses one thread's items under the newest (FeedInboxGroups.threads). */
  private threads(items: MockItem[]): FeedEntry[] {
    const entries: FeedEntry[] = [];
    const index = new Map<string, number>();
    for (const item of items) {
      const at = item.thread ? index.get(item.thread) : undefined;
      if (at !== undefined) {
        const entry = entries[at]!;
        entry.members.push(this.toView(item));
        entry.unread ||= item.read_at == null;
        continue;
      }
      if (item.thread) index.set(item.thread, entries.length);
      entries.push({
        id: item.thread ? `thread:${item.thread}:${item.id}` : item.id,
        item: this.toView(item),
        members: [],
        unread: item.read_at == null,
      });
    }
    return entries;
  }

  // MARK: - Intents

  private intent(params: FeedIntentParams): { settled: true } {
    if (this.options.refuse) {
      const item = this.items.find((other) => other.id === params.item);
      throw feedRefusal(this.options.refuse, "refused", item ? this.toView(item) : undefined);
    }
    const now = this.now();
    const change = (ids: readonly string[], patch: (item: MockItem) => MockItem) => {
      const set = new Set(ids);
      this.items = this.items.map((item) => (set.has(item.id) ? patch(item) : item));
    };
    switch (params.kind) {
      case "answer": {
        const item = this.items.find((other) => other.id === params.item);
        if (!item || item.state !== "open")
          throw feedRefusal("feed.closed", "closed", item ? this.toView(item) : undefined);
        change([item.id], (other) => ({
          ...other,
          state: "answered",
          answer: { value: params.answer, by: "usr_mock", device: "Mac", at: now },
          read_at: other.read_at ?? now,
          closed_at: now,
        }));
        break;
      }
      case "decline":
        change([params.item ?? ""], (item) => ({
          ...item,
          state: "cancelled",
          cancel: { reason: "declined", by: "usr_mock", at: now },
          read_at: item.read_at ?? now,
          closed_at: now,
        }));
        break;
      case "read":
        this.read(params.items ?? []);
        return { settled: true };
      case "archive":
        change(params.items ?? [], (item) => ({ ...item, archived_at: now }));
        break;
      case "snooze":
        change(params.items ?? [], (item) => ({ ...item, snoozed_until: params.until ?? now }));
        break;
      case "mark_all_read":
        change(
          this.items
            .filter((item) => item.read_at == null && item.created_at <= (params.before ?? now))
            .map((i) => i.id),
          (item) => ({ ...item, read_at: now }),
        );
        break;
    }
    for (const id of [params.item, ...(params.items ?? [])]) if (id) this.pending.delete(id);
    this.emit(FeedOps.viewChanged);
    return { settled: true };
  }

  private read(ids: readonly string[]): void {
    const set = new Set(ids);
    let changed = false;
    const now = this.now();
    this.items = this.items.map((item) => {
      if (!set.has(item.id) || item.read_at != null) return item;
      changed = true;
      return { ...item, read_at: now };
    });
    if (changed) this.emit(FeedOps.viewChanged);
  }

  private emit(stream: string): void {
    this.revision += 1;
    let seq = 0;
    for (const { stream: own, listener } of this.subs.values())
      if (own === stream) listener({ revision: this.revision }, ++seq);
  }
}

// MARK: - The seed (MockFeedSeed)

export const SAMPLE_DIFF = `--- a/Sources/Feed/FeedModel.swift
+++ b/Sources/Feed/FeedModel.swift
@@ -41,9 +41,12 @@ public final class FeedModel {
     public var visibleItems: [FeedItem] {
         var items = confirmed
-        for intent in pending {
-            items = intent.applied(to: items)
+        for intent in pending where !intent.isSettled {
+            intent.apply(to: &items, user: user, device: device)
         }
-        return Array(items.values)
+        return items.values.sorted(by: FeedOrder.newest)
     }
+
+    /// An intent on this item still waits for the owner.
+    public func isPending(_ id: String) -> Bool { pending.contains { $0.items?.contains(id) ?? true } }`;

const claude = (label: string) => ({ kind: "agent", label, harness: "Claude Code" });
const codex = (label: string) => ({ kind: "agent", label, harness: "Codex" });

const PR_DETAIL: GitHubDetail = {
  title: "Feed: mirror and intent log",
  repo: "manaflow-ai/cmux",
  number: 16201,
  url: "https://github.com/manaflow-ai/cmux/pull/16201",
  body: "Keeps the owner's items in one ordered ledger and applies pending intents over it.",
  branch: "feat-feed-ledger",
  checks: [
    { name: "cmux-next checks", conclusion: "success" },
    { name: "webviews", conclusion: "success" },
    { name: "swift test", conclusion: "failure" },
  ],
};

export function sampleFeed(now: number): MockItem[] {
  const ago = (seconds: number) => now - seconds * 1000;
  const base = { home: "cloud", state: "open" as const, count: 1, revision: 1 };
  return [
    // Requests: every kind.
    {
      ...base,
      id: "fi_claude_rm_build",
      kind: "approve",
      title: "Run rm -rf build && npm run build?",
      prompt: {
        action: {
          type: "command",
          summary: "Clean and rebuild",
          command: "rm -rf build && npm run build",
          cwd: "~/src/api-server",
          tool: "Bash",
          risk: "deletes build/",
        },
        scopes: ["once", "session", "always"],
      },
      thread: "claude:api-server",
      context: { workspace: "api-server", terminal: "term_7k2" },
      poster: claude("api-server"),
      created_at: ago(40),
    },
    {
      ...base,
      id: "fi_codex_edit",
      kind: "approve",
      title: "Edit Sources/Feed/FeedModel.swift",
      prompt: {
        action: { type: "edit", summary: "Apply patch to 1 file", tool: "apply_patch", diff: "att_diff" },
        scopes: ["once", "session"],
      },
      thread: "codex:cmux-next",
      context: { workspace: "cmux-next", terminal: "term_q81" },
      attachments: [
        { id: "att_diff", name: "FeedModel.swift.diff", mime: "text/x-diff", size: 612, text: SAMPLE_DIFF },
      ],
      poster: codex("cmux-next"),
      created_at: ago(190),
    },
    {
      ...base,
      id: "fi_claude_choice",
      kind: "choice",
      title: "Two questions about the login flow",
      prompt: {
        questions: [
          {
            id: "q_auth",
            question: "Which sign-in method should the CLI use?",
            header: "Sign-in",
            options: [
              { id: "device", label: "Device code", description: "Works over SSH" },
              { id: "browser", label: "Browser redirect", description: "Fewer steps on a desktop" },
              { id: "token", label: "Paste a token" },
            ],
          },
          {
            id: "q_scope",
            question: "Which commands need sign-in?",
            header: "Scope",
            options: [
              { id: "push", label: "push" },
              { id: "deploy", label: "deploy" },
              { id: "logs", label: "logs" },
            ],
            multi: true,
            allow_other: true,
          },
        ],
      },
      thread: "claude:api-server",
      context: { workspace: "api-server", terminal: "term_7k2" },
      poster: claude("api-server"),
      created_at: ago(360),
    },
    {
      ...base,
      id: "fi_codex_question",
      kind: "question",
      title: "Name for the release branch?",
      prompt: { question: "What should the release branch be called?", suggestions: ["release/0.80", "rc/0.80.0"] },
      context: { workspace: "docs-site" },
      poster: codex("docs-site"),
      created_at: ago(540),
    },
    {
      ...base,
      id: "fi_passkey_github",
      kind: "passkey",
      title: "Passkey for github.com",
      prompt: {
        origin: "https://github.com",
        rp_id: "github.com",
        ceremony: "get",
        browser_tab: "btab_gh",
        reason: "Confirm access to repository settings",
      },
      context: { workspace: "infra", browser_tab: "btab_gh", url: "https://github.com/settings" },
      poster: claude("infra"),
      created_at: ago(720),
    },
    {
      ...base,
      id: "fi_signin_dashboard",
      kind: "sign-in",
      title: "Sign in to dashboard.stripe.com",
      prompt: {
        origin: "https://dashboard.stripe.com",
        url: "https://dashboard.stripe.com/login",
        browser_tab: "btab_billing",
        reason: "Read the failed payouts report",
      },
      context: { workspace: "billing", browser_tab: "btab_billing" },
      poster: codex("billing"),
      created_at: ago(900),
    },
    {
      ...base,
      id: "fi_confirm_drop",
      kind: "confirm",
      title: "Drop the staging database?",
      prompt: {
        statement: "This deletes every table in staging-2.",
        confirm_label: "Drop",
        cancel_label: "Keep",
        destructive: true,
      },
      context: { workspace: "infra" },
      poster: codex("infra"),
      created_at: ago(1_100),
    },
    {
      ...base,
      id: "fi_claude_plan",
      kind: "review",
      priority: "normal",
      title: "Review the plan: split FeedModel",
      body: "1. Move grouping into a pure type.\n2. Keep the intent log in the model.\n3. Add tests for late answers.",
      prompt: { subject: "plan", ref: "plan_7", checklist: ["Grouping is pure", "Intent log unchanged"] },
      thread: "claude:cmux-next",
      context: { workspace: "cmux-next", terminal: "term_m4a" },
      poster: claude("cmux-next"),
      created_at: ago(1_500),
    },
    {
      ...base,
      id: "fi_codex_handoff",
      kind: "handoff",
      title: "Please take over: migration 0042 fails",
      body: "The migration fails on the staging copy with a lock timeout. I stopped before retrying.",
      prompt: { reason: "Lock timeout on staging", resume_hint: "Run it again after the backfill finishes" },
      context: { host: "mini-3", workspace: "infra", terminal: "term_z90" },
      poster: codex("infra"),
      created_at: ago(2_400),
    },
    {
      ...base,
      id: "fi_file_logo",
      kind: "file",
      title: "Pick the logo for the landing page",
      prompt: { purpose: "An SVG or PNG, at least 512 px wide" },
      context: { workspace: "site" },
      poster: claude("site"),
      created_at: ago(2_700),
    },
    {
      ...base,
      id: "fi_input_deploy",
      kind: "input",
      title: "Deploy settings for preview",
      body: "Region and instance count for the preview stack.",
      context: { workspace: "infra" },
      poster: codex("infra"),
      created_at: ago(2_900),
    },
    // Notices.
    {
      ...base,
      id: "fi_status_run",
      kind: "notice",
      title: "cargo test finished in 42 s",
      body: "412 passed, 0 failed",
      context: { workspace: "cmux-tui", terminal: "term_c11" },
      poster: { kind: "system", label: "status run" },
      created_at: ago(95),
    },
    {
      ...base,
      id: "fi_build_done",
      kind: "notice",
      title: "Build 1842 passed",
      body: "feat-cmux-next · 6 min 12 s",
      thread: "ci:cmux",
      poster: { kind: "server", label: "ci-runner" },
      read_at: ago(400),
      created_at: ago(480),
    },
    {
      ...base,
      id: "fi_build_retry",
      kind: "notice",
      title: "Build 1842 started",
      body: "feat-cmux-next",
      thread: "ci:cmux",
      count: 2,
      poster: { kind: "server", label: "ci-runner" },
      read_at: ago(800),
      created_at: ago(860),
    },
    {
      ...base,
      id: "fi_github_review",
      kind: "notice",
      title: "Review requested: manaflow-ai/cmux#16201",
      body: "Feed: mirror and intent log",
      dedupe_key: "github:review:manaflow-ai/cmux#16201",
      context: { url: "https://github.com/manaflow-ai/cmux/pull/16201" },
      poster: { kind: "integration", label: "GitHub" },
      created_at: ago(1_900),
      github: PR_DETAIL,
      github_actions: ["open", "checkout", "start_agent", "approve", "comment"],
    },
    {
      ...base,
      id: "fi_github_assigned",
      kind: "notice",
      title: "Assigned: manaflow-ai/cmux#16244",
      body: "Inbox: snooze until tomorrow",
      dedupe_key: "github:assigned:manaflow-ai/cmux#16244",
      context: { url: "https://github.com/manaflow-ai/cmux/issues/16244" },
      poster: { kind: "integration", label: "GitHub" },
      read_at: ago(4_000),
      created_at: ago(5_200),
      github: {
        title: "Inbox: snooze until tomorrow",
        repo: "manaflow-ai/cmux",
        number: 16244,
        url: "https://github.com/manaflow-ai/cmux/issues/16244",
        checks: [],
      },
      github_actions: ["open", "start_agent", "comment"],
    },
    {
      ...base,
      id: "fi_osc9",
      home: "local:inst_mbp",
      kind: "notice",
      title: "Render complete",
      body: "out/demo.mp4 (1080p, 38 s)",
      dedupe_key: "osc:term_f3:9a1",
      context: { workspace: "video", terminal: "term_f3" },
      poster: { kind: "system", label: "ffmpeg" },
      read_at: ago(3_000),
      created_at: ago(3_400),
    },
    {
      ...base,
      id: "fi_build_prev",
      kind: "notice",
      title: "Build 1841 failed",
      body: "check-l10n: 3 missing keys",
      thread: "ci:cmux",
      poster: { kind: "server", label: "ci-runner" },
      read_at: ago(80_000),
      created_at: ago(90_000),
    },
    {
      ...base,
      id: "fi_build_old",
      kind: "notice",
      title: "Build 1840 passed",
      thread: "ci:cmux",
      poster: { kind: "server", label: "ci-runner" },
      read_at: ago(95_000),
      created_at: ago(96_000),
    },
    // Closed requests.
    {
      ...base,
      id: "fi_answered_push",
      kind: "approve",
      title: "Run git push origin feat-login?",
      prompt: { action: { type: "command", summary: "Push the branch", command: "git push origin feat-login" } },
      poster: claude("api-server"),
      state: "answered",
      answer: { value: { decision: "allow", scope: "once" }, by: "usr_lawrence", device: "iPhone", at: ago(86_000) },
      read_at: ago(86_000),
      created_at: ago(86_400),
      closed_at: ago(86_000),
    },
    {
      ...base,
      id: "fi_expired_npm",
      kind: "approve",
      title: "Allow network access to registry.npmjs.org?",
      prompt: { action: { type: "network", summary: "Fetch packages" } },
      poster: codex("docs-site"),
      state: "expired",
      created_at: ago(172_800),
      closed_at: ago(86_400),
    },
    {
      ...base,
      id: "fi_declined_install",
      kind: "approve",
      title: "Install ripgrep with Homebrew?",
      prompt: { action: { type: "install", summary: "brew install ripgrep" } },
      poster: claude("dotfiles"),
      state: "cancelled",
      cancel: { reason: "declined", by: "usr_lawrence", at: ago(200_000) },
      read_at: ago(200_000),
      created_at: ago(200_400),
      closed_at: ago(200_000),
    },
  ];
}

/** Many notices for the long-list states (virtualized past 200 rows). */
export function manyNotices(now: number, count: number): MockItem[] {
  return Array.from({ length: count }, (_, index) => ({
    id: `fi_bulk_${index}`,
    home: "cloud",
    kind: "notice",
    title: `Build ${2000 - index} ${index % 7 === 0 ? "failed" : "passed"}`,
    body: index % 3 === 0 ? "" : `feat-cmux-next · step ${index + 1}`,
    poster: { kind: "server", label: `ci-runner-${index % 4}` },
    state: "open",
    count: 1,
    revision: 1,
    read_at: index % 5 === 0 ? null : now - index * 60_000,
    created_at: now - (index + 1) * 600_000,
  }));
}

export function sampleReports(now: number): FeedReport[] {
  return [
    {
      id: "rep_1",
      sender: "mini-3:codex-infra",
      body: "Migration 0042 is through on staging after the backfill. Production waits for your go.",
      created_at: now - 600_000,
    },
    {
      id: "rep_2",
      sender: "mbp:claude-api-server",
      body: "Login redirect fixed on feat-login; 42 tests pass. I left the flaky retry test skipped with a note.",
      created_at: now - 3_600_000,
    },
    { id: "rep_3", sender: "mbp:claude-docs", body: "", created_at: now - 7_200_000 },
  ];
}
