// l10n-allow-file: synthetic transcript revision fixture.
import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

// VirtualTranscript reaches into browser layout and the Pierre web components while rendering. Keep
// this focused test's DOM harness local so it can exercise the real transcript without restoring the
// large deleted transcript fixture suite.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IntersectionObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(_callback: () => void) {}
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
});

test("inline PR parsing retains the producer revision across filtered snapshots", async () => {
  const parser = await import("../src/agent-session/acpmux/summary/transcriptPullRequests");
  const key = spyOn(parser, "transcriptPullRequestKey");
  const parse = spyOn(parser, "transcriptPullRequests");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const revision = Symbol();
  try {
    for (let token = 0; token < 20; token++) {
      const producer: AcpmuxRow[] = [];
      parser.markPullRequestCommandVersion(producer, revision);
      // Permission/thought filtering creates an array without the producer's revision marker.
      const filtered = [...producer];
      const raw = { pullRequestRows: producer };
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={filtered}
            sourceRows={filtered}
            {...raw}
            sessionId="pr-revision"
            expanded={new Set()}
            onToggleActivity={() => {}}
          />,
        ),
      );
      expect(key.mock.calls.at(-1)?.[0]).toBe(producer);
    }
    expect(parse).toHaveBeenCalledTimes(1);
  } finally {
    act(() => root.unmount());
    key.mockRestore();
    parse.mockRestore();
  }
});

test("assistant-only PR URLs remain Sources without invalidating inline Changes", async () => {
  const { OrderedRows } = await import("../src/agent-session/acpmux/direct");
  const { assistant } = await import("../src/gallery/fixtures/acpmux");
  const parser = await import("../src/agent-session/acpmux/summary/transcriptPullRequests");
  const parse = spyOn(parser, "transcriptPullRequests");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = new OrderedRows();
  const reply = assistant("Working", 1);
  let version = reply.version;
  const render = async (text: string) => {
    rows.set(reply.id, { ...reply, text, version: ++version, streaming: true });
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={[]}
          sourceRows={[]}
          pullRequestRows={rows.sorted()}
          sessionId="assistant-pr-revision"
          expanded={new Set()}
          onToggleActivity={() => {}}
        />,
      ),
    );
    const result = parse.mock.results.at(-1);
    expect(result?.type).toBe("return");
    return result?.type === "return" ? result.value.map((pr) => pr.url) : undefined;
  };
  try {
    expect(await render("Working")).toEqual([]);
    const first = "https://github.com/acme/uploader/pull/42";
    expect(await render(`See ${first}`)).toEqual([]);
    expect(parse).toHaveBeenCalledTimes(1);
    expect(await render(`See ${first} for details.`)).toEqual([]);
    expect(parse).toHaveBeenCalledTimes(1);
    const updated = "https://github.com/acme/other/pull/43";
    expect(await render(`See ${updated}`)).toEqual([]);
    expect(parse).toHaveBeenCalledTimes(1);
    expect(await render("Still working")).toEqual([]);
    expect(parse).toHaveBeenCalledTimes(1);
  } finally {
    act(() => root.unmount());
    parse.mockRestore();
  }
});

test("PR fallback remains until the revealed prefix renders a safe block", async () => {
  const { assistant, activity, tool } = await import("../src/gallery/fixtures/acpmux");
  const { revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
  const savedFrames = { ...revealFrames };
  let queued: FrameRequestCallback[] = [];
  revealFrames.request = (callback) => queued.push(callback);
  revealFrames.cancel = () => {};
  const root = createRoot(dom.window.document.getElementById("root")!);
  const url = "https://github.com/acme/uploader/pull/41";
  const opened = activity(
    [
      tool("gh pr create", "execute", "completed", {
        command: "gh pr create",
        output: url,
        exitCode: 0,
      }),
    ],
    1,
  );
  const reply = assistant("", 2, { streaming: true });
  let version = reply.version;
  const render = async (text: string) => {
    const rows = [opened, { ...reply, text, version: ++version }];
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          pullRequestRows={rows}
          sessionId="reveal-pr"
          expanded={new Set()}
          onToggleActivity={() => {}}
        />,
      ),
    );
  };
  const links = () => dom.window.document.querySelectorAll(`.acpmux-pr-dock__bar[href="${url}"]`);
  try {
    await render("");
    expect(links()).toHaveLength(1);
    expect(links()[0]?.closest(".acpmux-pr-fallback")).not.toBeNull();
    await render("   ");
    expect(links()).toHaveLength(1);
    await render("```ts");
    expect(links()[0]?.closest(".acpmux-pr-fallback")).not.toBeNull();
    await render("```ts\nconst ready = true;\n");
    // The source can render now, but no reveal frame has run: its displayed prefix cannot.
    expect(links()).toHaveLength(1);
    expect(links()[0]?.closest(".acpmux-pr-fallback")).not.toBeNull();
    for (let frame = 0; frame < 100; frame++) {
      const callbacks = queued;
      queued = [];
      await act(async () => callbacks.forEach((callback) => callback(frame * 16)));
      expect(links()).toHaveLength(1);
    }
    expect(links()[0]?.closest(".acpmux-pr-fallback")).toBeNull();
    expect(links()[0]?.closest(".acpmux-assistant")).not.toBeNull();
  } finally {
    act(() => root.unmount());
    Object.assign(revealFrames, savedFrames);
  }
});

test("child streaming PR input retains producer revisions through visual transforms", async () => {
  const { SubagentFold } = await import("../src/agent-session/acpmux/subagents/subagentFold");
  const { childView } = await import("../src/agent-session/acpmux/subagents/subagentRows");
  const { pullRequestRows } = await import("../src/agent-session/acpmux/summary/pullRequestRows");
  const { transcriptPullRequestKey, transcriptPullRequests } =
    await import("../src/agent-session/acpmux/summary/transcriptPullRequests");
  const fold = new SubagentFold();
  let seq = 0;
  const feed = (update: Record<string, unknown>, acpmux: Record<string, unknown> = { subagent: "child" }) => {
    seq++;
    fold.reduce({ seq, at: seq, msg: { method: "session/update", params: { update, _meta: { acpmux } } } }, update);
  };
  feed({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: null, name: "Helper" }] });
  const parent = fold.takeRows();
  for (let index = 0; index < 100; index++) {
    feed({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "History" } });
    feed({
      sessionUpdate: "tool_call",
      toolCallId: `tool-${index}`,
      title: "Read",
      status: "completed",
    });
  }
  let revision: string | symbol | undefined;
  for (let token = 0; token < 20; token++) {
    feed({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: " word" } });
    const views = fold.views();
    const visual = childView("child", parent, views, new Set(), "Parent")!;
    const raw = views.child!;
    let reads = 0;
    for (const row of raw) {
      const kind = row.kind;
      Object.defineProperty(row, "kind", {
        configurable: true,
        get: () => {
          reads++;
          return kind;
        },
      });
    }
    const source = pullRequestRows({ rows: parent, subagentViews: views }, visual, "child");
    const key = transcriptPullRequestKey(source, false);
    if (token === 0) revision = key;
    expect(key).toBe(revision!);
    expect(reads).toBe(0);
  }
  feed({
    sessionUpdate: "tool_call",
    toolCallId: "create",
    title: "gh pr create",
    kind: "execute",
    status: "completed",
    rawInput: { command: "gh pr create" },
    content: [{ type: "text", text: "https://github.com/acme/uploader/pull/41" }],
  });
  const views = fold.views();
  const source = pullRequestRows(
    { rows: parent, subagentViews: views },
    childView("child", parent, views, new Set(), "Parent"),
    "child",
  );
  expect(transcriptPullRequestKey(source, false)).not.toBe(revision);
  expect(transcriptPullRequests(source).map((pr) => pr.number)).toContain(41);
});

test("empty nested Markdown keeps fallback and finished replies use their action row", async () => {
  const { assistant, activity, tool } = await import("../src/gallery/fixtures/acpmux");
  const opened = activity(
    [
      tool("gh pr create", "execute", "completed", {
        command: "gh pr create",
        output: "https://github.com/acme/uploader/pull/41",
        exitCode: 0,
      }),
    ],
    3,
  );
  for (const text of [">", "> >", "Ready for review."]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const empty = text.startsWith(">");
    const reply = assistant(text, 2, { streaming: empty });
    const rows = empty ? [opened, reply] : [opened, reply, activity([tool("Read", "read", "completed")], 1)];
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={rows}
            pullRequestRows={rows}
            sessionId={`host-${text}`}
            expanded={new Set()}
            onToggleActivity={() => {}}
          />,
        ),
      );
      const links = dom.window.document.querySelectorAll(".acpmux-pr-dock__bar");
      expect(links).toHaveLength(1);
      expect(links[0]?.closest(empty ? ".acpmux-pr-fallback" : ".cv-reply-actions")).not.toBeNull();
      expect(dom.window.document.querySelector(".cv-md .acpmux-pr-dock")).toBeNull();
    } finally {
      act(() => root.unmount());
    }
  }
});

test("custom footer and incoming renderers without PR hosts retain fallback", async () => {
  const { activity, tool } = await import("../src/gallery/fixtures/acpmux");
  const opened = activity(
    [
      tool("gh pr create", "execute", "completed", {
        command: "gh pr create",
        output: "https://github.com/acme/uploader/pull/41",
        exitCode: 0,
      }),
    ],
    3,
  );
  for (const kind of ["turnSummary", "user"]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const last: AcpmuxRow = {
      id: kind,
      kind,
      at: 1,
      version: 1,
      text: "Done",
      ...(kind === "user"
        ? { incoming: { kind: "message" as const, message: { name: "Helper", text: "Done", raw: "Done" } } }
        : {}),
    };
    const rows = [opened, last];
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={rows}
            pullRequestRows={rows}
            sessionId={`custom-${kind}`}
            registry={{ [kind]: () => <div>Custom message</div> }}
            expanded={new Set()}
            onToggleActivity={() => {}}
          />,
        ),
      );
      expect(dom.window.document.querySelectorAll(".acpmux-pr-dock__bar")).toHaveLength(1);
      expect(dom.window.document.querySelector(".acpmux-pr-fallback .acpmux-pr-dock__bar")).not.toBeNull();
    } finally {
      act(() => root.unmount());
    }
  }
});
