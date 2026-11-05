// l10n-allow-file: test fixture paths, not shipped UI.
// Changes opens as a tab on the chat's right, never over the chat (Leo, 2026-11-03: "the diff
// thing/changes viewer still doesn't open up on the right pane? why? just put it in a tab??? i've
// asked for days..."). Before, a Cloud or remote chat, a folder in no repository and a turn that
// wrote a file outside the repository all opened the page's own changes view over the chat, and no
// message reached the App. Now a remote chat's folder diff opens on its machine, and the others send
// the turn's own patch for a diff tab beside the chat.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { parsePatchFiles } from "@pierre/diffs";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { patchName, viewChangesFiles, viewChangesPatch } from "../src/agent-session/acpmux/turnChanges/viewChanges";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, kind, version: 1, at: (at += 1_000), ...extra }) as AcpmuxRow;
const edit = (id: string, path: string, oldText: string | null, newText: string, line?: number) => ({
  tool: {
    id,
    kind: "edit",
    status: "completed",
    title: `Edit ${path}`,
    diffs: [{ path, oldText, newText, ...(line === undefined ? {} : { line }) }],
  },
});
const FOLDER = "/Users/me/notes";
const chat = (): AcpmuxRow[] => [
  row("u1", "user", { text: "Set it up" }),
  row("a1", "activity", {
    items: [
      edit("t1", `${FOLDER}/todo.md`, "one\ntwo\n", "one\n2\n", 1),
      edit("t2", "/tmp/l-setup.txt", null, "hello\nworld\n"),
      edit("t3", `${FOLDER}/todo.md`, "one\n", "1\n", 1),
    ],
  } as Partial<AcpmuxRow>),
  row("s1", "turnSummary", { status: "completed" }),
];

const files = (text: string) => parsePatchFiles(text).flatMap((patch) => patch.files ?? []);

test("the turn's patch holds every edit, named from the chat's folder or by full path", () => {
  const patch = viewChangesPatch(chat(), "a1", undefined, FOLDER);
  expect(patch?.text.startsWith("diff --git ")).toBe(true);
  const parsed = files(patch!.text);
  // One section per edit: two edits of todo.md count lines from different versions of it.
  expect(parsed.map((file) => file.name)).toEqual(["todo.md", "todo.md", "/tmp/l-setup.txt"]);
  expect(patch?.file).toBeUndefined();
});

test("an edited-files row's file is the one the tab scrolls to", () => {
  expect(viewChangesPatch(chat(), "a1", "/tmp/l-setup.txt", FOLDER)?.file).toBe("/tmp/l-setup.txt");
  expect(viewChangesPatch(chat(), "a1", `${FOLDER}/todo.md`, FOLDER)?.file).toBe("todo.md");
});

test("a turn that changed nothing sends no patch", () => {
  const rows = [
    row("u", "user", { text: "hi" }),
    row("a", "activity"),
    row("s", "turnSummary", { status: "completed" }),
  ];
  expect(viewChangesPatch(rows, "a", undefined, FOLDER)).toBeUndefined();
});

test("a patch names a file from the chat folder only when it is under it", () => {
  expect(patchName("/Users/me/notes/a/b.md", "/Users/me/notes/")).toBe("a/b.md");
  expect(patchName("/Users/me/notesbook/x", "/Users/me/notes")).toBe("/Users/me/notesbook/x");
  expect(patchName("~/x", "/Users/me")).toBe("~/x");
  expect(patchName("src/a.ts", undefined)).toBe("src/a.ts");
});

test("the chat opens Changes as a tab for remote chats and non-repository turns; Quick Chat opens in the window", () => {
  const app = readFileSync(new URL("../src/agent-session/acpmux/App.tsx", import.meta.url), "utf8");
  const beside = app.slice(app.indexOf("diffBeside.current = async"), app.indexOf("diffBeside.current = async") + 2400);
  // A remote or Cloud chat's folder is read on its machine. Quick Chat has no tab beside it: its
  // chat moves to the main window (Open in Window), where the diff opens on the right.
  expect(beside).toMatch(/if \(quick\) \{\s+if \(snapshot\.sessionId\) postOpenInWindow\(snapshot\.sessionId\);/);
  expect(beside).toContain("if (!chatCwd) return false;");
  expect(beside).not.toContain("quick || !localCwd");
  // Outside a repository, or a file outside it: the turn's own patch for the tab.
  expect(beside).toMatch(/viewChangesPatch\(rows, rowId, path, chatCwd, files\)[\s\S]*target = \{ patch \}/);
  // A remote chat's turn always opens as its own patch (the page's checkpoint-or-edits choice), so
  // a missing, partial or pruned checkpoint never leaves the tab with less than the page showed.
  expect(beside).toContain("const root = localCwd ? await repositoryRoot(chatCwd, readFolderStatus) : undefined;");
  // The header's Changes in a folder outside a repository asks for the tab first.
  const header = app.slice(app.indexOf("const toggleChanges = "), app.indexOf("const toggleChanges = ") + 900);
  expect(header).toContain("headerChangesInPlace(chatCwd");
  expect(header).toMatch(/diffBeside\.current\(turn\.rowId, undefined, mode\)/);
});

test("a mixed turn keeps the checkpoint's repository changes beside its edit outside the repository", async () => {
  // The turn edited /repo/src/main.ts and wrote /tmp/setup.txt; a formatter also changed
  // /repo/src/fmt.ts, which only the checkpoint holds.
  const rows: AcpmuxRow[] = [
    row("mu", "user", { text: "Go" }),
    row("ma", "activity", {
      items: [edit("m1", "/repo/src/main.ts", "a\n", "b\n", 1), edit("m2", "/tmp/setup.txt", null, "x\n")],
    } as Partial<AcpmuxRow>),
    row("ms", "turnSummary", { status: "completed", checkpoint: { from: "cp-1", to: "cp-2" } }),
  ];
  // The session host's git.checkpoint.diff answer for the pair.
  const diff = async () => ({
    root: "/repo",
    complete: true,
    files: [
      { path: "src/main.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b\n" },
      { path: "src/fmt.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-c\n+d\n" },
    ],
  });
  const files = await viewChangesFiles(rows, "ma", diff);
  const patch = viewChangesPatch(rows, "ma", undefined, "/repo", files);
  expect(
    new Set(
      parsePatchFiles(patch!.text)
        .flatMap((p) => p.files ?? [])
        .map((file) => file.name),
    ),
  ).toEqual(new Set(["src/main.ts", "src/fmt.ts", "/tmp/setup.txt"]));
  // With no checkpoint read, the tool calls' edits still make the patch.
  const fallback = await viewChangesFiles(rows, "ma", () => Promise.reject(new Error("offline")));
  expect(viewChangesPatch(rows, "ma", undefined, "/repo", fallback)?.text).toContain("/tmp/setup.txt");
});

test("a binary or empty file the turn changed still lists, by its git header", async () => {
  const rows: AcpmuxRow[] = [
    row("bu", "user", { text: "Go" }),
    row("ba", "activity", { items: [edit("b1", "/tmp/setup.txt", null, "x\n")] } as Partial<AcpmuxRow>),
    row("bs", "turnSummary", { status: "completed", checkpoint: { from: "cp-1", to: "cp-2" } }),
  ];
  const diff = async () => ({
    root: "/repo",
    complete: true,
    files: [
      { path: "logo.png", status: "modified", binary: true },
      { path: "empty.txt", status: "added" },
    ],
  });
  const files = await viewChangesFiles(rows, "ba", diff);
  const patch = viewChangesPatch(rows, "ba", "/repo/logo.png", "/repo", files);
  const names = parsePatchFiles(patch!.text)
    .flatMap((p) => p.files ?? [])
    .map((file) => file.name);
  expect(new Set(names)).toEqual(new Set(["logo.png", "empty.txt", "/tmp/setup.txt"]));
  expect(patch?.text).toContain("Binary files a/logo.png and b/logo.png differ");
  expect(patch?.file).toBe("logo.png");
});
