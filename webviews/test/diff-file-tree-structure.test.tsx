// The diff tab's files tree with a diff whose files arrive out of folder order (user report, Nov 4:
// "lots of buggy stuff here"). The stream lists tracked edits first and new files after them, so
// `src/server/Mcp.ts` came before `src/worker.ts` and `src/server/machines/E2b.ts` after it. The tree
// was built from that order as if it were sorted: `src/server/` showed twice (once as "src / server",
// a second, flattened chain), each copy at its own depth, and a click on either copy lit both. A
// folder clicked to collapse it also kept the selection highlight. Each folder must show once, every
// file under it, and a folder click must leave the highlight on the file the viewer shows.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { FileTreeSource } from "../src/diff-stream";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
// The tree is a custom element: it needs the DOM's constructors, not only window and document.
const dom = Object.fromEntries(
  Object.getOwnPropertyNames(window)
    .filter((key) =>
      /^(HTML|SVG|CSS|Mutation|Shadow|Document|Element|Node|Text|Event|Custom|Keyboard|Pointer|Mouse)/.test(key),
    )
    .map((key) => [key, (window as unknown as Record<string, unknown>)[key]]),
);
const globals: Record<string, unknown> = {
  ...dom,
  window,
  document: window.document,
  navigator: window.navigator,
  customElements: window.customElements,
  getComputedStyle: window.getComputedStyle.bind(window),
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  Object.assign(scope, globals);
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

// The user's diff, in the order the stream sends it: tracked edits, then the new files.
const STREAM_ORDER = [
  "docs/hosted-mcp.md",
  "llms.txt",
  "src/server/Mcp.ts",
  "src/worker.ts",
  "test/workers/worker.test.ts",
  "src/server/machines/E2b.ts",
  "src/server/mcp/SessionTools.ts",
  "test/fixtures/grants.ts",
  "test/node/sessions.test.ts",
];
const ADDED = new Set(STREAM_ORDER.slice(5));

function treeSource(paths: string[]): FileTreeSource {
  return {
    diffStats: { addedLines: 0, deletedLines: 0, fileCount: paths.length, totalLinesOfCode: 0 },
    gitStatus: paths.filter((path) => ADDED.has(path)).map((path) => ({ path, status: "added" })),
    pathCount: paths.length,
    paths,
    pathToItemId: new Map(paths.map((path) => [path, path])),
    revision: 1,
    statsByPath: new Map(paths.map((path) => [path, { added: 3, deleted: 1 }])),
    treePathByItemId: new Map(paths.map((path) => [path, path])),
  } as unknown as FileTreeSource;
}

const shadow = () => host.querySelector("file-tree-container")!.shadowRoot!;
/** The scrolled list's rows (not the sticky folder overlay): path and depth. */
const rows = () =>
  [...shadow().querySelectorAll<HTMLElement>('[data-type="item"]:not([data-file-tree-sticky-row])')].map(
    (row) => `${row.getAttribute("aria-level")} ${row.dataset.itemPath}`,
  );
const selectedRows = () =>
  [...shadow().querySelectorAll<HTMLElement>('[data-type="item"][data-item-selected="true"]')].map(
    (row) => row.dataset.itemPath,
  );
/** Resolves once `ready()` holds, re-checked on each change under the root (the tree renders late). */
function until(ready: () => boolean): Promise<void> {
  return act(
    () =>
      new Promise<void>((resolve) => {
        const check = () => {
          try {
            return ready();
          } catch {
            return false;
          }
        };
        if (check()) return resolve();
        const observer = new window.MutationObserver(() => {
          if (check()) {
            observer.disconnect();
            resolve();
          }
        });
        observer.observe(window.document.body, { subtree: true, childList: true, attributes: true });
        const shadowRoot = host.querySelector("file-tree-container")?.shadowRoot;
        if (shadowRoot) observer.observe(shadowRoot, { subtree: true, childList: true, attributes: true });
      }),
  );
}

async function renderSidebar(selectedPath: string) {
  const { createRoot } = await import("react-dom/client");
  const { FilesSidebar } = await import("../src/diff-viewer/FilesSidebar");
  const { defaultDiffFileFilter } = await import("../src/file-filter");
  const source = treeSource(STREAM_ORDER);
  const state = {
    fileFilter: defaultDiffFileFilter(),
    fileSearchOpen: false,
    fileSearchRequest: 0,
    filesVisible: true,
    filesWidth: 320,
    items: [],
    status: { loading: false, pending: false, message: "" },
    treeSource: source,
  };
  host = window.document.createElement("div");
  window.document.body.replaceChildren(host);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <FilesSidebar
        commentEntries={[]}
        commentLabels={{} as never}
        dispatch={() => {}}
        hasDraft={false}
        label={(key: string) => key}
        onActivateItem={() => {}}
        onSelectComment={() => {}}
        onSelectItem={() => {}}
        onToggleViewedPath={() => {}}
        selectedPath={selectedPath}
        state={state as never}
        treeSource={source}
        viewedStateOf={() => "not-viewed" as never}
        visibleItemCount={STREAM_ORDER.length}
      />,
    ),
  );
  await until(() => rows().some((row) => row.endsWith(` ${selectedPath}`)));
}

test("each folder shows once, with every changed file under it at its depth", async () => {
  await renderSidebar("docs/hosted-mcp.md");
  expect(rows()).toEqual([
    "1 docs/",
    "2 docs/hosted-mcp.md",
    "1 llms.txt",
    "1 src/",
    "2 src/server/",
    "3 src/server/Mcp.ts",
    "3 src/server/machines/",
    "4 src/server/machines/E2b.ts",
    "3 src/server/mcp/",
    "4 src/server/mcp/SessionTools.ts",
    "2 src/worker.ts",
    "1 test/",
    "2 test/workers/",
    "3 test/workers/worker.test.ts",
    "2 test/fixtures/",
    "3 test/fixtures/grants.ts",
    "2 test/node/",
    "3 test/node/sessions.test.ts",
  ]);
  act(() => root?.unmount());
  root = undefined;
});

test("a folder click toggles the folder and leaves the highlight on the file in view", async () => {
  await renderSidebar("src/worker.ts");
  expect(selectedRows()).toEqual(["src/worker.ts"]);
  const folder = shadow().querySelector<HTMLElement>(
    '[data-type="item"][data-item-path="src/server/"]:not([data-file-tree-sticky-row])',
  )!;
  await act(async () => folder.click());
  await until(() => !rows().includes("3 src/server/Mcp.ts"));
  // The folder collapsed (its files left the list) and kept no highlight of its own.
  expect(rows()).not.toContain("3 src/server/Mcp.ts");
  expect(selectedRows()).toEqual(["src/worker.ts"]);
  act(() => root?.unmount());
  root = undefined;
});

test("the changes view's tree also leaves the highlight on the shown file after a folder click", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChangedFilesTree } = await import("../src/agent-session/acpmux/changes/ChangedFilesTree");
  const files = STREAM_ORDER.map((displayPath) => ({
    path: `/repo/${displayPath}`,
    displayPath,
    edits: [],
    additions: 3,
    deletions: 1,
  }));
  host = window.document.createElement("div");
  window.document.body.replaceChildren(host);
  root = createRoot(host);
  await act(async () =>
    root!.render(<ChangedFilesTree files={files as never} selected="/repo/src/worker.ts" onSelect={() => {}} />),
  );
  await until(() => rows().some((row) => row.endsWith(" src/worker.ts")));
  expect(selectedRows()).toEqual(["src/worker.ts"]);
  const folder = shadow().querySelector<HTMLElement>(
    '[data-type="item"][data-item-path="src/server/"]:not([data-file-tree-sticky-row])',
  )!;
  await act(async () => folder.click());
  await until(() => !rows().includes("3 src/server/Mcp.ts"));
  expect(rows()).not.toContain("3 src/server/Mcp.ts");
  expect(selectedRows()).toEqual(["src/worker.ts"]);
  act(() => root?.unmount());
  root = undefined;
});
