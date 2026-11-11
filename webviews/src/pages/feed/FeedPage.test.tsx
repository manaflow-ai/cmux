// The Feed page in a DOM with the mock provider: every route draws what the Swift views drew (row
// anatomy, request cards, the Inbox's groups, detail and toolbar, Needs you in each style, the
// reports basket, empty and disconnected states), keys move and open, and a long list keeps only
// the rows near the viewport.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/feed/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { FeedPage, rejectText } = await import("./FeedPage");
const { UiProvider } = await import("../../ui/UiProvider");
const { setLastingGrace } = await import("../../ui/lasting");
const { createStrings } = await import("../shared/i18n");
const table = (await import("./generated/strings.json")).default as Record<string, Record<string, string>>;
const { MockFeedProvider, manyNotices, sampleFeed } = await import("./mockProvider");
const { FeedStore } = await import("./store");
const { ACTION_RUN, FeedOps } = await import("./types");

const NOW = Date.now();

async function mount(
  hash: string,
  options: ConstructorParameters<typeof MockFeedProvider>[1] = {},
  items = sampleFeed(NOW),
) {
  const provider = new MockFeedProvider(items, options);
  const strings = createStrings(table, ["en"]);
  const store = new FeedStore(provider, hash, { rejectText: (reject) => rejectText(reject, strings) });
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host}>
        <FeedPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => {
    await store.start();
  });
  return { provider, store };
}

const all = (selector: string) => [...host.querySelectorAll<HTMLElement>(selector)];
const text = (selector: string) => all(selector).map((node) => node.textContent);
const button = (label: string) =>
  [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (item) => item.textContent === label || item.getAttribute("aria-label") === label,
  )!;
const press = async (target: HTMLElement, key: string) =>
  act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true }));
  });
const click = async (target: HTMLElement) => act(async () => target.click());

test("the list: title, badge, Mark All Read, request cards with answers, then rows", async () => {
  const { provider } = await mount("#/list");
  expect(host.querySelector(".feed-list-title")!.textContent).toBe("Feed");
  expect(host.querySelector(".feed-badge")!.textContent).toBe("13");
  const cards = all(".feed-card");
  expect(cards).toHaveLength(11);
  expect(cards[0]!.textContent).toContain("Run rm -rf build && npm run build?");
  expect(cards[0]!.querySelector(".feed-code-text")!.textContent).toBe("rm -rf build && npm run build");
  expect([...cards[0]!.querySelectorAll("button")].map((b) => b.textContent)).toEqual(["Once", "Deny", "Allow"]);
  // Row anatomy: unread dot, glyph, headline, time, detail, meta.
  const status = all(".feed-row").find((row) => row.textContent?.includes("cargo test finished"))!;
  expect(status.hasAttribute("data-unread")).toBe(true);
  expect(status.querySelector(".feed-dot")!.hasAttribute("data-visible")).toBe(true);
  expect(status.querySelector(".feed-icon")!.getAttribute("data-icon")).toBe("terminal");
  expect(status.querySelector(".feed-row-detail")!.textContent).toBe("412 passed, 0 failed");
  expect(status.querySelector(".feed-row-meta")!.textContent).toBe("status run · cmux-tui");
  const local = all(".feed-row").find((row) => row.textContent?.includes("Render complete"))!;
  expect(local.querySelector(".feed-local")!.getAttribute("title")).toBe("This Mac only");
  const answered = all(".feed-row").find((row) => row.textContent?.includes("git push origin"))!;
  expect(answered.querySelector(".feed-row-meta")!.textContent).toContain("Answered on iPhone");
  await click(button("Allow"));
  const intent = provider.calls.find((call) => call.op === FeedOps.intent)!.params as Record<string, unknown>;
  expect(intent).toMatchObject({
    kind: "answer",
    item: "fi_claude_rm_build",
    answer: { decision: "allow", scope: "once" },
  });
  expect(all(".feed-card")).toHaveLength(10);
  await click(button("Mark All Read"));
  expect(provider.calls.at(-2)!.params).toMatchObject({ kind: "mark_all_read" });
});

test("the list's Mark All Read is on with only an unread request", async () => {
  const request = sampleFeed(NOW).find((item) => item.id === "fi_claude_rm_build")!;
  const { provider } = await mount("#/list", {}, [{ ...request, read_at: undefined }]);
  const mark = button("Mark All Read");
  expect(mark.hasAttribute("disabled")).toBe(false);
  await click(mark);
  expect(provider.calls.at(-2)!.params).toMatchObject({ kind: "mark_all_read" });
});

test("the list's keys: Down selects and reads, Return opens; double click opens", async () => {
  const { provider } = await mount("#/list");
  const list = host.querySelector<HTMLElement>(".feed-lines")!;
  await press(list, "ArrowDown");
  const selected = host.querySelector(".feed-row.selected")!;
  expect(selected.textContent).toContain("cargo test finished");
  expect(provider.calls.find((call) => call.op === FeedOps.intent)!.params).toMatchObject({
    kind: "read",
    items: ["fi_status_run"],
  });
  await press(list, "Enter");
  expect(provider.calls.find((call) => call.op === ACTION_RUN)!.params).toEqual({
    action: "feed.openItem",
    args: { item: "fi_status_run" },
  });
  const row = all(".feed-row").find((r) => r.textContent?.includes("Build 1842 passed"))!;
  await act(async () => {
    row.dispatchEvent(new dom.window.MouseEvent("dblclick", { bubbles: true }));
  });
  expect(provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)!.params).toEqual({
    action: "feed.openItem",
    args: { item: "fi_build_done" },
  });
});

test("an empty feed says Nothing new", async () => {
  await mount("#/list", {}, []);
  expect(host.querySelector(".feed-empty")!.textContent).toBe("Nothing new");
  expect(host.querySelector(".feed-badge")!.hasAttribute("data-hidden")).toBe(true);
});

test("a feed whose cloud snapshot never came is loading, not empty", async () => {
  const offline = { loaded: false, connection: { state: "disconnected" as const, reason: "offline" } };
  await mount("#/list", offline, []);
  expect(host.querySelector(".feed-empty")).toBeNull();
  act(() => root?.unmount());
  root = undefined;
  await mount("#/inbox", offline, []);
  // Only the detail's "Select an inbox item"; the list is the loading placeholder.
  expect(text(".feed-inbox-column .feed-empty")).toEqual([]);
  expect(host.querySelector(".feed-inbox-list")).not.toBeNull();
  act(() => root?.unmount());
  root = undefined;
  // Signed out, there is no cloud part to wait for: empty is empty.
  await mount("#/list", { loaded: false, connection: { state: "disconnected", reason: "signed_out" } }, []);
  expect(host.querySelector(".feed-empty")!.textContent).toBe("Nothing new");
});

test("the Inbox: tabs, triage, groups with counts, the detail and its toolbar", async () => {
  const { provider } = await mount("#/inbox");
  expect(text('[role="tab"]')).toEqual(["GitHub", "Feed", "Reports basket"]);
  expect(text(".feed-group-title")).toEqual(["Needs you", "Today", "Earlier"]);
  expect(host.querySelector(".feed-inbox-detail")!.textContent).toBe("Select an inbox item");
  const thread = all(".feed-row").find((row) => row.textContent?.includes("Build 1842 passed"))!;
  expect(thread.querySelector(".feed-row-meta")!.textContent).toContain("2 items");
  await click(thread);
  expect(host.querySelector(".feed-detail-title")!.textContent).toBe("Build 1842 passed");
  expect(text(".feed-detail-toolbar button")).toEqual(["Snooze", "Done"]);
  // The thread's other member under the detail.
  expect(text(".feed-thread .feed-row-headline")).toEqual(["Build 1842 started"]);
  await click(button("Done"));
  expect(provider.calls.filter((call) => call.op === FeedOps.intent).at(-1)!.params).toMatchObject({
    kind: "archive",
    items: ["fi_build_done"],
  });
  const request = all(".feed-row").find((row) => row.textContent?.includes("Name for the release branch?"))!;
  await click(request);
  expect(text(".feed-detail-toolbar button")).toEqual(["Decline"]);
  expect(text(".feed-detail .feed-chip")).toEqual(["release/0.80", "rc/0.80.0"]);
  await click(button("release/0.80"));
  await click(
    [...host.querySelectorAll<HTMLButtonElement>(".feed-detail button")].find((b) => b.textContent === "Send")!,
  );
  expect(provider.calls.filter((call) => call.op === FeedOps.intent).at(-1)!.params).toMatchObject({
    kind: "answer",
    item: "fi_codex_question",
    answer: { text: "release/0.80" },
  });
});

test("the Inbox filter: no match says so; GitHub items show their card and actions", async () => {
  const { provider } = await mount("#/inbox");
  const field = host.querySelector<HTMLInputElement>(".feed-filter")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, "zzz-nothing");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  expect(host.querySelector(".feed-empty")!.textContent).toBe("No matching items");
  await press(field, "Escape");
  expect(field.value).toBe("");
  await act(async () => {
    host.querySelector<HTMLElement>('[role="tab"]')!.click();
  });
  const rows = all(".feed-row");
  expect(rows.map((row) => row.querySelector(".feed-row-headline")!.textContent)).toEqual([
    "Review requested: manaflow-ai/cmux#16201",
    "Assigned: manaflow-ai/cmux#16244",
  ]);
  await click(rows[0]!);
  expect(host.querySelector(".feed-github-title")!.textContent).toBe("Feed: mirror and intent log");
  expect(text(".feed-github-checks li")).toContain("swift test: failure");
  expect(text(".feed-github-actions .ui-btn")).toEqual([
    "Open on GitHub",
    "Check out",
    "Start agent",
    "Approve",
    "Comment",
  ]);
  await click(button("Check out"));
  expect(provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)!.params).toEqual({
    action: "feed.githubAction",
    args: { item: "fi_github_review", action: "checkout" },
  });
});

test("the Reports tab: the basket and a reply", async () => {
  const { provider } = await mount("#/inbox", { replyFails: true });
  await click([...host.querySelectorAll<HTMLElement>('[role="tab"]')][2]!);
  expect(host.querySelector(".feed-reports-title")!.textContent).toBe("Reports basket");
  expect(all(".feed-report-row")).toHaveLength(3);
  expect(host.querySelector(".feed-report-detail-title")!.textContent).toBe("mini-3:codex-infra");
  expect(host.querySelector(".feed-filter")).toBeNull();
  await click(all(".feed-report-row")[2]!);
  expect(host.querySelector(".feed-report-detail-text")!.textContent).toBe("(empty report)");
  const area = host.querySelector<HTMLTextAreaElement>(".feed-report-field")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(area, "On it");
    area.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await click(button("Reply"));
  expect(provider.calls.filter((call) => call.op === FeedOps.reportsReply)).toHaveLength(1);
  expect(host.querySelector(".feed-report-not-sent")!.textContent).toBe("Not sent. Try again.");
});

test("Needs you: rows with one-click answers, cards, and the one-line bar", async () => {
  await mount("#/needs-you");
  expect(host.querySelector(".feed-needs-title")!.textContent).toBe("Needs you");
  expect(host.querySelector(".feed-needs-count")!.textContent).toBe("11");
  expect(host.querySelector(".feed-needs-more")!.textContent).toBe("8 more");
  expect(all(".feed-needs-row")).toHaveLength(3);
  // A question or a choice needs typing or picking: its row opens instead of answering in place.
  const choice = all(".feed-needs-row").find((row) => row.dataset.item === "fi_claude_choice")!;
  expect(choice.querySelector(".feed-needs-answers")).toBeNull();
  // The count past the limit is text, not a control: the Inbox it opened is gone.
  expect(host.querySelector(".feed-needs-more")!.tagName).toBe("SPAN");
  act(() => root?.unmount());

  await mount("#/needs-you?style=cards");
  expect(all(".feed-needs .feed-card")).toHaveLength(3);
  act(() => root?.unmount());

  await mount("#/needs-you?style=bar");
  expect(host.querySelector(".feed-needs-headline")!.textContent).toBe("Needs you 11");
  expect(host.querySelector(".feed-needs-header")).toBeNull();
  act(() => root?.unmount());

  await mount("#/needs-you", {}, []);
  expect(host.querySelector(".feed-needs")).toBeNull();
});

test("a disconnected owner shows the banner and turns the answers off", async () => {
  setLastingGrace(0);
  await mount("#/list", { connection: { state: "disconnected", reason: "" } });
  expect(host.querySelector(".feed-banner")!.textContent).toBe("Feed is unreachable");
  expect(button("Allow").hasAttribute("disabled") || button("Allow").hasAttribute("data-disabled")).toBe(true);
  setLastingGrace(25_000);
});

test("past 200 rows the list draws only the rows near the viewport", async () => {
  await mount("#/inbox", {}, manyNotices(NOW, 600));
  const rows = all(".feed-row");
  expect(rows.length).toBeLessThan(100);
  expect(host.querySelector('[role="grid"]')).not.toBeNull();
});
