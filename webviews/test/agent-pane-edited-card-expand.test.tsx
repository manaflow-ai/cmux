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
// edited file (Edit with old and new strings, and MultiEdit). Each opens inline and through View
// changes. A Write over an existing file has no old text, so it lists its path without counts rather
// than reading as a new file; and a chat folder that is not a repository opens the turn's own diff,
// since the folder's git diff beside the chat has nothing to show. So does a Write acpmux sends as a
// fragment with no old text (its result never said it created the file): it lists without counts,
// chevron or Undo, until a confirmed create makes it a new file.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
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
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;
// The first card imports the pane's modules and Pierre's diff chunk, which takes seconds cold.
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
    // jsdom has no layout; the inline diff's lines (Pierre) watch their size.
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
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
const result = (text: string) => [{ type: "content", content: { type: "text", text } }];

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
/// text. `fromInput`: the content carries no `diff` item, only Claude Code's result saying it created
/// the file, and the input names the file and the whole text.
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
        ? result(`File created successfully at: ${SETUP}`)
        : [{ type: "diff", path: SETUP, oldText: null, newText: setupText }],
    },
  ]);

/// Claude Code's Write over a file that was there: its result says it updated the file, and the call
/// holds no old text.
const NOTES = `${FOLDER}/notes.txt`;
const writeOverFile = () =>
  toolCall("write-2", [
    { title: "Write notes.txt", kind: "edit", status: "pending", rawInput: { file_path: NOTES, content: "new\n" } },
    { status: "completed", content: result(`The file ${NOTES} has been updated. Here's the result:`) },
  ]);

/// Claude Code's Write as the acpmux translator sends it (claude_stdio `edit_diffs`): the whole new
/// text with no old text, marked a fragment until the result says what the Write did. `settled`: the
/// result confirmed a create, so the mark is gone (`settle_write`); else the result said the file was
/// updated and held no old text, so the mark stays and the old contents are unknown.
const translatorWrite = (id: string, path: string, settled: boolean) => {
  const fragment = { type: "diff", path, oldText: null, newText: setupText, _meta: { acpmux: { fragment: true } } };
  return toolCall(id, [
    {
      title: `Write ${path.split("/").pop()}`,
      kind: "edit",
      status: "pending",
      rawInput: { file_path: path, content: setupText },
      content: [fragment],
      locations: [{ path }],
    },
    {
      status: "completed",
      content: [settled ? { type: "diff", path, oldText: null, newText: setupText } : fragment],
    },
  ]);
};

/// Claude Code's Edit inside the chat folder, with only `old_string` and `new_string` in its input.
const editInFolder = () =>
  toolCall("edit-1", [
    {
      title: "Edit upload.sh",
      kind: "edit",
      status: "pending",
      rawInput: { file_path: `${FOLDER}/upload.sh`, old_string: "attempt=0\n", new_string: "attempt=1\n" },
    },
    { status: "completed", content: result("Updated") },
  ]);

/// Claude Code's MultiEdit: named as its block starts with part of its input, then the whole input,
/// which replaces the diffs the first one gave.
const CONFIG = `${FOLDER}/config.sh`;
const multiEdit = () =>
  toolCall("multi-1", [
    {
      title: "MultiEdit config.sh",
      kind: "edit",
      status: "pending",
      rawInput: { file_path: CONFIG, edits: [{ old_string: "a=1\n", new_string: "a=9\n" }] },
    },
    {
      status: "in_progress",
      rawInput: {
        file_path: CONFIG,
        edits: [
          { old_string: "a=1\n", new_string: "a=2\n" },
          { old_string: "b=1\n", new_string: "b=2\nc=3\n" },
        ],
      },
    },
    // Ends with no content, so nothing but the input says what changed.
    { status: "completed" },
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

/// The host's `git.status` for a folder in the repository at `root`, and for a folder in none.
const inRepository = (root: string) => async () => ({ root, ahead: 0, behind: 0, detached: false });
const notARepository = async (): Promise<unknown> => {
  throw new Error("not a git repository");
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
        <TurnCountsContext.Provider value={(_rowId, files, pathsOnly) => turnCounts(files, load, pathsOnly)}>
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
  const { turnFiles, turnPathsOnly } = await import("../src/agent-session/acpmux/diff");
  const { turnDisplay } = await import("../src/agent-session/acpmux/changes/turnCheckpoint");
  const { translatorFor } = await import("../src/agent-session/acpmux/i18n");
  return turnDisplay(translatorFor("en"), turnFiles(rows), load, false, turnPathsOnly(rows)).files.map((file) => ({
    path: file.path,
    created: file.created,
    additions: file.additions,
    deletions: file.deletions,
    lines: file.edits.flatMap((edit) => edit.hunks.flatMap((hunk) => hunk.lines.map((line) => line.type))),
  }));
}

/// Where View changes opens for the chat folder `folder`, whose `git.status` `readStatus` answers.
async function opensIn(
  rows: AcpmuxRow[],
  rowId: string,
  folder: string | undefined,
  readStatus: (cwd: string) => Promise<unknown> = inRepository(FOLDER),
) {
  const { repositoryRoot, viewChangesBeside } = await import("../src/agent-session/acpmux/turnChanges/viewChanges");
  const root = folder ? await repositoryRoot(folder, readStatus) : undefined;
  return viewChangesBeside(rows, rowId, root) ? "beside" : "in place";
}

test.each([
  ["with a diff in its content", false],
  ["with only its input", true],
])("a new file (Write, nothing before it) %s opens inline as all added lines", async (_shape, fromInput) => {
  const row = activity(`turn-1-${fromInput}`, [await writeNewFile(fromInput)]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited l-setup.txt");
  expect(text(".acpmux-edited-sub")).toBe("+9-0");
  // Built from the input, the page never saw the file on disk: Undo is not offered from it.
  if (fromInput) expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
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
  // Read from the input, it is a fragment: never marked as a new file, though every line is added.
  expect(await viewedFiles([row], emptyCheckpoint)).toEqual([
    { path: SETUP, created: false, additions: 9, deletions: 0, lines: Array(9).fill("add") },
  ]);
});

test("a Write over an existing file lists its path without counts, not as a new file", async () => {
  const row = activity("turn-4", [await writeOverFile()]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited 1 file");
  expect(host.querySelector(".acpmux-edited .acpmux-diff-add")).toBeNull();
  expect(host.querySelector(".acpmux-edited-path")?.getAttribute("data-path")).toBe(NOTES);
  // Nothing to diff: no View changes and no inline diff.
  expect(host.querySelector(".acpmux-review-changes")).toBeNull();
  expect(host.querySelector(".acpmux-edited-toggle")).toBeNull();
  expect(await viewedFiles([row], { state: "unsupported" })).toEqual([]);
});

test("a Write whose old contents never came lists its path without counts, chevron or Undo", async () => {
  const row = activity("turn-8", [await translatorWrite("write-3", NOTES, false)]);
  await renderCard(row);
  // Not "+9 -0": the file was there, and what it held is unknown.
  expect(text(".acpmux-edited-title > div")).toBe("Edited 1 file");
  expect(host.querySelector(".acpmux-edited .acpmux-diff-add")).toBeNull();
  expect(host.querySelector(".acpmux-edited-path")?.getAttribute("data-path")).toBe(NOTES);
  expect(host.querySelector(".acpmux-edited-toggle")).toBeNull();
  expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
  expect(host.querySelector(".acpmux-review-changes")).toBeNull();
  // The turn's own diff has nothing to show for it.
  expect(await viewedFiles([row], { state: "unsupported" })).toEqual([]);
});

test("beside a Write of unknown old contents, a fragment Edit keeps its counts", async () => {
  const row = activity("turn-9", [
    await translatorWrite("write-4", NOTES, false),
    await toolCall("edit-4", [
      {
        title: "Edit Cargo.toml",
        kind: "edit",
        status: "completed",
        content: [
          {
            type: "diff",
            path: `${FOLDER}/Cargo.toml`,
            oldText: 'version = "1.2.0"\n',
            newText: 'version = "1.3.0"\n',
            _meta: { acpmux: { fragment: true } },
          },
        ],
      },
    ]),
  ]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited 2 files");
  expect(text(".acpmux-edited-sub")).toBe("+1-1");
  const rows = [...host.querySelectorAll(".acpmux-edited-file")].map((entry) => [
    entry.querySelector(".acpmux-edited-path")?.getAttribute("data-path"),
    entry.querySelector(".acpmux-diff-counts")?.textContent,
  ]);
  expect(rows).toEqual([
    [`${FOLDER}/Cargo.toml`, "+1-1"],
    [NOTES, undefined],
  ]);
  expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
});

test("an Edit to a file a Write rewrote with unknown old contents lists without counts too", async () => {
  // The Write replaced the whole file: what the turn changed in it is unknown, whatever the Edit says.
  const row = activity("turn-12", [
    await translatorWrite("write-7", NOTES, false),
    await toolCall("edit-5", [
      {
        title: "Edit notes.txt",
        kind: "edit",
        status: "completed",
        content: [{ type: "diff", path: NOTES, oldText: "step 1\n", newText: "step one\n" }],
      },
    ]),
  ]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited 1 file");
  expect(host.querySelector(".acpmux-edited .acpmux-diff-add")).toBeNull();
  expect(host.querySelector(".acpmux-edited-path")?.getAttribute("data-path")).toBe(NOTES);
  expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
});

test("a Write of unknown old contents in the repository takes the checkpoint's counts once it loads", async () => {
  const row = activity("turn-13", [await translatorWrite("write-8", NOTES, false)]);
  const checkpoint: TurnCheckpointLoad = {
    state: "loaded",
    checkpointId: "checkpoint-3",
    changeSet: {
      scope: "lastTurn",
      root: FOLDER,
      files: [
        { path: "notes.txt", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new\n" },
      ],
    },
  };
  await renderCard(row, checkpoint);
  // The checkpoint read the file before and after: its counts, listed once, and the Write's change
  // (not one made outside the tool calls).
  expect(text(".acpmux-edited-title > div")).toBe("Edited notes.txt");
  expect(text(".acpmux-edited-sub")).toBe("+1-1");
  expect(host.querySelectorAll(".acpmux-edited-file")).toHaveLength(0);
  expect((await viewedFiles([row], checkpoint)).map((file) => [file.path, file.additions])).toEqual([[NOTES, 1]]);
});

test("a Write of unknown old contents outside the repository still lists once the checkpoint loads", async () => {
  const row = activity("turn-10", [await translatorWrite("write-5", SETUP, false)]);
  await renderCard(row, emptyCheckpoint);
  expect(text(".acpmux-edited-title > div")).toBe("Edited 1 file");
  expect(host.querySelector(".acpmux-edited .acpmux-diff-add")).toBeNull();
  expect(host.querySelector(".acpmux-edited-path")?.getAttribute("data-path")).toBe(SETUP);
  expect(await viewedFiles([row], emptyCheckpoint)).toEqual([]);
});

test("the same Write once its result confirmed a create is a new file, all lines added", async () => {
  const row = activity("turn-11", [await translatorWrite("write-6", SETUP, true)]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited l-setup.txt");
  expect(text(".acpmux-edited-sub")).toBe("+9-0");
  // Undo may move the new file to the Trash.
  expect(host.querySelector(".acpmux-edited-undo")).not.toBeNull();
  await click(host.querySelector(".acpmux-edited-toggle"));
  expect(inlineDiff()).toEqual({ name: "l-setup.txt", added: "+9", removed: "-0" });
  expect(await viewedFiles([row], { state: "unsupported" })).toEqual([
    { path: SETUP, created: true, additions: 9, deletions: 0, lines: Array(9).fill("add") },
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
    {
      path: "/etc/hosts.local",
      created: false,
      additions: 1,
      deletions: 0,
      lines: ["context", "context", "add"],
    },
  ]);
});

test("a file the checkpoint holds under another path for the same folder lists once", async () => {
  // The repository is /private/tmp/proj; the agent wrote /tmp/proj/notes.txt, the same file.
  const row = activity("turn-5", [
    await toolCall("edit-3", [
      {
        title: "Edit notes.txt",
        kind: "edit",
        status: "completed",
        content: [{ type: "diff", path: "/tmp/proj/notes.txt", oldText: "a\nb\n", newText: "a\nb\nc\n" }],
      },
    ]),
  ]);
  const checkpoint: TurnCheckpointLoad = {
    state: "loaded",
    checkpointId: "checkpoint-2",
    changeSet: {
      scope: "lastTurn",
      root: "/private/tmp/proj",
      files: [
        { path: "notes.txt", status: "modified", additions: 1, deletions: 0, patch: "@@ -1,2 +1,3 @@\n a\n b\n+c\n" },
      ],
    },
  };
  expect((await viewedFiles([row], checkpoint)).map((file) => [file.path, file.additions])).toEqual([
    ["/private/tmp/proj/notes.txt", 1],
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
  // A chat in a subfolder of the repository still has its files in the repository's diff.
  expect(await opensIn([row], "turn-3", `${FOLDER}/scripts`, inRepository(FOLDER))).toBe("beside");
  // Without a checkpoint, the in-place view is the tool call's change.
  expect(await viewedFiles([row], { state: "unsupported" })).toEqual([
    { path: `${FOLDER}/upload.sh`, created: false, additions: 1, deletions: 1, lines: ["del", "add"] },
  ]);
});

test("a chat folder that is not a repository opens the turn's own diff, even for a file inside it", async () => {
  const row = activity("turn-6", [await editInFolder()]);
  const opened = await renderCard(row);
  await click(host.querySelector(".acpmux-review-changes"));
  expect(opened).toEqual([{ rowId: "turn-6", path: `${FOLDER}/upload.sh` }]);
  // git.status fails for the folder: the viewer beside the chat would only ask for a repository.
  expect(await opensIn([row], "turn-6", FOLDER, notARepository)).toBe("in place");
  // A reply without a repository root reads the same way.
  expect(await opensIn([row], "turn-6", FOLDER, async () => ({}))).toBe("in place");
});

test("a MultiEdit opens inline with every edit from its latest input", async () => {
  const row = activity("turn-7", [await multiEdit()]);
  await renderCard(row);
  expect(text(".acpmux-edited-title > div")).toBe("Edited config.sh");
  // The whole input replaced the partial one ("a=9" is gone): +3 -2.
  expect(text(".acpmux-edited-sub")).toBe("+3-2");
  expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
  await click(host.querySelector(".acpmux-edited-toggle"));
  expect(inlineDiff()).toEqual({ name: "config.sh", added: "+3", removed: "-2" });
  expect(await viewedFiles([row], { state: "unsupported" })).toEqual([
    { path: CONFIG, created: false, additions: 3, deletions: 2, lines: ["del", "add", "del", "add", "add"] },
  ]);
});

// The card draws outside ToolRows, under the transcript-wide Find reveal: only the card that holds
// Find's current match opens its cut diff, not every open card whose diff has the query's text.
test.each([
  ["another row's match leaves this card's diff cut", false, "cut"],
  ["its own match opens it past the cut", true, "all"],
])("Find in Chat: %s", async (_case, own, preview) => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  // Each case its own row: a card's open state outlives its render (turnChanges/openStore).
  const row = activity(own ? "turn-find-own" : "turn-find-other", [await writeNewFile()]);
  const find = { rowId: own ? row.id : "turn-elsewhere", card: true, needle: "step 9", repaint: () => {} };
  root = createRoot(host);
  // Opened before Find reveals anything.
  await act(async () => root!.render(<EditedFilesCard row={row} />));
  await click(host.querySelector(".acpmux-edited-toggle"));
  const body = () => host.querySelector(".acpmux-edited .cv-edit-diff__body")?.getAttribute("data-preview");
  expect(body()).toBe("cut");
  await act(async () =>
    root!.render(
      <FindReveal.Provider value={find}>
        <EditedFilesCard row={row} />
      </FindReveal.Provider>,
    ),
  );
  expect(body()).toBe(preview);
});
