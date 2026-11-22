import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
// Tool rows reach for DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
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
const { EditedFilesCard } = await import("../conversation/EditedFilesCard");
const { setUndoCall } = await import("./undoStore");
const { setEditedFilesSettings } = await import("./settings");

let rowCount = 0;
/// An ended turn's edits: each [path, oldText, newText], one tool call each.
function editRow(edits: [string, string | undefined, string][], ended = true): AcpmuxRow {
  rowCount += 1;
  return {
    id: `row-${rowCount}`,
    version: 1,
    at: 0,
    kind: "activity",
    ended,
    items: edits.map(([path, oldText, newText], index) => ({
      kind: "tool" as const,
      text: "Edit",
      tool: {
        id: `t${rowCount}-${index}`,
        title: "Edit",
        kind: "edit",
        status: "completed",
        diffs: [{ path, ...(oldText === undefined ? {} : { oldText }), newText }],
      },
    })),
  };
}

async function render(row: AcpmuxRow, opened: (string | undefined)[] = []) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(createElement(EditedFilesCard, { row, onOpenDiff: (_id, path) => opened.push(path) })),
  );
  return { container, unmount: () => act(async () => root.unmount()) };
}
const buttons = (container: Element) => [...container.querySelectorAll("button")];
const button = (container: Element, text: string) => buttons(container).find((one) => one.textContent === text);
const click = (element: Element | undefined) => act(async () => (element as HTMLButtonElement).click());

beforeEach(() => setEditedFilesSettings({}));

describe("edited-files card Undo (host revert)", () => {
  test("asks the host first, confirms, then undoes only the files that still hold the turn's bytes", async () => {
    const calls: { files: unknown; apply: boolean }[] = [];
    setUndoCall(async (files, apply) => {
      calls.push({ files, apply });
      return apply
        ? { files: [{ path: "/r/a.ts", status: "reverted" }] }
        : {
            files: [
              { path: "/r/a.ts", status: "wouldRevert" },
              { path: "/r/b.ts", status: "changed" },
            ],
          };
    });
    const opened: (string | undefined)[] = [];
    const { container, unmount } = await render(
      editRow([
        ["/r/a.ts", "1\n", "2\n"],
        ["/r/b.ts", "x\n", "y\n"],
      ]),
      opened,
    );
    expect(container.querySelector(".acpmux-edited-title > div")!.textContent).toBe("Edited 2 files");
    await click(button(container, "Undo"));
    expect(calls).toEqual([
      {
        apply: false,
        files: [
          { path: "/r/a.ts", before: "1\n", after: "2\n" },
          { path: "/r/b.ts", before: "x\n", after: "y\n" },
        ],
      },
    ]);
    const confirm = container.querySelector(".acpmux-edited-confirm")!;
    expect(confirm.textContent).toContain("Undo 1 file?");
    expect(confirm.textContent).toContain("1 file changed since this turn and will be skipped.");
    await click([...confirm.querySelectorAll("button")].find((one) => one.textContent === "Undo"));
    expect(calls[1]).toEqual({ apply: true, files: [{ path: "/r/a.ts", before: "1\n", after: "2\n" }] });
    expect(container.querySelector(".acpmux-edited-undone")!.textContent).toBe("Undone 1 of 2");
    const statuses = [...container.querySelectorAll(".acpmux-edited-status")].map((one) => one.textContent);
    expect(statuses).toEqual(["Undone", "Changed since this turnView diff"]);
    await click(button(container, "View diff"));
    expect(opened).toEqual(["/r/b.ts"]);
    await unmount();
  });

  test("Cancel writes nothing", async () => {
    const applied: boolean[] = [];
    setUndoCall(async (_files, apply) => {
      applied.push(apply);
      return { files: [{ path: "/r/a.ts", status: "wouldRevert" }] };
    });
    const { container, unmount } = await render(editRow([["/r/a.ts", "1\n", "2\n"]]));
    await click(button(container, "Undo"));
    await click(button(container, "Cancel"));
    expect(applied).toEqual([false]);
    expect(container.querySelector(".acpmux-edited-confirm")).toBeNull();
    await unmount();
  });

  test("a file the turn created is sent with no before, for the Trash", async () => {
    const sent: unknown[] = [];
    setUndoCall(async (files) => {
      sent.push(files);
      return { files: [] };
    });
    const { container, unmount } = await render(editRow([["/r/new.ts", undefined, "made\n"]]));
    await click(button(container, "Undo"));
    expect(sent).toEqual([[{ path: "/r/new.ts", before: null, after: "made\n" }]]);
    await unmount();
  });

  test("fragment edits and a running turn offer no Undo", async () => {
    setUndoCall(async () => {
      throw new Error("never called");
    });
    const fragments = await render(
      editRow([
        ["/r/a.ts", "return 1", "return 2"],
        ["/r/a.ts", "let x", "const x"],
      ]),
    );
    expect(button(fragments.container, "Undo")).toBeUndefined();
    await fragments.unmount();
    const running = await render(editRow([["/r/a.ts", "1\n", "2\n"]], false));
    expect(button(running.container, "Undo")).toBeUndefined();
    await running.unmount();
  });
});

describe("edited-files card settings (agentPane.editedFiles)", () => {
  const seven = () => editRow(["a", "b", "c", "d", "e", "f", "g"].map((name) => [`/r/${name}.ts`, "1\n", "2\n"]));

  test("shows the first five rows by default, then Show N more", async () => {
    const { container, unmount } = await render(seven());
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    expect(container.querySelector(".acpmux-edited-more")!.textContent).toBe("Show 2 more files");
    await unmount();
  });

  test("maxRows sets how many rows show", async () => {
    setEditedFilesSettings({ maxRows: 2 });
    const { container, unmount } = await render(seven());
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(2);
    expect(container.querySelector(".acpmux-edited-more")!.textContent).toBe("Show 5 more files");
    await unmount();
  });

  test("collapsed shows the header until the chevron opens the rows", async () => {
    setEditedFilesSettings({ show: "collapsed" });
    const { container, unmount } = await render(seven());
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(0);
    await click(container.querySelector('button[aria-label="Show files"]')!);
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    await unmount();
  });

  test("collapsed that arrives after the card mounts (the host's editedFiles event) folds the rows", async () => {
    // nxdog65-v2: the page mounts the card, then the host's event sets collapsed; the rows stayed open.
    const { container, unmount } = await render(seven());
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    await act(async () => setEditedFilesSettings({ show: "collapsed" }));
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(0);
    expect(container.querySelector(".acpmux-edited-title")).not.toBeNull();
    expect(container.querySelector(".acpmux-review-changes")).not.toBeNull();
    await click(container.querySelector('button[aria-label="Show files"]')!);
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    await unmount();
  });

  test("a card the user opened stays open when it mounts again (the transcript is virtualized)", async () => {
    setEditedFilesSettings({ show: "collapsed" });
    const row = seven();
    const first = await render(row);
    await click(first.container.querySelector('button[aria-label="Show files"]')!);
    expect(first.container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    await first.unmount();
    const again = await render(row);
    expect(again.container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    await again.unmount();
    const other = await render(seven());
    expect(other.container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(0);
    await other.unmount();
  });

  test("never leaves the plain tool rows, with no card", async () => {
    setEditedFilesSettings({ show: "never" });
    const { container, unmount } = await render(seven());
    expect(container.querySelector(".acpmux-edited")).toBeNull();
    expect(container.textContent).toContain("Edit");
    await unmount();
  });

  test("a value the pane does not know keeps the default", async () => {
    setEditedFilesSettings({ show: "sometimes", maxRows: 0, scope: "galaxy" });
    const { container, unmount } = await render(seven());
    expect(container.querySelectorAll("button.acpmux-edited-file")).toHaveLength(5);
    await unmount();
  });
});

/// The Write call from Lawrence's 2026-10-06 screenshot: Claude Code's rawInput has `content`
/// before `file_path`, and the call carried no diff.
const FLEET_WRITE = JSON.stringify({
  content: 'import json, sys, urllib.request, html, datetime\n\nURL = "http://100.89.225.106:18765/v1/status"\n',
  file_path: "/tmp/fleetviz/gen.py",
});

function plainRow(tools: { title: string; inputSummary?: string; kind?: string }[]): AcpmuxRow {
  rowCount += 1;
  return {
    id: `row-${rowCount}`,
    version: 1,
    at: 0,
    kind: "activity",
    ended: true,
    items: tools.map((tool, index) => ({
      kind: "tool" as const,
      text: tool.title,
      tool: { id: `p${rowCount}-${index}`, status: "completed", kind: tool.kind ?? "edit", ...tool },
    })),
  };
}

describe("edited-files rows without a diff", () => {
  test("the fleet Write row shows its path, never the tool input's JSON", async () => {
    const { container, unmount } = await render(
      plainRow([
        { title: "Write", inputSummary: FLEET_WRITE },
        { title: "Edit", inputSummary: "{}" },
      ]),
    );
    const rows = [...container.querySelectorAll(".acpmux-edited-file")].map((row) => row.textContent);
    expect(rows).toEqual(["/tmp/fleetviz/gen.py", "Unknown file"]);
    expect(container.textContent).not.toContain("{");
    expect(container.querySelector(".acpmux-edited-file .acpmux-edited-base")?.textContent).toBe("gen.py");
    await unmount();
  });
});
