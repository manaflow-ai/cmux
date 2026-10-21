// l10n-allow-file: test fixture paths and file text, not shipped UI.
// The card that ends a turn which edited one file ("Edited l-setup.txt +9 -0 [View changes]") opens
// its diff right there, and View changes shows that file even when no git diff has it.
//
// Before: a one-file card had no chevron and nothing to click, so its diff showed only through View
// changes; View changes opened the chat folder's git diff beside the chat, which holds no file
// outside the folder (a new /tmp/l-setup.txt), and once the turn's checkpoint loaded its git files
// replaced the tool calls' ones, dropping that file from the card's counts and the turn's diff. An
// edit call whose content carried no `diff` item also lost its change, though its input has it.
//
// The three cases: a new file (Write, nothing before it), a file outside the repository, and an
// edited file (Edit with old and new strings). Each opens inline and through View changes.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { TurnCheckpointLoad } from "../src/agent-session/acpmux/changes/turnCheckpoint";

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
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;

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
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // Pierre's registered elements (the diff card) read their own DOM constructors at import time.
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

const FOLDER = "/Users/you/src/uploader";
const SETUP = "/tmp/l-setup.txt";
const setupText = Array.from({ length: 9 }, (_, index) => `step ${index + 1}`).join("\n") + "\n";

/// One tool call as the pane folds it from its ACP events (direct.ts `mergeToolItem`).
async function toolCall(id: string, events: Record<string, unknown>[]): Promise<AcpmuxActivity> {
  const { mergeToolItem } = await import("../src/agent-session/acpmux/direct");
  let item: AcpmuxActivity | undefined;
  for (const [index, event] of events.entries()) item = mergeToolItem(item, event, id, "", 1_000 + index);
  return item!;
}

const activity = (id: string, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "activity",
  ended: true,
  items,
});

/// Claude Code's Write of a new file, as in the report: its ACP content is a `diff` with no old
/// text. `fromInput`: the content carries no `diff` item (the call's result is plain text), and only
/// its input names the file and the whole text.
const writeNewFile = (fromInput = false) =>
  toolCall("write-1", [
    {
      title: "Write /tmp/l-setup.txt",
      kind: "edit",
      status: "pending",
      rawInput: { file_path: SETUP, content: setupText },
    },
    {
      status: "completed",
      content: fromInput
        ? [{ type: "content", content: { type: "text", text: "File created" } }]
        : [{ type: "diff", path: SETUP, oldText: null, newText: setupText }],
    },
  ]);

/// Claude Code's Edit inside the chat folder, with only `old_string` and `new_string` in its input.
const editInFolder = () =>
  toolCall("edit-1", [
    {
      title: "Edit upload.sh",
      kind: "edit",
      status: "pending",
      rawInput: { file_path: `${FOLDER}/upload.sh`, old_string: "attempt=0\n", new_string: "attempt=1\n" },
    },
    { status: "completed", content: [{ type: "content", content: { type: "text", text: "Updated" } }] },
  ]);

/// An edit to a file outside any repository, with the ACP `diff` content Claude Code sends.
const editOutside = () =>
  toolCall("edit-2", [
    {
      title: "Edit /etc/hosts.local",
      kind: "edit",
      status: "completed",
      content: [{ type: "diff", path: "/etc/hosts.local", oldText: "a\nb\n", newText: "a\nb\nc\n" }],
    },
  ]);

/// The turn's checkpoint, loaded: the chat folder's repository, where the turn changed nothing.
const emptyCheckpoint: TurnCheckpointLoad = {
  state: "loaded",
  checkpointId: "checkpoint-1",
  changeSet: { scope: "lastTurn", root: FOLDER, files: [] },
};

async function renderCard(row: AcpmuxRow, load?: TurnCheckpointLoad) {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const { TurnCountsContext } = await import("../src/agent-session/acpmux/changes/TurnCountsContext");
  const { turnCounts } = await import("../src/agent-session/acpmux/changes/turnCheckpoint");
  const opened: { rowId: string; path?: string }[] = [];
  const card: ReactNode = <EditedFilesCard row={row} onOpenDiff={(rowId, path) => opened.push({ rowId, path })} />;
  root = createRoot(host);
  await act(async () =>
    root!.render(
      load ? (
        <TurnCountsContext.Provider value={(_rowId, files) => turnCounts(files, load)}>
          {card}
        </TurnCountsContext.Provider>
      ) : (
        card
      ),
    ),
  );
  return opened;
}

const text = (selector: string) => host.querySelector(selector)?.textContent ?? undefined;
const inlineDiff = () => {
  const diff = host.querySelector(".acpmux-edited .cv-edit-diff");
  return diff
    ? {
        name: diff.querySelector(".cv-edit-diff__name")?.textContent,
        added: diff.querySelector(".cv-edit-diff__add")?.textContent,
        removed: diff.querySelector(".cv-edit-diff__del")?.textContent,
      }
    : undefined;
};
const click = (element: Element | null) =>
  act(async () => {
    element!.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  });

/// The files the turn's own diff (the in-place View changes) shows for `rows`, with the checkpoint.
async function viewedFiles(rows: AcpmuxRow[], load: TurnCheckpointLoad) {
  const { turnFiles } = await import("../src/agent-session/acpmux/diff");
  const { turnDisplay } = await import("../src/agent-session/acpmux/changes/turnCheckpoint");
  const { translatorFor } = await import("../src/agent-session/acpmux/i18n");
  return turnDisplay(translatorFor("en"), turnFiles(rows), load, false).files.map((file) => ({
    path: file.path,
    additions: file.additions,
    deletions: file.deletions,
    lines: file.edits.flatMap((edit) => edit.hunks.flatMap((hunk) => hunk.lines.map((line) => line.type))),
  }));
}

async function opensIn(rows: AcpmuxRow[], rowId: string, folder: string | undefined) {
  const { viewChangesBeside } = await import("../src/agent-session/acpmux/turnChanges/viewChanges");
  return viewChangesBeside(rows, rowId, folder) ? "beside" : "in place";
}

test.each([
  ["with a diff in its content", false],
  ["with only its input", true],
])("a new file (Write, nothing before it) %s opens inline as all added lines", async (_shape, fromInput) => {
  const row = activity(`turn-1-${fromInput}`, [await writeNewFile(fromInput)]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited l-setup.txt");
  expect(text(".acpmux-edited-sub")).toBe("+9-0");
  const chevron = host.querySelector(".acpmux-edited-toggle");
  expect(chevron?.getAttribute("aria-expanded")).toBe("false");
  expect(inlineDiff()).toBeUndefined();
  await click(chevron);
  expect(chevron?.getAttribute("aria-expanded")).toBe("true");
  expect(inlineDiff()).toEqual({ name: "l-setup.txt", added: "+9", removed: "-0" });
  // The card's title closes it again.
  await click(host.querySelector(".acpmux-edited-title"));
  expect(inlineDiff()).toBeUndefined();
});

test("a new file's View changes opens the turn's own diff, all nine lines added", async () => {
  const row = activity("turn-1", [await writeNewFile(true)]);
  const opened = await renderCard(row);
  await click(host.querySelector(".acpmux-review-changes"));
  expect(opened).toEqual([{ rowId: "turn-1", path: SETUP }]);
  // The chat folder's git diff beside the chat has no /tmp file: the turn's diff opens in place.
  expect(await opensIn([row], "turn-1", FOLDER)).toBe("in place");
  expect(await viewedFiles([row], emptyCheckpoint)).toEqual([
    { path: SETUP, additions: 9, deletions: 0, lines: Array(9).fill("add") },
  ]);
});

test("a file outside the repository keeps its counts and opens inline once the checkpoint loads", async () => {
  const row = activity("turn-2", [await editOutside()]);
  await renderCard(row, emptyCheckpoint);
  expect(text(".acpmux-edited-title > div")).toBe("Edited hosts.local");
  expect(text(".acpmux-edited-sub")).toBe("+1-0");
  await click(host.querySelector(".acpmux-edited-toggle"));
  expect(inlineDiff()).toEqual({ name: "hosts.local", added: "+1", removed: "-0" });
});

test("a file outside the repository opens through View changes with its tool-call diff", async () => {
  const row = activity("turn-2", [await editOutside()]);
  const opened = await renderCard(row, emptyCheckpoint);
  await click(host.querySelector(".acpmux-review-changes"));
  expect(opened).toEqual([{ rowId: "turn-2", path: "/etc/hosts.local" }]);
  expect(await opensIn([row], "turn-2", FOLDER)).toBe("in place");
  expect(await viewedFiles([row], emptyCheckpoint)).toEqual([
    { path: "/etc/hosts.local", additions: 1, deletions: 0, lines: ["context", "context", "add"] },
  ]);
});

test("an edited file (Edit with old and new strings) opens inline with its removed and added line", async () => {
  const row = activity("turn-3", [await editInFolder()]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited upload.sh");
  expect(text(".acpmux-edited-sub")).toBe("+1-1");
  // Its input holds only the strings, not the whole file: Undo is not offered from them.
  expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
  await click(host.querySelector(".acpmux-edited-title"));
  expect(inlineDiff()).toEqual({ name: "upload.sh", added: "+1", removed: "-1" });
});

test("an edited file in the chat folder opens through View changes beside the chat", async () => {
  const row = activity("turn-3", [await editInFolder()]);
  const opened = await renderCard(row);
  await click(host.querySelector(".acpmux-review-changes"));
  expect(opened).toEqual([{ rowId: "turn-3", path: `${FOLDER}/upload.sh` }]);
  // The folder's git diff holds it, as before; with no local folder the turn's diff opens in place.
  expect(await opensIn([row], "turn-3", FOLDER)).toBe("beside");
  expect(await opensIn([row], "turn-3", undefined)).toBe("in place");
  // Without a checkpoint, the in-place view is the tool call's change.
  expect(await viewedFiles([row], { state: "unsupported" })).toEqual([
    { path: `${FOLDER}/upload.sh`, additions: 1, deletions: 1, lines: ["del", "add"] },
  ]);
});
