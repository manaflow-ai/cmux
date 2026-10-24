// l10n-allow-file: test fixture commands and titles, not shipped UI.
// A pull request bar the header isn't following knows only what the chat saw when the PR was
// opened, so it names no state rather than a stale "Open". A merged or closed pull request keeps
// no bar above the composer (it lives in the right panel's Changes card): the chat's own merge or
// close drops it, and so does the header's live state. A long repository name truncates with its
// full name a hover away.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://example.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

const tool = (id: string, command: string, output = "") => ({
  id,
  tool: { id, kind: "execute", title: command, status: "completed", exitCode: 0, command, output },
});

const bars = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-pr-dock__bar")].map((bar) => [
    bar.querySelector(".acpmux-pr-dock__number")?.textContent,
    bar.querySelector(".acpmux-pr-dock__state")?.textContent ?? null,
    bar.querySelector(".acpmux-pr-dock__repo")?.textContent,
  ]);

const container = () => dom.window.document.body.appendChild(dom.window.document.createElement("div"));

const live = (url: string, number: number, state: string) => ({
  url,
  number,
  title: "Add retry",
  state,
  review: "",
  mergeable: "",
  checks: { state: "none", passed: 0, total: 0 },
  checkList: [],
});

test("an open bar names no stale Open; the chat's merged and closed pull requests keep no bar", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  const rows = [
    {
      kind: "activity",
      id: "a1",
      version: 1,
      items: [
        tool("t1", 'gh pr create --title "Add retry"', "https://github.com/acme/uploader/pull/41"),
        tool(
          "t2",
          'gh pr create --title "Document retry"',
          "https://github.com/acme/a-very-long-repository-name/pull/42",
        ),
        tool("t3", 'gh pr create --title "Drop the old client"', "https://github.com/acme/uploader/pull/43"),
        tool("t4", "gh pr merge 41"),
        tool("t5", "gh pr close 43"),
      ],
    },
  ];
  const root = createRoot(container());
  await act(async () => root.render(<PullRequestDock rows={rows as never} sessionId="s1" />));
  expect(bars()).toEqual([["#42", null, "a-very-long-repository-name"]]);
  act(() => root.unmount());
});

test("a bar drops once the header reports its pull request merged; an open one stays", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const url = "https://github.com/manaflow-ai/cmux/pull/23621";
  const rows = [
    {
      kind: "activity",
      id: "a1",
      version: 1,
      items: [tool("t1", 'gh pr create --title "Add retry"', url)],
    },
  ];
  setHeaderState({ pullRequest: live(url, 23621, "open") });
  const root = createRoot(container());
  await act(async () => root.render(<PullRequestDock rows={rows as never} sessionId="s2" />));
  expect(bars()).toEqual([["#23621", "Open", "cmux"]]);
  await act(async () => setHeaderState({ pullRequest: live(url, 23621, "merged") }));
  expect(bars()).toEqual([]);
  expect(dom.window.document.querySelector(".acpmux-pr-dock")).toBeNull();
  act(() => root.unmount());
  setHeaderState({ pullRequest: null });
});
