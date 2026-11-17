// FeedStore against the mock `cmux.feed` provider: it reads on open and on every change event (a
// newer read supersedes an older reply, nothing polls), sends answers and triage as intents, shows
// a refusal as a toast, and keeps a report's unsent reply id for the resend.
import { describe, expect, test } from "bun:test";
import { pageError, type PageClient } from "../shared/pageClient";
import { formatString } from "../shared/i18n";
import generated from "./generated/strings.json";
import { rejectText } from "./FeedPage";
import { feedRefusal, MockFeedProvider, sampleFeed, type MockItem } from "./mockProvider";
import { routeItem, withoutRouteItem } from "./model";
import { FeedStore, rejectOf } from "./store";
import { canChange } from "./context";
import { ACTION_RUN, FeedOps, type FeedIntentParams, type FeedView, type FeedViewParams, type ViewItem } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings = {
  t: (key: string) => en[key] ?? key,
  format: (key: string, ...args: string[]) => formatString(en[key] ?? key, args),
};
const NOW = Date.parse("2026-11-06T12:00:00Z");

function setup(options: ConstructorParameters<typeof MockFeedProvider>[1] = {}, hash = "#/inbox") {
  const provider = new MockFeedProvider(sampleFeed(NOW), { now: () => NOW, ...options });
  let key = 0;
  const store = new FeedStore(provider, hash, {
    clock: () => NOW,
    tzOffsetMin: () => 0,
    newKey: () => `k${++key}`,
    rejectText: (reject) => rejectText(reject, strings),
  });
  return { provider, store };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const intents = (provider: MockFeedProvider) =>
  provider.calls.filter((call) => call.op === FeedOps.intent).map((call) => call.params as FeedIntentParams);
const reads = (provider: MockFeedProvider) =>
  provider.calls.filter((call) => call.op === FeedOps.viewRead).map((call) => call.params as FeedViewParams);

describe("reads", () => {
  test("the Inbox reads its layout and filter on open, and again on every change event", async () => {
    const { provider, store } = setup();
    await store.start();
    expect(reads(provider)).toEqual([
      { layout: "inbox", filter: { connection: "feed", category: "all" }, tz_offset_min: 0 },
    ]);
    expect(store.getSnapshot()).toMatchObject({ loading: false, link: "connected" });
    expect(store.getSnapshot().view!.groups.map((group) => group.id)).toEqual(["needs_you", "today", "earlier"]);
    expect(store.getSnapshot().reports).toHaveLength(3);
    provider.post({ ...sampleFeed(NOW)[11]!, id: "fi_new", title: "New notice", created_at: NOW });
    await settle();
    expect(reads(provider)).toHaveLength(2);
    expect(store.getSnapshot().view!.groups[1]!.entries[0]!.item.id).toBe("fi_new");
    store.stop();
    expect(provider.subscriberCount).toBe(0);
  });

  test("the list and Needs you read their own layouts", async () => {
    const list = setup({}, "#/list?surface=sidebar");
    await list.store.start();
    expect(reads(list.provider)[0]).toEqual({ layout: "list", tz_offset_min: 0 });
    expect(list.store.getSnapshot().route.surface).toBe("sidebar");
    const needs = setup({}, "#/needs-you?limit=2");
    await needs.store.start();
    expect(reads(needs.provider)[0]).toEqual({ layout: "needs_you", limit: 2, tz_offset_min: 0 });
    expect(needs.provider.calls.some((call) => call.op === FeedOps.reportsRead)).toBe(false);
  });

  test("a newer read supersedes an older reply that arrives late", async () => {
    const answers: Array<(view: FeedView) => void> = [];
    const mock = new MockFeedProvider(sampleFeed(NOW), { now: () => NOW });
    const client: PageClient = {
      call: <R>(op: string, params: unknown) =>
        op === FeedOps.viewRead
          ? new Promise<R>((resolve) => answers.push((view) => resolve(view as R)))
          : mock.call<R>(op, params),
      subscribe: (stream, onEvent) => mock.subscribe(stream, onEvent),
      handle: () => () => undefined,
    };
    const store = new FeedStore(client, "#/list", { clock: () => NOW });
    const first = store.reload();
    const second = store.reload();
    const newer = mock.view({ layout: "list" });
    answers[1]!({ ...newer, revision: 9 });
    answers[0]!({ ...newer, revision: 1 });
    await Promise.all([first, second]);
    expect(store.getSnapshot().view!.revision).toBe(9);
  });

  test("with GitHub on, the Inbox opens on the GitHub tab before it draws any row", async () => {
    const { provider, store } = setup({ githubEnabled: true });
    const seen: string[] = [];
    store.subscribe(() => {
      const view = store.getSnapshot().view;
      if (view) seen.push(store.getSnapshot().filter.connection);
    });
    await settle();
    await settle();
    expect(reads(provider).map((read) => read.filter?.connection)).toEqual(["feed", "github"]);
    expect(new Set(seen)).toEqual(new Set(["github"]));
    const items = store.getSnapshot().view!.groups.flatMap((group) => group.entries.map((entry) => entry.item.id));
    expect(items).toEqual(["fi_github_review", "fi_github_assigned"]);
    // The person's own choice is never overridden again.
    store.setConnection("feed");
    await settle();
    expect(store.getSnapshot().filter.connection).toBe("feed");
  });

  test("the filter and the category go to the owner; the Reports tab reads no items", async () => {
    const { provider, store } = setup();
    await store.start();
    store.setQuery("build");
    store.setCategory("unread");
    await settle();
    expect(reads(provider).at(-1)).toMatchObject({
      filter: { connection: "feed", category: "unread", query: "build" },
    });
    const before = reads(provider).length;
    store.setConnection("reports");
    await settle();
    expect(reads(provider)).toHaveLength(before);
  });

  test("a lost host link shows; back up re-reads", async () => {
    const { provider, store } = setup();
    await store.start();
    await settle();
    provider.page.setConnected(false);
    expect(store.getSnapshot().link).toBe("disconnected");
    const before = reads(provider).length;
    provider.page.setConnected(true);
    await settle();
    expect(store.getSnapshot().link).toBe("connected");
    expect(reads(provider).length).toBe(before + 1);
  });

  test("opened while the daemon is away, the page subscribes again on reconnect and follows changes", async () => {
    const { provider, store } = setup();
    provider.offline = true;
    provider.page.setConnected(false);
    await store.start();
    expect(store.getSnapshot().link).toBe("disconnected");
    expect(provider.subscriberCount).toBe(0);
    provider.offline = false;
    provider.page.setConnected(true);
    await settle();
    await settle();
    expect(store.getSnapshot().link).toBe("connected");
    expect(provider.subscriberCount).toBe(2); // the view's and the Reports basket's changes
    const before = reads(provider).length;
    provider.post({ ...sampleFeed(NOW)[11]!, id: "fi_after", title: "After reconnect", created_at: NOW });
    await settle();
    expect(reads(provider)).toHaveLength(before + 1);
    expect(store.getSnapshot().view!.groups[1]!.entries[0]!.item.id).toBe("fi_after");
    store.stop();
    expect(provider.subscriberCount).toBe(0);
  });
});

describe("intents", () => {
  test("selecting reads the item; opening asks the app to open its context", async () => {
    const { provider, store } = setup();
    await store.start();
    store.select("fi_status_run");
    await settle();
    expect(intents(provider)).toEqual([{ kind: "read", items: ["fi_status_run"], idempotency_key: "k1" }]);
    store.select("fi_build_done"); // already read: nothing to send
    store.open("fi_codex_question");
    await settle();
    expect(provider.calls.find((call) => call.op === ACTION_RUN)?.params).toEqual({
      action: "feed.openItem",
      args: { item: "fi_codex_question" },
    });
    expect(intents(provider).map((intent) => intent.kind)).toEqual(["read", "read"]);
  });

  test("answers carry each kind's value, and a sent answer drops its draft", async () => {
    const { provider, store } = setup();
    await store.start();
    store.setScope("fi_claude_rm_build", "session");
    store.approve("fi_claude_rm_build", "allow", "session");
    store.setReply("fi_codex_question", "  release/0.80 ");
    store.sendReply("fi_codex_question");
    store.answer("fi_confirm_drop", { confirmed: false });
    store.review("fi_claude_plan", "request_changes");
    const choice = store.item("fi_claude_choice")!.prompt!.questions!;
    expect(store.submitChoice("fi_claude_choice")).toContainEqual({ kind: "unanswered", question: "q_auth" });
    store.toggleChoice("fi_claude_choice", choice[0]!, "device", false);
    store.setOther("fi_claude_choice", choice[1]!, " status ");
    expect(store.submitChoice("fi_claude_choice")).toEqual([]);
    await settle();
    expect(intents(provider).map(({ kind, item, answer }) => ({ kind, item, answer }))).toEqual([
      { kind: "answer", item: "fi_claude_rm_build", answer: { decision: "allow", scope: "session" } },
      { kind: "answer", item: "fi_codex_question", answer: { text: "release/0.80" } },
      { kind: "answer", item: "fi_confirm_drop", answer: { confirmed: false } },
      { kind: "answer", item: "fi_claude_plan", answer: { verdict: "request_changes" } },
      {
        kind: "answer",
        item: "fi_claude_choice",
        answer: { answers: { q_auth: { selected: ["device"] }, q_scope: { selected: [], other: "status" } } },
      },
    ]);
    expect(store.getSnapshot().drafts).toEqual({ choices: {}, replies: {}, scopes: {} });
    expect(store.item("fi_claude_rm_build")!.state).toBe("answered");
  });

  test("triage: decline, done, snooze, Mark All Read of what the Inbox shows, and the list's", async () => {
    const { provider, store } = setup();
    await store.start();
    store.decline("fi_signin_dashboard");
    store.archive("fi_claude_rm_build"); // open: only answer or decline
    store.archive("fi_build_done");
    store.snooze("fi_status_run", "hour");
    store.snooze("fi_codex_edit", "tomorrow"); // open: refused here
    await settle();
    store.markShownRead();
    await settle();
    const sent = intents(provider);
    expect(sent.slice(0, 3).map(({ kind, item, items, until }) => ({ kind, item, items, until }))).toEqual([
      { kind: "decline", item: "fi_signin_dashboard", items: undefined, until: undefined },
      { kind: "archive", item: undefined, items: ["fi_build_done"], until: undefined },
      { kind: "snooze", item: undefined, items: ["fi_status_run"], until: NOW + 3_600_000 },
    ]);
    expect(sent[3]!.kind).toBe("read");
    expect(sent[3]!.items!.length).toBeGreaterThan(5);
    const list = setup({}, "#/list");
    await list.store.start();
    list.store.markAllRead();
    await settle();
    expect(intents(list.provider)).toEqual([{ kind: "mark_all_read", before: NOW, idempotency_key: "k1" }]);
  });

  test("Mark All Read of a long Inbox is one intent of every shown item (one gesture)", async () => {
    const notices: MockItem[] = Array.from({ length: 300 }, (_, index) => ({
      id: `fi_notice_${index}`,
      home: "local",
      kind: "notice",
      title: `Build ${index} finished`,
      state: "open",
      count: 1,
      revision: 1,
      poster: { kind: "integration", label: "CI" },
      created_at: NOW - index * 1000,
    }));
    const provider = new MockFeedProvider(notices, { now: () => NOW });
    const store = new FeedStore(provider, "#/inbox", {
      clock: () => NOW,
      tzOffsetMin: () => 0,
      newKey: () => crypto.randomUUID(),
      rejectText: (reject) => rejectText(reject, strings),
    });
    await store.start();
    store.markShownRead();
    await settle();
    const sent = intents(provider).filter((intent) => intent.kind === "read");
    expect(sent.map((intent) => intent.items!.length)).toEqual([300]);
    expect(new Set(sent[0]!.items!)).toEqual(new Set(notices.map((notice) => notice.id)));
    expect(intents(provider)).toHaveLength(1);
  });

  test("an item waits dimmed while its intent is in flight", async () => {
    const mock = new MockFeedProvider(sampleFeed(NOW), { now: () => NOW });
    let release: () => void = () => undefined;
    const client: PageClient = {
      call: async <R>(op: string, params: unknown) => {
        if (op === FeedOps.intent) await new Promise<void>((resolve) => (release = resolve));
        return mock.call<R>(op, params);
      },
      subscribe: (stream, onEvent) => mock.subscribe(stream, onEvent),
      handle: () => () => undefined,
    };
    const store = new FeedStore(client, "#/list", { clock: () => NOW });
    await store.start();
    store.decline("fi_codex_handoff");
    expect(store.getSnapshot().inflight.has("fi_codex_handoff")).toBe(true);
    release();
    await settle();
    await settle();
    expect(store.getSnapshot().inflight.has("fi_codex_handoff")).toBe(false);
  });

  test("a refusal is a toast in the Feed's words", async () => {
    const shown = (store: FeedStore) => store.notices.snapshot().map((entry) => entry.spec.message);
    const moving = setup({ refuse: "feed.moving" });
    await moving.store.start();
    moving.store.decline("fi_codex_handoff");
    await settle();
    expect(shown(moving.store)).toEqual(["Moving to the cloud. Try again."]);
    const closed = setup({ refuse: "feed.closed" });
    await closed.store.start();
    closed.store.decline("fi_codex_handoff");
    await settle();
    expect(shown(closed.store)).toEqual(["The feed refused the change"]);
    // Answering a request that already closed says how it closed, without asking the owner.
    closed.store.answer("fi_answered_push", { decision: "allow" });
    expect(shown(closed.store)).toEqual(["Answered on iPhone"]);
    expect(intents(closed.provider).some((intent) => intent.item === "fi_answered_push")).toBe(false);
  });

  test("GitHub actions run in the app; a failure says why and the next try clears it", async () => {
    const { provider, store } = setup({ githubError: "gh is not signed in" });
    await store.start();
    expect(await store.githubAction("fi_github_review", "comment", "LGTM")).toBe(false);
    expect(store.getSnapshot().github).toEqual({ pending: false, error: "gh is not signed in" });
    expect(provider.calls.find((call) => call.op === ACTION_RUN)?.params).toEqual({
      action: "feed.githubAction",
      args: { item: "fi_github_review", action: "comment", comment: "LGTM" },
    });
    const ok = setup();
    await ok.store.start();
    expect(await ok.store.githubAction("fi_github_review", "checkout")).toBe(true);
    expect(ok.store.getSnapshot().github).toEqual({ pending: false });
    ok.store.refresh();
    ok.store.addConnection();
    await settle();
    expect(ok.provider.calls.some((call) => call.op === FeedOps.githubRefresh)).toBe(true);
    expect(ok.provider.calls.at(-1)!.params).toEqual({
      action: "openSettings",
      args: { section: "notifications", setting: "feed.github.enabled" },
    });
  });
});

describe("opening the Inbox on an item", () => {
  // Review of #37378: Needs you's request whose own tab is gone opens the Inbox; the app names the
  // item in the route (`item=<id>`) and the Inbox selects it, new or already open.
  test("a new Inbox opens on the item, on the Feed tab even with GitHub on", async () => {
    const { provider, store } = setup({ githubEnabled: true }, "#/inbox?surface=page&item=fi_codex_question");
    await store.start();
    await settle();
    expect(reads(provider).map((read) => read.filter?.connection)).toEqual(["feed"]);
    expect(store.getSnapshot().selection).toBe("fi_codex_question");
    expect(store.item("fi_codex_question")).toBeDefined();
  });

  test("an open Inbox selects the item, and leaves a filter that hides it", async () => {
    const { provider, store } = setup();
    await store.start();
    store.select("fi_status_run");
    store.applyRoute("#/inbox?surface=page&item=fi_claude_choice");
    expect(store.getSnapshot().selection).toBe("fi_claude_choice");
    // The same request again after the person moved on (the page drops `item` once it is used).
    store.select("fi_build_done");
    store.applyRoute("#/inbox?surface=page");
    store.applyRoute("#/inbox?surface=page&item=fi_claude_choice");
    expect(store.getSnapshot().selection).toBe("fi_claude_choice");
    store.setConnection("reports");
    store.setQuery("deploy");
    await settle();
    const before = reads(provider).length;
    store.applyRoute("#/inbox?surface=page&item=fi_codex_question");
    expect(store.getSnapshot().filter).toEqual({ connection: "feed", category: "all", query: "" });
    expect(store.getSnapshot().selection).toBe("fi_codex_question");
    await settle();
    expect(reads(provider)).toHaveLength(before + 1);
    expect(store.item("fi_codex_question")).toBeDefined();
  });

  test("an item request names the Inbox only, and is dropped from the fragment once used", () => {
    expect(routeItem("#/inbox?surface=page&item=fi_a")).toBe("fi_a");
    expect(routeItem("#/needs-you?item=fi_a")).toBeUndefined();
    expect(routeItem("#/inbox")).toBeUndefined();
    expect(withoutRouteItem("#/inbox?surface=page&item=fi_a")).toBe("#/inbox?surface=page");
    expect(withoutRouteItem("#/inbox?item=fi_a")).toBe("#/inbox");
  });
});

describe("reports basket", () => {
  test("a reply that was not sent keeps its draft, and sent again keeps its id", async () => {
    const { provider, store } = setup({ replyFails: true });
    await store.start();
    expect(store.getSnapshot().reportSelection).toBe("rep_1");
    store.setReportDraft("Go ahead");
    await store.sendReportReply();
    expect(store.getSnapshot()).toMatchObject({ reportDraft: "Go ahead", reportNotSent: "rep_1" });
    await store.sendReportReply();
    const replies = provider.calls.filter((call) => call.op === FeedOps.reportsReply).map((call) => call.params);
    expect(replies).toEqual([
      { to: "mini-3:codex-infra", text: "Go ahead", prompt_id: "k1", idempotency_key: "k1" },
      { to: "mini-3:codex-infra", text: "Go ahead", prompt_id: "k1", idempotency_key: "k1" },
    ]);
    const ok = setup();
    await ok.store.start();
    ok.store.selectReport("rep_2");
    ok.store.setReportDraft("Thanks");
    await ok.store.sendReportReply();
    expect(ok.store.getSnapshot()).toMatchObject({ reportDraft: "", reportNotSent: undefined });
  });

  test("a draft to a report that leaves the basket is dropped, never sent to the newly selected sender", async () => {
    const reports = Array.from({ length: 200 }, (_, index) => ({
      id: `rep_${index}`,
      sender: `host-${index}:agent`,
      body: `Report ${index}`,
      created_at: NOW - index * 1000,
    }));
    const { provider, store } = setup({ reports });
    await store.start();
    store.selectReport("rep_199");
    store.setReportDraft("Ship it");
    provider.report({ id: "rep_new", sender: "mbp:claude", body: "Done", created_at: NOW + 1000 });
    await settle();
    const snapshot = store.getSnapshot();
    expect(snapshot.reports.some((report) => report.id === "rep_199")).toBe(false);
    expect(snapshot.reportSelection).not.toBe("rep_199");
    expect(snapshot.reportDraft).toBe("");
    await store.sendReportReply();
    expect(provider.calls.some((call) => call.op === FeedOps.reportsReply)).toBe(false);
  });

  test("a new report re-reads the basket", async () => {
    const { provider, store } = setup();
    await store.start();
    provider.report({ id: "rep_new", sender: "mbp:claude", body: "Done", created_at: NOW });
    await settle();
    expect(store.getSnapshot().reports[0]!.id).toBe("rep_new");
  });

  test("a page that opened on the list and moves to the Inbox reads and follows the basket", async () => {
    const { provider, store } = setup({}, "#/list?surface=sidebar");
    await store.start();
    expect(store.getSnapshot().reports).toHaveLength(0);
    store.applyRoute("#/inbox");
    await settle();
    expect(store.getSnapshot().reports).toHaveLength(3);
    provider.report({ id: "rep_late", sender: "mbp:claude", body: "Later", created_at: NOW });
    await settle();
    expect(store.getSnapshot().reports[0]!.id).toBe("rep_late");
    store.stop();
    expect(provider.subscriberCount).toBe(0);
  });

  test("a mailbox read that fails leaves the basket empty, not the page down", async () => {
    const mock = new MockFeedProvider(sampleFeed(NOW), { now: () => NOW });
    const client: PageClient = {
      call: <R>(op: string, params: unknown) =>
        op === FeedOps.reportsRead
          ? Promise.reject(pageError("acpmux.unavailable", "no acpmux"))
          : mock.call<R>(op, params),
      subscribe: (stream, onEvent) => mock.subscribe(stream, onEvent),
      handle: () => () => undefined,
    };
    const store = new FeedStore(client, "#/inbox", { clock: () => NOW });
    await store.start();
    expect(store.getSnapshot()).toMatchObject({ reportsLoaded: true, reports: [], link: "connected" });
  });
});

describe("refusals", () => {
  test("a feed refusal is read from operation.failed's details.extra", () => {
    const item = { id: "fi_1", state: "answered" } as unknown as ViewItem;
    expect(rejectOf(feedRefusal("feed.closed", "closed", item))).toEqual({ kind: "closed", item });
    expect(rejectOf(feedRefusal("feed.moving", "moving"))).toEqual({ kind: "moving" });
    expect(rejectOf(feedRefusal("feed.disconnected", "offline"))).toEqual({ kind: "disconnected" });
    expect(rejectOf(feedRefusal("feed.rejected", "no"))).toEqual({ kind: "refused", message: "no" });
    expect(rejectOf(pageError("cmux.validation.invalid", "bad answer"))).toEqual({
      kind: "refused",
      message: "bad answer",
    });
    expect(rejectOf(pageError("cmux.operation.failed", "gone"))).toEqual({ kind: "refused", message: "gone" });
  });
});

describe("availability", () => {
  test("with the cloud owner down, a local item stays answerable and a cloud item does not", async () => {
    const { store } = setup({ connection: { state: "disconnected", reason: "offline" } });
    await store.start();
    const snap = store.getSnapshot();
    const items = snap.view!.groups.flatMap((group) => group.entries.map((entry) => entry.item));
    const local = items.find((item) => item.home.startsWith("local"))!;
    const cloud = items.find((item) => item.home === "cloud")!;
    expect(canChange(snap, local)).toBe(true);
    expect(canChange(snap, cloud)).toBe(false);
  });
});
