// l10n-allow-file: test fixture commands and titles, not shipped UI.
// A pull request bar the header isn't following knows only what the chat saw when the PR was
// opened, so it names no state rather than a stale "Open"; merged stays named. A long repository
// name truncates with its full name a hover away.
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

test("a bar the header isn't following names no stale Open; merged stays named", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  const rows = [
    {
      kind: "activity",
      id: "a1",
      version: 1,
      items: [
        tool("t1", 'gh pr create --title "Add retry"', "https://github.com/acme/a-very-long-repository-name/pull/41"),
        tool("t2", 'gh pr create --title "Document retry"', "https://github.com/acme/uploader/pull/42"),
        tool("t3", "gh pr merge 41"),
      ],
    },
  ];
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<PullRequestDock rows={rows as never} sessionId="s1" />));
  const bars = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-pr-dock__bar")].map((bar) => [
    bar.querySelector(".acpmux-pr-dock__number")?.textContent,
    bar.querySelector(".acpmux-pr-dock__state")?.textContent ?? null,
    bar.querySelector(".acpmux-pr-dock__repo")?.textContent,
  ]);
  expect(bars).toEqual([
    ["#42", null, "uploader"],
    ["#41", "Merged", "a-very-long-repository-name"],
  ]);
  act(() => root.unmount());
});
