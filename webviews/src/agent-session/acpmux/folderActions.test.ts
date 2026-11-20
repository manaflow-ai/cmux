import { afterEach, describe, expect, test } from "bun:test";
import { translate, type Translate } from "./i18n";
import {
  FOLDER_ACTIONS,
  absolutePath,
  editorList,
  fileMenuItems,
  folderActions,
  folderMenuChildren,
  openInEditorLabel,
  readEditorList,
  refreshEditors,
  setEditors,
  type EditorList,
  type FolderHost,
} from "./folderActions";
import { folderRow } from "./header/folderRow";
import { instructionsRow, projectFilesRow } from "./header/instructionsRow";
import { guardedChatMenu, menuGroups, type ChatMenuItem } from "./header/chatHeaderToolsModel";
import { nativeChatMenu } from "./header/nativeMenuBindings";
import { headerQuickTools } from "./header/headerQuickTools";
import { QUICK_ACTION_DEFAULTS, readQuickActions } from "./header/quickActions";
import { worktreeFolderActions } from "./header/worktreePillModel";

const t: Translate = translate;

const EDITORS: EditorList = {
  default: { id: "zed", name: "Zed" },
  others: [
    { id: "vscode", name: "Visual Studio Code" },
    { id: "cursor", name: "Cursor" },
  ],
};

/// A host that records what each row asks the app.
function recorder(session: string | undefined = "s1") {
  const calls: unknown[][] = [];
  const host: FolderHost = {
    folder: "/Users/me/src/app",
    session,
    run: (id, at, app) => void calls.push(["run", id, at, ...(app ? [app] : [])]),
    openFile: (path, where) => void calls.push(["file.open", path, where]),
    copy: (text) => void calls.push(["copy", text]),
  };
  return { host, calls };
}

afterEach(() => setEditors(undefined));

describe("editors.list", () => {
  test("reads the default and the others, dropping bad ids, empty names and repeats", () => {
    expect(
      readEditorList({
        default: { id: "zed", name: " Zed " },
        others: [
          { id: "zed", name: "Zed again" },
          { id: "Bad Id", name: "Bad" },
          { id: "vscode", name: "" },
          { id: "cursor", name: "Cursor" },
          "nope",
        ],
      }),
    ).toEqual({ default: { id: "zed", name: "Zed" }, others: [{ id: "cursor", name: "Cursor" }] });
    expect(readEditorList({ default: null, others: [] })).toEqual({ default: null, others: [] });
    // An older app answers null: no list, so the rows say Open in Editor.
    expect(readEditorList(null)).toBeUndefined();
  });

  test("a read keeps the last list when it fails, and one read runs at a time", async () => {
    let reads = 0;
    const read = () => {
      reads++;
      return Promise.resolve(EDITORS);
    };
    await Promise.all([refreshEditors(read), refreshEditors(read)]);
    expect(reads).toBe(1);
    expect(editorList()).toEqual(EDITORS);
    await refreshEditors(() => Promise.reject(new Error("older app")));
    expect(editorList()).toEqual(EDITORS);
  });
});

describe("folder rows", () => {
  test("Open in the default editor by name, Open In the others, Reveal, Terminal, Copy Path, in order", () => {
    const { host, calls } = recorder();
    const rows = folderActions(host, EDITORS, t);
    expect(rows.map((row) => row.label)).toEqual([
      "Open in Zed",
      "Open In",
      "Reveal in Finder",
      "Open Terminal Here",
      "Copy Path",
    ]);
    expect(rows[1]!.editors!.map((editor) => editor.label)).toEqual(["Visual Studio Code", "Cursor"]);
    for (const row of rows) row.run?.();
    rows[1]!.editors![1]!.run();
    expect(calls).toEqual([
      ["run", FOLDER_ACTIONS.openInEditor, "s1"],
      ["run", FOLDER_ACTIONS.reveal, "s1"],
      ["run", FOLDER_ACTIONS.terminal, "s1"],
      ["copy", "/Users/me/src/app"],
      ["run", FOLDER_ACTIONS.openInApp, "s1", "cursor"],
    ]);
  });

  test("with no editor known or installed: Open in Editor, and no Open In", () => {
    const { host } = recorder();
    for (const list of [undefined, { default: null, others: [] }]) {
      expect(folderActions(host, list, t).map((row) => row.key)).toEqual([
        "openInEditor",
        "reveal",
        "terminal",
        "copyPath",
      ]);
      expect(openInEditorLabel(list, t)).toBe("Open in Editor");
    }
  });

  test("a row runs for the session it was drawn for, not the one shown later", () => {
    const { host, calls } = recorder("drawn");
    const rows = folderActions(host, EDITORS, t);
    host.session = "later";
    rows[0]!.run?.();
    expect(calls).toEqual([["run", FOLDER_ACTIONS.openInEditor, "drawn"]]);
  });

  test("the worktree pill lists the four folder actions without Open In", () => {
    const { host } = recorder();
    expect(worktreeFolderActions(host, EDITORS, t).map((row) => row.label)).toEqual([
      "Open in Zed",
      "Reveal in Finder",
      "Open Terminal Here",
      "Copy Path",
    ]);
  });
});

describe("the chat menu's Folder row", () => {
  const chat = { cwd: "/Users/me/src/app", family: "claude" };
  const project = [instructionsRow(chat, () => undefined, t), projectFilesRow(chat, () => undefined, t)];

  test("one Folder row holds the folder's actions, then Edit CLAUDE.md and Add Files under a line", () => {
    const { host } = recorder();
    const row = folderRow(folderActions(host, EDITORS, t), project, t)!;
    expect(row.label).toBe("Folder");
    expect(row.children!.map((child) => [child.label, child.separatorBefore ?? false])).toEqual([
      ["Open in Zed", false],
      ["Open In", false],
      ["Reveal in Finder", false],
      ["Open Terminal Here", false],
      ["Copy Path", false],
      ["Edit CLAUDE.md", true],
      ["Add Files to Project…", false],
    ]);
    expect(row.children![1]!.children!.map((child) => child.label)).toEqual(["Visual Studio Code", "Cursor"]);
  });

  test("the menu does not grow: two top-level rows become one", () => {
    const { host } = recorder();
    const before = menuGroups(project.filter((row) => row !== undefined) as ChatMenuItem[]);
    const after = menuGroups([folderRow(folderActions(host, EDITORS, t), project, t)!]);
    expect(before.length).toBe(2);
    expect(after.length).toBe(1);
  });

  test("a chat whose folder is not on this Mac keeps only the project rows; none at all, no row", () => {
    expect(folderRow(undefined, project, t)!.children!.map((child) => child.label)).toEqual([
      "Edit CLAUDE.md",
      "Add Files to Project…",
    ]);
    expect(folderRow(undefined, [undefined, undefined], t)).toBeUndefined();
  });

  test("a menu kept open across a chat switch runs none of its rows, Open In's editors included", () => {
    const { host, calls } = recorder();
    let shown = true;
    const [row] = guardedChatMenu([folderRow(folderActions(host, EDITORS, t), [], t)!], () => shown) as Exclude<
      ChatMenuItem,
      "separator"
    >[];
    shown = false;
    row!.children![0]!.onSelect();
    row!.children![1]!.children![0]!.onSelect();
    expect(calls).toEqual([]);
    shown = true;
    row!.children![1]!.children![0]!.onSelect();
    expect(calls).toEqual([["run", FOLDER_ACTIONS.openInApp, "s1", "vscode"]]);
  });

  test("the native menu lists Open In's editors in its place, one submenu deep", () => {
    const { host, calls } = recorder();
    const binding = nativeChatMenu([folderRow(folderActions(host, EDITORS, t), [], t)!])!;
    const folder = binding.items[0]!;
    expect(folder.children!.map((child) => [child.id, child.label])).toEqual([
      ["folder/openInEditor", "Open in Zed"],
      ["folder/openIn-vscode", "Open In Visual Studio Code"],
      ["folder/openIn-cursor", "Open In Cursor"],
      ["folder/reveal", "Reveal in Finder"],
      ["folder/terminal", "Open Terminal Here"],
      ["folder/copyPath", "Copy Path"],
    ]);
    binding.invoke("folder/openIn-cursor");
    expect(calls).toEqual([["run", FOLDER_ACTIONS.openInApp, "s1", "cursor"]]);
  });

  test("the submenu's rows keep their keys", () => {
    const { host } = recorder();
    expect(folderMenuChildren(folderActions(host, undefined, t)).map((child) => child.key)).toEqual([
      "openInEditor",
      "reveal",
      "terminal",
      "copyPath",
    ]);
  });
});

describe("a changed file", () => {
  test("Open in the default editor, Reveal in Finder and Copy Path for the file", () => {
    const { host, calls } = recorder();
    const items = fileMenuItems("/Users/me/src/app/src/a.ts", host, EDITORS, t);
    expect(items.map((item) => item.label)).toEqual(["Open in Zed", "Reveal in Finder", "Copy Path"]);
    for (const item of items) item.onSelect();
    expect(calls).toEqual([
      ["file.open", "/Users/me/src/app/src/a.ts", "editor"],
      ["file.open", "/Users/me/src/app/src/a.ts", "finder"],
      ["copy", "/Users/me/src/app/src/a.ts"],
    ]);
  });

  test("a path the agent wrote relative opens from the turn's root, else the chat's folder", () => {
    expect(absolutePath("/tmp/x.ts", ["/repo"])).toBe("/tmp/x.ts");
    expect(absolutePath("src/a.ts", [undefined, "/repo/"])).toBe("/repo/src/a.ts");
    expect(absolutePath("./src/a.ts", ["/repo"])).toBe("/repo/src/a.ts");
    expect(absolutePath("src/a.ts", [undefined])).toBeUndefined();
  });
});

describe("the header's Open in Editor", () => {
  test("is not a button by default, and no default button changes", () => {
    expect(QUICK_ACTION_DEFAULTS.map((action) => action.id)).toEqual(["changes", "terminal", "browser"]);
    expect(readQuickActions({ quickActions: ["openInEditor"] }).map((action) => action.id)).toEqual(["openInEditor"]);
  });

  test("a pinned Open in Editor names the editor, and hides without a folder on this Mac", () => {
    const base = {
      actions: [{ id: "openInEditor" as const, mode: "toggle" as const }],
      tabTools: true,
      sideTabs: false,
      lit: [],
      hasChanges: false,
      onTerminal: () => undefined,
      onBrowser: () => undefined,
      t,
    };
    let ran = 0;
    const [tool] = headerQuickTools({ ...base, onOpenInEditor: () => ran++, openInEditorLabel: "Open in Zed" });
    expect([tool!.id, tool!.label, tool!.icon]).toEqual(["openInEditor", "Open in Zed", "code"]);
    tool!.run?.();
    expect(ran).toBe(1);
    expect(headerQuickTools(base)).toEqual([]);
  });
});
