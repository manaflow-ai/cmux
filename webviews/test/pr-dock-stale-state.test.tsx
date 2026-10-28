// l10n-allow-file: test fixture commands and titles, not shipped UI.
// A pull request bar the header isn't following knows only what the chat saw when the PR was
// opened, so it names no state rather than a stale "Open". A merged or closed pull request keeps
// no bar above the composer (it lives in the right panel's Changes card): the chat's own merge or
// close drops it, and so does the header's live state. A long repository name truncates with its
// full name a hover away.
import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://example.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
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

test("the default dock is a compact count that opens Session Info changes", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  delete dom.window.document.documentElement.dataset.prDock;
  const rows = [
    {
      kind: "activity",
      id: "a3",
      version: 1,
      items: [
        tool("t6", 'gh pr create --title "Add retry"', "https://github.com/acme/uploader/pull/51"),
        tool("t7", 'gh pr create --title "Document retry"', "https://github.com/acme/uploader/pull/52"),
      ],
    },
  ];
  let opened = 0;
  const root = createRoot(container());
  await act(async () =>
    root.render(<PullRequestDock rows={rows as never} sessionId="s3" onOpenChanges={() => (opened += 1)} />),
  );
  expect(dom.window.document.querySelector(".acpmux-pr-dock")?.getAttribute("data-mode")).toBe("compact");
  expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toContain("2 PRs");
  await act(async () => (dom.window.document.querySelector(".acpmux-pr-dock__count") as HTMLButtonElement).click());
  expect(opened).toBe(1);
  const disclosure = dom.window.document.querySelector<HTMLButtonElement>(".acpmux-pr-dock__disclosure");
  expect(disclosure).not.toBeNull();
  await act(async () => disclosure!.click());
  expect(bars().map((bar) => bar[0])).toEqual(["#52", "#51"]);
  await act(async () => dom.window.document.querySelector<HTMLButtonElement>(".acpmux-pr-dock__dismiss")!.click());
  expect(bars().map((bar) => bar[0])).toEqual(["#51"]);
  // Dismissal hides a shortcut, not a session change.
  expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toBe("2 PRs");
  await act(async () =>
    root.render(
      <PullRequestDock
        rows={[{ ...rows[0], version: 2, items: [...rows[0].items, tool("t8", "gh pr merge 51")] }] as never}
        sessionId="s3"
        onOpenChanges={() => undefined}
      />,
    ),
  );
  expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toBe("2 PRs");
  act(() => root.unmount());
  const oneRoot = createRoot(container());
  await act(async () =>
    oneRoot.render(
      <PullRequestDock
        rows={[{ ...rows[0], items: [rows[0].items[0]] } as never]}
        sessionId="s4"
        onOpenChanges={() => undefined}
      />,
    ),
  );
  expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toBe("1 PR");
  expect(
    (dom.window.document.querySelector(".acpmux-pr-dock__count") as HTMLButtonElement).getAttribute("aria-label"),
  ).toBe("1 PR");
  act(() => oneRoot.unmount());
  delete dom.window.document.documentElement.dataset.prDock;
});

test("the compact count follows Changes for touched PRs and verified mentions arriving in replies", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const rows = [{ kind: "activity", id: "touch", version: 1, items: [tool("read", "gh pr view 61 -R acme/uploader")] }];
  const root = createRoot(container());
  const render = (text: string) =>
    root.render(
      <PullRequestDock
        rows={[...rows, { kind: "assistant", id: "reply", text }] as never}
        repository="acme/uploader"
        sessionId="mentions"
        onOpenChanges={() => undefined}
      />,
    );
  setHeaderState({ pullRequest: live("https://github.com/acme/uploader/pull/62", 62, "open") });
  await act(async () => render("Working on the follow-up"));
  const count = () => dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent;
  expect(count()).toBe("1 PR");
  await act(async () => render("See #62 for details"));
  expect(count()).toBe("2 PRs");
  await act(async () => render("See #62 for details. Still working."));
  expect(count()).toBe("2 PRs");
  await act(async () => setHeaderState({ pullRequest: null }));
  expect(count()).toBe("1 PR");
  act(() => root.unmount());
});

test.each(["reply", "thought"])(
  "200 %s tokens without new PR findings do not recompute the dock's PR list",
  async (streamKind) => {
    const { createRoot } = await import("react-dom/client");
    const { OrderedRows, appendThought } = await import("../src/agent-session/acpmux/direct");
    const parser = await import("../src/agent-session/acpmux/summary/transcriptPullRequests");
    const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
    const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
    const rows = new OrderedRows();
    rows.set("created", {
      id: "created",
      kind: "activity",
      version: 1,
      at: 1,
      items: [tool("create", 'gh pr create --title "Retry"', "https://github.com/acme/uploader/pull/71") as never],
    });
    for (let index = 0; index < 2000; index++) {
      const id = `history-${index}`;
      rows.set(id, { id, kind: "assistant", version: 1, at: index + 2, text: "Earlier reply" });
    }
    let reply = { id: "stream", kind: "assistant", version: 1, at: 3000, text: "Working", streaming: true };
    rows.set(reply.id, reply);
    let thought = { id: "thought", kind: "activity", version: 1, at: 3001, items: appendThought([], "Thinking") };
    rows.set(thought.id, thought);
    const parse = spyOn(parser, "transcriptPullRequests");
    const root = createRoot(container());
    const render = (repository = "acme/uploader") =>
      root.render(
        <PullRequestDock
          rows={rows.sorted()}
          repository={repository}
          sessionId="stream-cache"
          onOpenChanges={() => undefined}
        />,
      );
    try {
      setHeaderState({ pullRequest: live("https://github.com/acme/uploader/pull/72", 72, "open") });
      await act(async () => render());
      expect(parse).toHaveBeenCalledTimes(1);
      for (let token = 0; token < 200; token++) {
        if (streamKind === "reply") {
          reply = { ...reply, version: reply.version + 1, text: `${reply.text} word` };
          rows.set(reply.id, reply);
        } else {
          thought = { ...thought, version: thought.version + 1, items: appendThought(thought.items, " word") };
          rows.set(thought.id, thought);
        }
        await act(async () => render());
      }
      expect(parse).toHaveBeenCalledTimes(1);
      expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toBe("1 PR");
      // A new verified mention must invalidate; caching cannot make the count stale.
      reply = { ...reply, version: reply.version + 1, text: `${reply.text} See #72` };
      rows.set(reply.id, reply);
      await act(async () => render());
      expect(parse).toHaveBeenCalledTimes(2);
      expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toBe("2 PRs");
      await act(async () => render("acme/other"));
      expect(parse).toHaveBeenCalledTimes(3);
      expect(dom.window.document.querySelector(".acpmux-pr-dock__count")?.textContent).toBe("1 PR");
    } finally {
      act(() => root.unmount());
      setHeaderState({ pullRequest: null });
      parse.mockRestore();
    }
  },
);
