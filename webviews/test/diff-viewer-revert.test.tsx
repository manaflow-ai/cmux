// l10n-allow-file: test fixture file names and file text, not shipped UI.
// The diff tab's Revert and hunk Stage (D3, the Codex Review pane's): a file header's Revert, a hunk's
// Stage and Revert on hover, and the floating Stage all / Revert all bar, over the host's
// `cmux.diff.git.discard`, `.discardHunk`, `.undoDiscard` and `.stageHunk`. Only Unstaged and
// Uncommitted, whose changes are in the work tree, offer Revert. A hunk names its lines as git
// printed them, which is how the host finds it in its own read of the file's diff.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { parsePatchFiles } = await import("@pierre/diffs");
const { loadDiffViewerLabels, createDiffViewerLabelResolver } = await import("../src/labels");
await loadDiffViewerLabels("en");
const revert = await import("../src/diff-viewer/revert");
const { DiffBulkBar, HUNK_HOVER_GRACE_MS, HunkHoverActions, hunkHoverCallbacks, revertFailureMessage, useDiffRevert } =
  await import("../src/diff-viewer/RevertControls");
const { FileHeader } = await import("../src/diff-viewer/FileHeader");
const { pageError } = await import("../src/pages/shared/pageClient");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const label = createDiffViewerLabelResolver(undefined, { language: "en" });
const buttons = () => [...dom.window.document.querySelectorAll("button")];
/** A button by its text, or by its name when it shows only an icon (the hunk pill's). */
const button = (text: string) =>
  buttons().find((element) => element.textContent?.trim() === text || element.getAttribute("aria-label") === text);

/** Twenty lines, lines 2 and 19 changed: two hunks, as `git diff` prints them. */
const PATCH = `diff --git a/src/a.txt b/src/a.txt
index 1111111..2222222 100644
--- a/src/a.txt
+++ b/src/a.txt
@@ -1,5 +1,5 @@
 line 1
-line 2
+line two
 line 3
 line 4
 line 5
@@ -16,5 +16,6 @@ fn
 line 16
 line 17
 line 18
-line 19
+line nineteen\r
+line nineteen and a half
 line 20
`;
const fileDiff = parsePatchFiles(PATCH)[0]!.files[0]!;
const item = { id: "f1", fileDiff } as never;

const ALL_OPS = [
  "cmux.diff.git.discard",
  "cmux.diff.git.discardHunk",
  "cmux.diff.git.undoDiscard",
  "cmux.diff.git.stageHunk",
  "cmux.diff.git.unstageHunk",
];

function recordingPage(answer: (op: string) => unknown = () => ({ ok: true })) {
  const calls: [string, unknown][] = [];
  return {
    calls,
    page: {
      call: async (op: string, params: unknown) => {
        calls.push([op, params]);
        const value = answer(op);
        if (value instanceof Error) throw value;
        return value;
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    },
  };
}

test("only scopes whose changes are in the work tree offer Revert", () => {
  expect(revert.revertScopeOf({ kind: "unstaged", repoRoot: "/r" })).toBe("unstaged");
  expect(revert.revertScopeOf({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" })).toBe("uncommitted");
  expect(revert.revertScopeOf({ kind: "branch", repoRoot: "/r", baseRef: "main" })).toBeUndefined();
  expect(revert.revertScopeOf({ kind: "branch", repoRoot: "/r" })).toBeUndefined();
  expect(revert.revertScopeOf({ kind: "staged", repoRoot: "/r" })).toBeUndefined();
  expect(revert.revertScopeOf({ kind: "patch", path: "/tmp/x.patch" })).toBeUndefined();
  expect(revert.revertScopeOf(null)).toBeUndefined();
  expect(revert.hunkStageModeOf({ kind: "staged", repoRoot: "/r" })).toBe("unstage");
  expect(revert.hunkStageModeOf({ kind: "unstaged", repoRoot: "/r" })).toBe("stage");
  expect(revert.hunkStageModeOf({ kind: "branch", repoRoot: "/r", baseRef: "main" })).toBeUndefined();
  // The host stages a hunk of the index against the work tree, which Uncommitted does not show.
  expect(revert.hunkStageModeOf({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" })).toBeUndefined();
});

test("a hunk's lines read as git printed them, without line endings", () => {
  expect(revert.hunkLines(fileDiff, 0)).toEqual([" line 1", "-line 2", "+line two", " line 3", " line 4", " line 5"]);
  expect(revert.hunkLines(fileDiff, 1)).toEqual([
    " line 16",
    " line 17",
    " line 18",
    "-line 19",
    "+line nineteen",
    "+line nineteen and a half",
    " line 20",
  ]);
  expect(revert.hunkLines(fileDiff, 2)).toBeUndefined();
});

test("a line finds its hunk on its own side, and a line between hunks finds none", () => {
  expect(revert.hunkIndexAt(fileDiff, "additions", 2)).toBe(0);
  expect(revert.hunkIndexAt(fileDiff, "deletions", 19)).toBe(1);
  expect(revert.hunkIndexAt(fileDiff, "additions", 21)).toBe(1);
  expect(revert.hunkIndexAt(fileDiff, "deletions", 21)).toBeUndefined();
  expect(revert.hunkIndexAt(fileDiff, "additions", 10)).toBeUndefined();
});

test("new, deleted and binary files revert whole, never by hunk", () => {
  expect(revert.hunksActionable(fileDiff)).toBe(true);
  expect(revert.hunksActionable({ ...fileDiff, type: "new" })).toBe(false);
  expect(revert.hunksActionable({ ...fileDiff, type: "deleted" })).toBe(false);
  expect(revert.hunksActionable({ ...fileDiff, hunks: [] })).toBe(false);
  expect(revert.hunksActionable(undefined)).toBe(false);
  // In Uncommitted a rename is staged, and the host refuses a hunk of a file with staged changes.
  expect(revert.hunksActionable({ ...fileDiff, type: "rename-changed" }, "unstaged")).toBe(true);
  expect(revert.hunksActionable({ ...fileDiff, type: "rename-changed" }, "uncommitted")).toBe(false);
});

test("Stage all and Revert all name each file once, a rename with its previous path for Revert", () => {
  const items = [
    { id: "a", fileDiff: { name: "a.txt" } },
    { id: "b", fileDiff: { name: "new.txt", prevName: "old.txt" } },
    { id: "c", fileDiff: { name: "a.txt" } },
  ] as never[];
  const pathOf = (each: { fileDiff: { name: string } }) => each.fileDiff.name;
  expect(revert.allPaths(items, pathOf as never, true)).toEqual(["a.txt", "new.txt", "old.txt"]);
  expect(revert.allPaths(items, pathOf as never, false)).toEqual(["a.txt", "new.txt"]);
  expect(revert.renameSources(items, pathOf as never)).toEqual(["old.txt"]);
  expect(revert.chunked([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
});

test("a host without every revert op gets no Revert, and hunk Stage does not need Revert", () => {
  const { page } = recordingPage();
  expect(revert.diffRevertSource(page as never, ["cmux.diff.git.discard"])).toBeUndefined();
  expect(revert.diffRevertSource(null, ALL_OPS)).toBeUndefined();
  const withoutHunkStage = revert.diffRevertSource(page as never, ALL_OPS.slice(0, 3))!;
  expect(withoutHunkStage.revert).toBeDefined();
  expect(withoutHunkStage.stageHunk).toBeUndefined();
  // A host that serves only the stage ops.
  const revertOff = revert.diffRevertSource(page as never, ALL_OPS.slice(3))!;
  expect(revertOff.revert).toBeUndefined();
  expect(revertOff.stageHunk).toBeDefined();
});

test("a hunk's Stage and Revert sit on its first changed line, not on the line under the pointer", () => {
  expect(revert.hunkFirstChange(fileDiff, 0)).toEqual({ deletions: 2, additions: 2 });
  expect(revert.hunkFirstChange(fileDiff, 1)).toEqual({ deletions: 19, additions: 19 });
  expect(revert.hunkFirstChange(fileDiff, 2)).toBeUndefined();

  // The file's rendered rows (Pierre's unified pre): the pointer is on context line 17.
  const document = dom.window.document;
  const pre = document.createElement("pre");
  const row = (line: number, type: string) => {
    const element = document.createElement("div");
    element.dataset.line = String(line);
    element.dataset.lineType = type;
    pre.append(element);
    return element;
  };
  row(16, "context");
  const hovered = row(17, "context");
  row(18, "context");
  const removed = row(19, "change-deletion");
  row(19, "change-addition");
  document.body.append(pre);
  expect(revert.hunkAnchorRow(hovered, fileDiff, 1)).toBe(removed);
  // A first changed row that is not rendered (scrolled out of a long hunk): the caller keeps the hovered row.
  expect(revert.hunkAnchorRow(hovered, fileDiff, 0)).toBeUndefined();
  pre.remove();
});

test("the pill stays while the pointer is on it, though the viewer reports leaving the line", async () => {
  jest.useFakeTimers();
  try {
    const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" });
    await hoverLine(harness, "additions", 20);
    const pill = () => dom.window.document.querySelector(".diff-hunk-actions");
    const events = dom.window as unknown as { PointerEvent?: typeof PointerEvent; MouseEvent: typeof MouseEvent };
    const Pointer = events.PointerEvent ?? events.MouseEvent;
    await act(async () => void pill()!.dispatchEvent(new Pointer("pointerover", { bubbles: true })));
    // Every move over the pill reaches the viewer as a line leave.
    const callbacks = hunkHoverCallbacks(harness.hover);
    await act(async () => {
      callbacks.onLineLeave();
    });
    await act(async () => void jest.advanceTimersByTime(HUNK_HOVER_GRACE_MS * 3));
    expect(pill()).not.toBeNull();
    // Leaving the pill hides it after the grace time.
    await act(async () => void pill()!.dispatchEvent(new Pointer("pointerout", { bubbles: true })));
    await act(async () => void jest.advanceTimersByTime(HUNK_HOVER_GRACE_MS + 1));
    expect(pill()).toBeNull();
  } finally {
    jest.useRealTimers();
  }
});

test("the hunk pill is two named icon buttons, Revert's arrow then Stage's plus", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" });
  await hoverLine(harness, "additions", 20);
  const pill = [...dom.window.document.querySelectorAll(".diff-hunk-actions button")];
  expect(pill.map((element) => element.getAttribute("aria-label"))).toEqual(["Revert", "Stage"]);
  expect(pill.map((element) => element.querySelector("svg")?.getAttribute("data-icon"))).toEqual(["revert", "plus"]);
  expect(pill.every((element) => element.textContent?.trim() === "")).toBe(true);
});

test("a declined sheet says nothing; git's own reason is shown as it is", () => {
  expect(revertFailureMessage(pageError("cmux.page.cancelled", "cancelled"), "fallback")).toBeUndefined();
  expect(revertFailureMessage(pageError("git.failed", "error: patch failed: a.txt:2"), "fallback")).toBe(
    "error: patch failed: a.txt:2",
  );
  expect(revertFailureMessage(pageError("git.busy", "Another revert is still running."), "fallback")).toBe(
    "Another revert is still running.",
  );
  expect(revertFailureMessage(new Error("boom"), "fallback")).toBe("fallback");
});

type Harness = {
  calls: [string, unknown][];
  refreshes: string[];
  hover: { current: import("../src/diff-viewer/RevertControls").HunkHoverHandle | null };
  rerender: (props: Partial<ViewerProps>) => Promise<void>;
};

type ViewerProps = {
  shown: import("../src/diff/generated/protocol").DiffSource;
  items: never[];
  complete: boolean;
};

const renamed = {
  id: "f2",
  fileDiff: { name: "src/new.txt", prevName: "src/old.txt", type: "rename-pure", hunks: [] },
};

async function renderViewer(
  shown: import("../src/diff/generated/protocol").DiffSource,
  answer?: (op: string) => unknown,
  ops: string[] = ALL_OPS,
  hidesChanges = false,
): Promise<Harness> {
  const { page, calls } = recordingPage(answer);
  const source = revert.diffRevertSource(page as never, ops)!;
  const stage = (paths: string[], unstage: boolean) =>
    page.call(unstage ? "cmux.diff.git.unstage" : "cmux.diff.git.stage", { paths });
  const refreshes: string[] = [];
  const hover = createRef<import("../src/diff-viewer/RevertControls").HunkHoverHandle>() as Harness["hover"];
  const viewer = { current: dom.window.document.getElementById("root") };
  let props: ViewerProps = { shown, items: [item, renamed as never], complete: true };
  function Viewer(current: ViewerProps) {
    const actions = useDiffRevert({
      source,
      stage,
      shown: current.shown,
      items: current.items,
      complete: current.complete,
      label,
      refresh: () => refreshes.push("refreshed"),
      hidesChanges,
    });
    return (
      <div>
        <FileHeader
          item={item}
          label={label}
          onLoadDiff={() => {}}
          onToggleCollapsed={() => refreshes.push("toggled")}
          onToggleViewed={() => {}}
          revert={actions.revertFile}
          viewedState="unviewed"
        />
        <FileHeader
          item={renamed as never}
          label={label}
          onLoadDiff={() => {}}
          onToggleCollapsed={() => {}}
          onToggleViewed={() => {}}
          revert={actions.revertFile}
          viewedState="unviewed"
        />
        <HunkHoverActions
          handle={hover}
          viewer={viewer}
          actionsFor={actions.hunkActions}
          busy={actions.busy}
          label={label}
        />
        <DiffBulkBar revert={actions} label={label} />
      </div>
    );
  }
  const rerender = async (next: Partial<ViewerProps>) => {
    props = { ...props, ...next };
    await act(async () => root.render(<Viewer {...props} />));
  };
  await rerender({});
  return { calls, refreshes, hover, rerender };
}

/** Pierre's record for an item: CodeView passes it after a callback's own arguments. */
const record = { type: "diff", item, instance: {}, index: 0, top: 0 };

/** The pointer enters `lineNumber` on `side`, through the callbacks the viewer gives Pierre. */
async function hoverLine(harness: Harness, side: "additions" | "deletions", lineNumber: number) {
  const lineElement = dom.window.document.createElement("div");
  const callbacks = hunkHoverCallbacks(harness.hover);
  await act(async () =>
    callbacks.onLineEnter(
      { lineNumber, annotationSide: side, lineType: "change-addition", lineElement },
      record as never,
    ),
  );
}

const note = () => dom.window.document.querySelector(".diff-bulk-note")?.textContent;
const arrows = () => [...dom.window.document.querySelectorAll<HTMLButtonElement>(".file-review-revert")];

test("in Unstaged a file reverts from its header, after the host's sheet, without toggling the file", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" });
  const arrow = arrows()[0]!;
  expect(arrow.getAttribute("aria-label")).toBe("Revert changes to a.txt");
  await act(async () => arrow.click());
  expect(harness.calls).toEqual([["cmux.diff.git.discard", { paths: ["src/a.txt"], scope: "unstaged" }]]);
  expect(harness.refreshes).toEqual(["refreshed"]);
});

test("a renamed file's revert names its previous path as the rename's source, so the sheet counts one file", async () => {
  const harness = await renderViewer({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" });
  await act(async () => arrows()[1]!.click());
  expect(harness.calls).toEqual([
    [
      "cmux.diff.git.discard",
      { paths: ["src/new.txt", "src/old.txt"], scope: "uncommitted", sources: ["src/old.txt"] },
    ],
  ]);
});

test("Revert all sends every file in one request, so the host asks once; Stage all stages them", async () => {
  const harness = await renderViewer({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" });
  await act(async () => button("Revert all")!.click());
  expect(harness.calls).toEqual([
    [
      "cmux.diff.git.discard",
      { paths: ["src/a.txt", "src/new.txt", "src/old.txt"], scope: "uncommitted", sources: ["src/old.txt"] },
    ],
  ]);
  harness.calls.length = 0;
  await act(async () => button("Stage all")!.click());
  expect(harness.calls).toEqual([["cmux.diff.git.stage", { paths: ["src/a.txt", "src/new.txt"] }]]);
});

test("a host with only the stage ops gets hunk Stage and Stage all, and no Revert, Revert all or Undo", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, undefined, ALL_OPS.slice(3));
  expect(arrows()).toEqual([]);
  expect(button("Revert all")).toBeUndefined();
  expect(button("Stage all")).toBeDefined();
  await hoverLine(harness, "additions", 20);
  expect(button("Revert")).toBeUndefined();
  await act(async () => button("Stage")!.click());
  expect(harness.calls).toEqual([
    ["cmux.diff.git.stageHunk", { paths: ["src/a.txt"], hunk: revert.hunkLines(fileDiff, 1) }],
  ]);
});

test("while the diff hides changes (white space, imports), no file Revert, Revert all or Stage all; hunks keep theirs", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, undefined, ALL_OPS, true);
  expect(arrows()).toEqual([]);
  expect(button("Revert all")).toBeUndefined();
  expect(button("Stage all")).toBeUndefined();
  await hoverLine(harness, "additions", 20);
  expect(button("Revert")).toBeDefined();
  expect(button("Stage")).toBeDefined();
});

test("Stage all and Revert all wait for the whole diff", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" });
  await harness.rerender({ complete: false });
  expect(button("Revert all")).toBeUndefined();
  expect(button("Stage all")).toBeUndefined();
  await harness.rerender({ complete: true });
  expect(button("Revert all")).toBeDefined();
});

test("Pierre's line callback, with the item's record, shows a hunk's buttons; Revert sends that hunk", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, (op) =>
    op === "cmux.diff.git.discardHunk" ? { ok: true, undo: "token-1" } : { ok: true },
  );
  await hoverLine(harness, "additions", 20);
  const bar = dom.window.document.querySelector(".diff-hunk-actions");
  expect(bar?.getAttribute("aria-label")).toBe("Actions for this change");
  expect(button("Stage")).toBeDefined();
  await act(async () => button("Revert")!.click());
  expect(harness.calls).toEqual([
    ["cmux.diff.git.discardHunk", { paths: ["src/a.txt"], hunk: revert.hunkLines(fileDiff, 1), scope: "unstaged" }],
  ]);
  expect(dom.window.document.querySelector(".diff-hunk-actions")).toBeNull();
  expect(note()).toBe("Change reverted.");
});

test("Undo stays after the revert empties the diff, puts each hunk back newest first, and stays with its scope", async () => {
  let next = 0;
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, (op) =>
    op === "cmux.diff.git.discardHunk" ? { ok: true, undo: `token-${(next += 1)}` } : { ok: true },
  );
  await hoverLine(harness, "additions", 2);
  await act(async () => button("Revert")!.click());
  await hoverLine(harness, "additions", 20);
  await act(async () => button("Revert")!.click());
  // The diff reloads with no files left.
  await harness.rerender({ items: [] });
  expect(button("Undo")).toBeDefined();
  // A declined sheet keeps Undo.
  await harness.rerender({ items: [item, renamed as never] });
  // Another scope shows no Undo; coming back shows it again.
  await harness.rerender({ shown: { kind: "staged", repoRoot: "/r" } });
  expect(button("Undo")).toBeUndefined();
  await harness.rerender({ shown: { kind: "unstaged", repoRoot: "/r" } });
  harness.calls.length = 0;
  await act(async () => button("Undo")!.click());
  await act(async () => button("Undo")!.click());
  expect(harness.calls).toEqual([
    ["cmux.diff.git.undoDiscard", { undo: "token-2" }],
    ["cmux.diff.git.undoDiscard", { undo: "token-1" }],
  ]);
  expect(button("Undo")).toBeUndefined();
});

test("a declined file sheet keeps Undo and refreshes nothing", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, (op) =>
    op === "cmux.diff.git.discardHunk"
      ? { ok: true, undo: "token-1" }
      : op === "cmux.diff.git.discard"
        ? pageError("cmux.page.cancelled", "cancelled")
        : { ok: true },
  );
  await hoverLine(harness, "additions", 2);
  await act(async () => button("Revert")!.click());
  harness.refreshes.length = 0;
  await act(async () => button("Revert all")!.click());
  expect(harness.refreshes).toEqual([]);
  expect(button("Undo")).toBeDefined();
  expect(dom.window.document.querySelector('.diff-bulk-note[data-kind="error"]')).toBeNull();
});

test("an Undo the host fails drops its token; a busy host keeps it", async () => {
  let undoAnswer: unknown = pageError("git.busy", "Busy");
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, (op) =>
    op === "cmux.diff.git.discardHunk"
      ? { ok: true, undo: "token-1" }
      : op === "cmux.diff.git.undoDiscard"
        ? undoAnswer
        : { ok: true },
  );
  await hoverLine(harness, "additions", 2);
  await act(async () => button("Revert")!.click());
  await act(async () => button("Undo")!.click());
  expect(button("Undo")).toBeDefined();
  undoAnswer = pageError("git.failed", "The file changed since the revert.");
  await act(async () => button("Undo")!.click());
  expect(button("Undo")).toBeUndefined();
  expect(dom.window.document.querySelector('.diff-bulk-note[data-kind="error"]')?.textContent).toContain(
    "The file changed since the revert.",
  );
});

test("a line between hunks shows no hunk buttons; a hunk's Stage stages only that hunk", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" });
  await hoverLine(harness, "additions", 10);
  expect(dom.window.document.querySelector(".diff-hunk-actions")).toBeNull();
  await hoverLine(harness, "deletions", 2);
  await act(async () => button("Stage")!.click());
  expect(harness.calls).toEqual([
    ["cmux.diff.git.stageHunk", { paths: ["src/a.txt"], hunk: revert.hunkLines(fileDiff, 0) }],
  ]);
});

test("Uncommitted offers hunk Revert but not hunk Stage", async () => {
  const harness = await renderViewer({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" });
  await hoverLine(harness, "additions", 2);
  expect(button("Stage")).toBeUndefined();
  expect(button("Revert")).toBeDefined();
});

test("Staged and Branch show no Revert, and Staged's hunks unstage", async () => {
  await renderViewer({ kind: "branch", repoRoot: "/r", baseRef: "main" });
  expect(arrows()).toEqual([]);
  expect(dom.window.document.querySelector(".diff-bulk-bar")).toBeNull();
  const harness = await renderViewer({ kind: "staged", repoRoot: "/r" });
  expect(arrows()).toEqual([]);
  expect(dom.window.document.querySelector(".diff-bulk-bar")).toBeNull();
  await hoverLine(harness, "additions", 2);
  expect(button("Revert")).toBeUndefined();
  await act(async () => button("Unstage")!.click());
  expect(harness.calls.map(([op]) => op)).toEqual(["cmux.diff.git.unstageHunk"]);
});

test("a failure shows git's reason in the bar, also in Staged, and the diff refreshes", async () => {
  const harness = await renderViewer({ kind: "unstaged", repoRoot: "/r" }, () =>
    pageError("git.failed", "That change is no longer in the file. Refresh and try again."),
  );
  await hoverLine(harness, "additions", 2);
  await act(async () => button("Revert")!.click());
  const shown = dom.window.document.querySelector('.diff-bulk-note[data-kind="error"]');
  expect(shown?.textContent).toBe("That change is no longer in the file. Refresh and try again.");
  // An <output> is a status: a screen reader announces it too.
  expect(shown?.tagName).toBe("OUTPUT");
  expect(harness.refreshes).toEqual(["refreshed"]);
  const staged = await renderViewer({ kind: "staged", repoRoot: "/r" }, () =>
    pageError("git.failed", "index.lock exists"),
  );
  await hoverLine(staged, "additions", 2);
  await act(async () => button("Unstage")!.click());
  expect(note()).toBe("index.lock exists");
});
