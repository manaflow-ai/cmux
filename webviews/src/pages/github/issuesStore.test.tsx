// The GitHub page's issues view: its routes read back, the list and one issue come from the host's
// issue ops, an answer for a view the page has left is dropped, a failure keeps what was drawn, a
// row opens its issue in place, and the issues view and its mock render the list and the detail.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { GitHubIssues } from "./GitHubIssues";
import { IssuesStore } from "./issuesStore";
import { mockIssue, mockIssueComments, mockIssueData, mockIssues, MOCK_ISSUE_URL, MOCK_REPO } from "./mockIssues";
import { MockGitHubProvider } from "./mockProvider";
import { GitHubOps, issueRoute, issuesRoute, routedIssue, routedIssues, routedPullRequest } from "./types";
import { settleReact } from "../../../test/support/domTeardown";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => (en[key] ?? key).replace("%@", args[0] ?? ""),
};

class Host implements PageClient {
  calls: { op: string; params: unknown }[] = [];
  replies: (unknown | Error | (() => Promise<unknown>))[] = [];
  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    const next = this.replies.shift();
    if (next instanceof Error) throw next;
    return (typeof next === "function" ? await (next as () => Promise<unknown>)() : next) as R;
  }
  async subscribe(): Promise<() => void> {
    return () => {};
  }
  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

test("routes: a repository's list and one issue read back; other routes name neither", () => {
  expect(issuesRoute("example/app")).toBe("#/issues?repo=example%2Fapp");
  expect(routedIssues(issuesRoute("example/app"))).toEqual({ repo: "example/app" });
  expect(routedIssue(issueRoute(MOCK_ISSUE_URL))).toEqual({ url: MOCK_ISSUE_URL, repo: MOCK_REPO, number: 517 });
  expect(routedIssues("#/issues?repo=../x")).toBeUndefined();
  expect(routedIssues("#/issues?repo=a/b/c")).toBeUndefined();
  expect(routedIssue(issueRoute("https://github.com/example/app/pull/1"))).toBeUndefined();
  expect(routedIssue(issueRoute("https://example.com/a/b/issues/1"))).toBeUndefined();
  expect(routedIssue("#/pull?url=x")).toBeUndefined();
  // The pull request route is untouched by the issue routes.
  expect(routedPullRequest(issueRoute(MOCK_ISSUE_URL))).toBeUndefined();
});

test("the list comes from issues.list with the repository; an issue from issue.details with its url", async () => {
  const host = new Host();
  host.replies.push({ issues: mockIssues }, { issue: mockIssue, comments: mockIssueComments });
  const navigated: string[] = [];
  const store = new IssuesStore(
    host,
    (hash) => navigated.push(hash),
    () => false,
  );
  await store.route(issuesRoute(MOCK_REPO));
  expect(host.calls[0]).toEqual({ op: GitHubOps.issues, params: { repo: MOCK_REPO } });
  expect(store.getSnapshot().issues?.map((issue) => issue.number)).toEqual(mockIssues.map((issue) => issue.number));
  expect(store.getSnapshot().loading).toBe(false);
  store.openIssue(mockIssue);
  expect(navigated).toEqual([issueRoute(MOCK_ISSUE_URL)]);
  await store.route(navigated[0]!);
  expect(host.calls[1]).toEqual({ op: GitHubOps.issue, params: { url: MOCK_ISSUE_URL } });
  expect(store.getSnapshot().issue?.title).toBe(mockIssue.title);
  expect(store.getSnapshot().comments).toHaveLength(3);
  store.openList();
  expect(navigated[1]).toBe(issuesRoute(MOCK_REPO));
  store.stop();
});

test("an answer for a view the page has left is dropped", async () => {
  const host = new Host();
  let release: (value: unknown) => void = () => {};
  host.replies.push(() => new Promise((resolve) => (release = resolve)), { issue: mockIssue, comments: [] });
  const store = new IssuesStore(
    host,
    () => {},
    () => false,
  );
  const first = store.route(issuesRoute(MOCK_REPO));
  await store.route(issueRoute(MOCK_ISSUE_URL));
  release({ issues: mockIssues });
  await first;
  expect(store.getSnapshot().view?.kind).toBe("issue");
  expect(store.getSnapshot().issues).toBeUndefined();
  store.stop();
});

test("a failed read keeps what the page drew and says why; a pull request route names no issue view", async () => {
  const host = new Host();
  host.replies.push({ issues: mockIssues }, pageError("cmux.github.issues_unavailable", "GitHub refused"));
  const store = new IssuesStore(
    host,
    () => {},
    () => false,
  );
  await store.route(issuesRoute(MOCK_REPO));
  await store.ask();
  expect(store.getSnapshot().issues).toHaveLength(mockIssues.length);
  expect(store.getSnapshot().failure).toBeTruthy();
  await store.route("#/pull?url=https://github.com/example/app/pull/1");
  expect(store.getSnapshot().view).toBeUndefined();
  expect(host.calls).toHaveLength(2);
  store.stop();
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function mountDom() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  root = createRoot(dom.window.document.getElementById("root")!);
  return dom.window.document;
}

test("the list draws each issue's title, number, labels, author and comment count; a row opens its issue", async () => {
  const document = mountDom();
  const held: { store?: IssuesStore } = {};
  held.store = new IssuesStore(
    new MockGitHubProvider(undefined, undefined, undefined, mockIssueData),
    (hash) => void held.store?.route(hash),
    () => false,
  );
  const store = held.store;
  await act(async () => {
    root!.render(<GitHubIssues store={store} strings={strings} now={() => Date.parse("2026-11-05T03:00:00Z")} />);
    await store.route(issuesRoute(MOCK_REPO));
  });
  const rows = [...document.querySelectorAll<HTMLElement>(".gh-issue-row")];
  expect(rows).toHaveLength(mockIssues.length);
  const first = rows[0]!;
  expect(first.querySelector(".gh-issue-title")?.textContent).toBe(mockIssue.title);
  expect(first.querySelector(".gh-issue-meta")?.textContent).toContain("#517");
  expect(first.querySelector(".gh-issue-meta")?.textContent).toContain("mona");
  expect([...first.querySelectorAll(".gh-label")].map((label) => label.textContent)).toEqual([
    "bug",
    "sidebar",
    "good first issue",
  ]);
  expect(first.querySelector(".gh-issue-comments")?.textContent).toBe("3");
  expect(rows[3]!.dataset.state).toBe("closed");
  await act(async () => {
    first.querySelector<HTMLButtonElement>(".gh-issue-title")!.click();
    // The click routes in place; the mock answers a few microtasks on.
    for (let turn = 0; turn < 8; turn += 1) await Promise.resolve();
  });
  expect(document.querySelector("h1")?.textContent).toBe(mockIssue.title);
  expect(document.querySelectorAll(".gh-entry")).toHaveLength(mockIssueComments.length);
  expect(document.querySelector(".gh-badge")?.textContent).toBe(en["github.state.open"]!);
  store.stop();
});

test("an empty repository and a failed read each say so", async () => {
  const document = mountDom();
  const store = new IssuesStore(
    new MockGitHubProvider(undefined, undefined, undefined, { ...mockIssueData, issues: [] }),
    () => {},
    () => false,
  );
  await act(async () => {
    root!.render(<GitHubIssues store={store} strings={strings} />);
    await store.route(issuesRoute(MOCK_REPO));
  });
  expect(document.querySelector(".gh-issues-note")?.textContent).toBe(en["github.issues.empty"]!);
  store.stop();
  const failing = new IssuesStore(
    new MockGitHubProvider(undefined, undefined, undefined, { ...mockIssueData, issue: "failed" }),
    () => {},
    () => false,
  );
  await act(async () => {
    root!.render(<GitHubIssues store={failing} strings={strings} />);
    await failing.route(issueRoute(MOCK_ISSUE_URL));
  });
  expect(document.querySelector("h1")?.textContent).toBe(en["github.issue.failed"]!);
  failing.stop();
});
