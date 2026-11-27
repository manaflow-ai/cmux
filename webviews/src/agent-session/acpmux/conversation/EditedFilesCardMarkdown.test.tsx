// l10n-allow-file: test fixtures.
// A Markdown file the agent wrote or changed opens in cmux's Markdown page from the edited-files card
// the chat already draws (EditedFilesCard.tsx, writtenArtifacts.tsx `OpenWrittenMarkdown`): Open at
// the end of its row, or beside View changes on a card for one file, once per file however often the
// turn wrote it, through the path chip's `link.openPath`. No other file gets one, nor a read-only copy.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { setChipHost } from "../chips/host";
import { EditedFilesCard } from "./EditedFilesCard";
import { TranscriptReadOnly } from "./readOnly";
import { isMarkdownPath } from "./writtenArtifactsModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  setChipHost(undefined);
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

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // The opened card draws each file with the diff renderer (@pierre/diffs), a custom element.
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !saved.has(key)) {
      saved.set(key, scope[key]);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

/// Opens the card's one row, as a reader clicks it: its files stack under it.
async function opened(node: ReactNode): Promise<HTMLElement> {
  const container = await render(node);
  const head = container.querySelector(".acpmux-edited-head")!;
  await act(async () => head.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true })));
  return container;
}

let ids = 0;
const write = (path: string, newText: string, oldText?: string): AcpmuxActivity => {
  const id = `tool-${++ids}`;
  return {
    kind: "tool",
    text: `Edit ${path}`,
    tool: {
      id,
      title: `Edit ${path}`,
      kind: "edit",
      status: "completed",
      locations: [{ path }],
      diffs: [{ path, oldText, newText }],
    },
  };
};
const turn = (items: AcpmuxActivity[]): AcpmuxRow =>
  ({ id: `edits-${++ids}`, version: 1, at: 0, kind: "activity", ended: true, items }) as AcpmuxRow;

const PLAN = "/home/dev/atlas/docs/plan.md";
/// The Open buttons for Markdown files (the opened card also has an Open in Changes per file).
const opens = (container: HTMLElement) => [
  ...container.querySelectorAll<HTMLButtonElement>(".acpmux-review-changes.acpmux-edited-open"),
];
const card = (row: AcpmuxRow) => <EditedFilesCard row={row} onOpenDiff={() => {}} />;

test("Markdown paths are the ones cmux's Markdown page reads", () => {
  for (const path of ["notes.md", "/a/b/README.MD", "doc.markdown", " plan.md "])
    expect(isMarkdownPath(path)).toBe(true);
  for (const path of ["page.html", "page.mdx", "md", "notes.md.bak", "src/md/index.ts", "notes.mdown.txt"])
    expect(isMarkdownPath(path)).toBe(false);
});

test("a card for one Markdown file has Open beside View changes, which opens the file's path", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  setChipHost(async (method, params) => {
    calls.push([method, params]);
    return { ok: true };
  });
  const container = await render(card(turn([write(PLAN, "# Plan\n")])));
  const [open, ...rest] = opens(container);
  expect(rest).toHaveLength(0);
  expect(open?.closest(".acpmux-edited-actions")).not.toBeNull();
  expect(open?.getAttribute("aria-label")).toContain("plan.md");
  await act(async () => open!.click());
  expect(calls).toEqual([["link.openPath", { path: PLAN }]]);
});

test("among several files only the Markdown file has Open, on its name line", async () => {
  const container = await opened(
    card(
      turn([
        write("/home/dev/atlas/src/retry.ts", "export const tries = 3;\n", "export const tries = 1;\n"),
        write(PLAN, "# Plan\n"),
        write("/home/dev/atlas/reports/retries.html", "<!doctype html><title>r</title>\n"),
      ]),
    ),
  );
  const found = opens(container);
  expect(found).toHaveLength(1);
  expect(found[0]!.closest(".cv-edit-diff__header")).not.toBeNull();
  expect(found[0]!.closest(".acpmux-edited-section")?.getAttribute("data-path")).toBe(PLAN);
  expect(container.querySelector(".acpmux-edited-actions .acpmux-edited-open")).toBeNull();
});

test("a Markdown file written twice in a turn is one file with one Open", async () => {
  const container = await opened(
    card(
      turn([
        write(PLAN, "# Plan\n"),
        write(PLAN, "# Plan\n\n## Rollout\n", "# Plan\n"),
        write("/home/dev/atlas/src/retry.ts", "export const tries = 3;\n", "export const tries = 1;\n"),
      ]),
    ),
  );
  expect(opens(container)).toHaveLength(1);
  expect(container.querySelectorAll(`.acpmux-edited-section[data-path="${PLAN}"]`)).toHaveLength(1);
});

test("a Markdown Write with no diff opens from its plain line", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  setChipHost(async (method, params) => {
    calls.push([method, params]);
    return { ok: true };
  });
  const row = turn([
    {
      kind: "tool",
      text: "Write",
      tool: {
        id: "write-plain",
        title: "Write",
        kind: "edit",
        status: "completed",
        inputSummary: JSON.stringify({ file_path: PLAN, content: "# Plan\n" }),
      },
    },
    write("/home/dev/atlas/src/retry.ts", "export const tries = 3;\n", "export const tries = 1;\n"),
  ]);
  const container = await opened(card(row));
  const found = opens(container);
  expect(found).toHaveLength(1);
  // The path is the button's tooltip (ui/Tooltip) and what it opens.
  expect(found[0]!.getAttribute("aria-label")).toContain("plan.md");
  await act(async () => found[0]!.click());
  expect(calls).toEqual([["link.openPath", { path: PLAN }]]);
});

test("a read-only copy of the chat has no Open: the file is on the owner's machine", async () => {
  const container = await render(
    <TranscriptReadOnly.Provider value={true}>{card(turn([write(PLAN, "# Plan\n")]))}</TranscriptReadOnly.Provider>,
  );
  expect(opens(container)).toHaveLength(0);
});
