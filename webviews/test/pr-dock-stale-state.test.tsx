// l10n-allow-file: test fixture commands and titles, not shipped UI.
// A pull request bar the header isn't following knows only what the chat saw when the PR was
// opened, so it names no state rather than a stale "Open". A merged or closed pull request keeps
// no bar above the composer (it lives in the right panel's Changes card): the chat's own merge or
// close drops it, and so does the header's live state. A long repository name truncates with its
// full name a hover away.
import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  PullRequestDock,
  RowPullRequests,
  useTranscriptPullRequests,
} from "../src/agent-session/acpmux/summary/PullRequestDock";

function TestDock({
  rows,
  repository,
}: {
  rows: readonly AcpmuxRow[];
  repository?: string;
  sessionId?: string;
  onOpenChanges?: () => void;
}) {
  const prs = useTranscriptPullRequests(rows, repository);
  return (
    <RowPullRequests.Provider value={prs}>
      <output data-pr-count>
        {prs.length} {prs.length === 1 ? "PR" : "PRs"}
      </output>
      <PullRequestDock />
    </RowPullRequests.Provider>
  );
}

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

test("a PR remains linked after merging, with no stale state label or removable attachment", async () => {
  const { createRoot } = await import("react-dom/client");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const url = "https://github.com/acme/uploader/pull/41";
  const rows = [
    { kind: "activity", id: "a", version: 1, items: [tool("create", 'gh pr create --title "Retry"', url)] },
  ];
  const root = createRoot(container());
  await act(async () => root.render(<TestDock rows={rows as never} />));
  expect(bars()).toEqual([["#41", null, "uploader"]]);
  await act(async () => setHeaderState({ pullRequest: live(url, 41, "merged") }));
  expect(bars()).toEqual([["#41", null, "uploader"]]);
  expect(dom.window.document.querySelector(".acpmux-pr-dock__bar")?.getAttribute("data-state")).toBe("merged");
  expect(dom.window.document.querySelector(".acpmux-pr-dock__dismiss")).toBeNull();
  act(() => root.unmount());
  setHeaderState({ pullRequest: null });
});

test("the compact count follows Changes for touched PRs and verified mentions arriving in replies", async () => {
  const { createRoot } = await import("react-dom/client");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const rows = [{ kind: "activity", id: "touch", version: 1, items: [tool("read", "gh pr view 61 -R acme/uploader")] }];
  const root = createRoot(container());
  const render = (text: string) =>
    root.render(
      <TestDock
        rows={[...rows, { kind: "assistant", id: "reply", text }] as never}
        repository="acme/uploader"
        sessionId="mentions"
        onOpenChanges={() => undefined}
      />,
    );
  setHeaderState({ pullRequest: live("https://github.com/acme/uploader/pull/62", 62, "open") });
  await act(async () => render("Working on the follow-up"));
  const count = () => dom.window.document.querySelector("[data-pr-count]")?.textContent;
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
        <TestDock
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
      expect(dom.window.document.querySelector("[data-pr-count]")?.textContent).toBe("1 PR");
      // A new verified mention must invalidate; caching cannot make the count stale.
      reply = { ...reply, version: reply.version + 1, text: `${reply.text} See #72` };
      rows.set(reply.id, reply);
      await act(async () => render());
      expect(parse).toHaveBeenCalledTimes(2);
      expect(dom.window.document.querySelector("[data-pr-count]")?.textContent).toBe("2 PRs");
      await act(async () => render("acme/other"));
      expect(parse).toHaveBeenCalledTimes(3);
      expect(dom.window.document.querySelector("[data-pr-count]")?.textContent).toBe("1 PR");
    } finally {
      act(() => root.unmount());
      setHeaderState({ pullRequest: null });
      parse.mockRestore();
    }
  },
);
