// l10n-allow-file: test fixture paths and file text, not shipped UI.
// Shared by test/agent-pane-unknown-write-*.test.*: Claude Code's Write as the acpmux translator
// sends it (claude_stdio `edit_diffs`), an Edit with its diff, a turn's activity row, and a DOM to
// draw one edited-files card or transcript row in.
import { afterAll, afterEach, beforeAll, setDefaultTimeout } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";
import type { TurnCheckpointLoad } from "../../src/agent-session/acpmux/changes/turnCheckpoint";

export const FOLDER = "/Users/you/src/uploader";
export const NOTES = `${FOLDER}/notes.txt`;
export const PLAN = `${FOLDER}/plan.md`;
export const CARGO = `${FOLDER}/Cargo.toml`;
export const SETUP = "/tmp/l-setup.txt";
export const setupText = Array.from({ length: 9 }, (_, index) => `step ${index + 1}`).join("\n") + "\n";

/// One tool call as the pane folds it from its ACP events (direct.ts `mergeToolItem`).
export async function toolCall(id: string, events: Record<string, unknown>[]): Promise<AcpmuxActivity> {
  const { mergeToolItem } = await import("../../src/agent-session/acpmux/direct");
  let item: AcpmuxActivity | undefined;
  for (const [index, event] of events.entries()) item = mergeToolItem(item, event, id, "", 1_000 + index);
  return item!;
}

/// A Write as the translator sends it: the whole new text with no old text, marked a fragment until
/// the result says what the Write did. `updated`: the result said the file was updated and held no
/// old text, so the mark stays and the old contents are unknown. `created`: the result confirmed a
/// create, so the mark is gone (`settle_write`). `failed`: the call failed and its last update
/// carried no content, so the pending fragment is all the call has. `canonical`: the path acpmux
/// recorded beside the agent's (hub `path_canon`), on the diff, the location and the input.
export const translatorWrite = (
  id: string,
  path: string,
  outcome: "updated" | "created" | "failed",
  canonical?: string,
) => {
  const named = canonical === undefined ? {} : { canonicalPath: canonical };
  const fragment = {
    type: "diff",
    path,
    oldText: null,
    newText: setupText,
    _meta: { acpmux: { fragment: true, ...named } },
  };
  const created = { type: "diff", path, oldText: null, newText: setupText, ...canonicalMeta(canonical) };
  return toolCall(id, [
    {
      title: `Write ${path.split("/").pop()}`,
      kind: "edit",
      status: "pending",
      rawInput: { file_path: path, content: setupText },
      content: [fragment],
      locations: [{ path, ...canonicalMeta(canonical) }],
      ...canonicalMeta(canonical),
    },
    outcome === "failed"
      ? { status: "failed" }
      : { status: "completed", content: [outcome === "created" ? created : fragment] },
  ]);
};

/// An Edit whose content carries its diff, old text and new; `canonical` as for `translatorWrite`.
export const editWithDiff = (id: string, path: string, oldText: string, newText: string, canonical?: string) =>
  toolCall(id, [
    {
      title: `Edit ${path.split("/").pop()}`,
      kind: "edit",
      status: "completed",
      content: [{ type: "diff", path, oldText, newText, ...canonicalMeta(canonical) }],
      ...(canonical === undefined ? {} : { locations: [{ path, ...canonicalMeta(canonical) }] }),
    },
  ]);

/// acpmux's `_meta.acpmux.canonicalPath` for `canonical`, or nothing.
const canonicalMeta = (canonical: string | undefined) =>
  canonical === undefined ? {} : { _meta: { acpmux: { canonicalPath: canonical } } };

export const activity = (id: string, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "activity",
  ended: true,
  items,
});

/// A DOM for one test file: `host()` is the element each render draws in; `render` mounts there and
/// is unmounted after each test.
export function useDom() {
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "customElements",
    "MutationObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  const added: string[] = [];
  let root: Root | undefined;
  let host: HTMLElement | undefined;
  // The first render imports the pane's modules, which takes seconds cold.
  setDefaultTimeout(30_000);

  beforeAll(() => {
    const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
    Object.assign(scope, {
      window,
      document: window.document,
      navigator: window.navigator,
      HTMLElement: window.HTMLElement,
      Element: window.Element,
      Node: window.Node,
      customElements: window.customElements,
      MutationObserver: window.MutationObserver,
      ResizeObserver: class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
      requestAnimationFrame: window.requestAnimationFrame.bind(window),
      cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
      IS_REACT_ACT_ENVIRONMENT: true,
    });
    for (const key of Object.getOwnPropertyNames(window))
      if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
        added.push(key);
        scope[key] = (window as unknown as Record<string, unknown>)[key];
      }
    host = window.document.getElementById("root")!;
  });

  afterEach(() => {
    act(() => root?.unmount());
    root = undefined;
  });

  afterAll(() => {
    for (const key of added) delete scope[key];
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });

  return {
    host: () => host!,
    async render(node: ReactNode) {
      const { createRoot } = await import("react-dom/client");
      root = createRoot(host!);
      await act(async () => root!.render(node));
    },
    text: (selector: string) => host!.querySelector(selector)?.textContent ?? undefined,
    click: (element: Element | null) =>
      act(async () => {
        element!.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      }),
  };
}

/// The turn's checkpoint, loaded: the repository at `root` (FOLDER), with `files` (paths from the
/// root) changed.
export const checkpoint = (
  files: { path: string; additions: number; deletions: number; patch: string }[] = [],
  root = FOLDER,
): TurnCheckpointLoad => ({
  state: "loaded",
  checkpointId: "checkpoint-1",
  changeSet: {
    scope: "lastTurn",
    root,
    files: files.map((file) => ({ ...file, status: "modified" as const })),
  },
});

/// The edited-files card for `row`, as the transcript draws it at the end of its turn; with `load`,
/// once the turn's checkpoint has loaded (App.tsx `turnCountsFor`).
export async function editedCard(row: AcpmuxRow, load?: TurnCheckpointLoad): Promise<ReactNode> {
  const { EditedFilesCard } = await import("../../src/agent-session/acpmux/conversation/EditedFilesCard");
  const { TurnCountsContext } = await import("../../src/agent-session/acpmux/changes/TurnCountsContext");
  const { turnCounts } = await import("../../src/agent-session/acpmux/changes/turnCheckpoint");
  const card = <EditedFilesCard row={row} onOpenDiff={() => {}} />;
  if (!load) return card;
  return (
    <TurnCountsContext.Provider value={(_rowId, files, pathsOnly) => turnCounts(files, load, pathsOnly)}>
      {card}
    </TurnCountsContext.Provider>
  );
}
