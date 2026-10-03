import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
class Inert {
  observe() {}
  unobserve() {}
  disconnect() {}
}
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: Inert,
  ResizeObserver: Inert,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The changes view renders @pierre/diffs and @pierre/trees web components, which reach for
// DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../DiffPanel");
const { readTurnCheckpoint } = await import("./model");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 50 && !done(); tries += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
};

test("a turn summary's checkpoints read as acpmux recorded them", () => {
  expect(readTurnCheckpoint({ status: "completed" })).toBeUndefined();
  expect(readTurnCheckpoint({ checkpointId: "ckpt_a", endCheckpointId: "ckpt_b" })).toEqual({
    from: "ckpt_a",
    to: "ckpt_b",
  });
  // An ended turn without its end checkpoint would compare with later work: unavailable.
  expect(readTurnCheckpoint({ checkpointId: "ckpt_a" })).toEqual({ from: null, reason: "no_end_checkpoint" });
  expect(readTurnCheckpoint({ checkpointId: null, checkpointError: "timed_out" })).toEqual({
    from: null,
    reason: "timed_out",
  });
  expect(readTurnCheckpoint({ checkpointId: null })).toEqual({ from: null });
});

test("a turn without a starting checkpoint says its changes are unavailable and asks nothing", async () => {
  const asked: string[] = [];
  const source = {
    diff: (scope: string) => (asked.push(scope), Promise.resolve({ files: [] })),
    checkpointDiff: (from: string) => (asked.push(from), Promise.resolve({ files: [] })),
  };
  await act(async () =>
    root.render(
      createElement(DiffPanel, {
        files: [],
        onClose: () => {},
        source,
        turnCheckpoint: { from: null, reason: "timed_out" },
      }),
    ),
  );
  const state = doc.querySelector('[data-state="unavailable"]');
  expect(state?.querySelector("strong")?.textContent).toBe("Changes unavailable for this turn");
  expect(asked).toEqual([]);
});

test("a turn with checkpoints reads its changes between them from the session host", async () => {
  const asked: [string, string | undefined][] = [];
  const source = {
    diff: () => Promise.reject(new Error("not this scope")),
    checkpointDiff: (from: string, to?: string) => {
      asked.push([from, to]);
      return Promise.resolve({
        root: "/repo",
        from,
        to,
        files: [{ path: "src/a.ts", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n a\n+b\n" }],
        additions: 1,
        deletions: 0,
        total_files: 1,
        files_omitted: 0,
      });
    },
  };
  await act(async () =>
    root.render(
      createElement(DiffPanel, {
        files: [],
        onClose: () => {},
        source,
        turnCheckpoint: { from: "ckpt_a", to: "ckpt_b" },
      }),
    ),
  );
  await settle(
    () => doc.body.textContent?.includes("src/a.ts") === true || doc.body.textContent?.includes("a.ts") === true,
  );
  expect(asked).toEqual([["ckpt_a", "ckpt_b"]]);
  expect(doc.querySelector('[data-state="unavailable"]')).toBeNull();
  expect(doc.body.textContent).toContain("a.ts");
});

test("a turn with checkpoints reviews the files its tool calls changed and marks the others read-only", async () => {
  const { turnFiles } = await import("../diff");
  const transcript = turnFiles([
    {
      id: "activity-1",
      version: 1,
      at: 1,
      kind: "activity",
      items: [
        {
          kind: "tool",
          text: "Edit",
          tool: {
            id: "t1",
            title: "Edit",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/a.ts", oldText: "a\n", newText: "a\nb\n", line: 1 }],
          },
        },
      ],
    },
  ] as never);
  const source = {
    diff: () => Promise.reject(new Error("not this scope")),
    checkpointDiff: () =>
      Promise.resolve({
        root: "/repo",
        files: [
          { path: "src/a.ts", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n a\n+b\n" },
          { path: "src/b.ts", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n x\n+y\n" },
        ],
      }),
  };
  const decisions = new Map<string, "accepted" | "rejected" | "requested">();
  const sent: { keys: string[]; prompt: string }[] = [];
  const render = () =>
    root.render(
      createElement(DiffPanel, {
        files: transcript,
        onClose: () => {},
        source,
        turnCheckpoint: { from: "ckpt_a", to: "ckpt_b" },
        review: {
          decisions: new Map(decisions),
          decide: (key: string, decision?: "accepted" | "rejected" | "requested") => {
            if (decision) decisions.set(key, decision);
            else decisions.delete(key);
            render();
          },
          requestRevert: (keys: string[], prompt: string) => {
            sent.push({ keys, prompt });
            for (const key of keys) decisions.set(key, "requested");
            render();
          },
        },
      }),
    );
  await act(async () => render());
  await settle(() => doc.querySelector(".acpmux-hunk-reject") !== null);
  const section = (path: string) => doc.querySelector(`.acpmux-diff-file[data-path="${path}"]`);
  // The tool calls changed a.ts: its hunk keeps Reject and Accept.
  expect(section("/repo/src/a.ts")?.querySelector(".acpmux-diff-outside")).toBeNull();
  expect(doc.querySelectorAll(".acpmux-hunk-reject").length).toBe(1);
  // b.ts changed some other way: read-only, and marked as outside the agent's edits.
  expect(section("/repo/src/b.ts")?.querySelector(".acpmux-diff-outside")?.textContent).toBe(
    "Outside the agent's edits",
  );
  expect(section("/repo/src/b.ts")?.querySelector(".acpmux-hunk-actions")).toBeNull();
  await act(async () => {
    doc.querySelector(".acpmux-hunk-reject")!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  // A decision names the turn's checkpoints, so it never marks another turn's hunks.
  expect([...decisions.keys()]).toEqual(["checkpoint:ckpt_a..ckpt_b\u0000/repo/src/a.ts\u00000\u00000"]);
  await act(async () => {
    doc.querySelector(".acpmux-revert-send")!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  expect(sent.length).toBe(1);
  expect(sent[0]!.prompt).toContain("--- /repo/src/a.ts\n+++ /repo/src/a.ts\n@@ -1,1 +1,2 @@\n a\n+b");
  expect(sent[0]!.prompt).not.toContain("b.ts");
});
