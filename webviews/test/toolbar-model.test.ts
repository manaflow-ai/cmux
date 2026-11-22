import { describe, expect, test } from "bun:test";
import type { DiffSource } from "../src/diff/generated/protocol";
import type { DiffItem } from "../src/diff-stream";
import {
  activeSourceMenuId,
  diffLineTotals,
  jumpToFileRows,
  NO_HOST_CAPABILITIES,
  overflowMenuItems,
  rovingIndex,
  sourceMenuModel,
  toolbarPillButtons,
  UNCOMMITTED_BASE_REF,
} from "../src/toolbar-model";

const isValidSource = (value: unknown): value is DiffSource =>
  typeof value === "object" && value != null && typeof (value as { kind?: unknown }).kind === "string";

function model(input: Partial<Parameters<typeof sourceMenuModel>[0]>) {
  return sourceMenuModel({
    sourceOptions: undefined,
    repoRoot: "/tmp/repo",
    activeSource: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "origin/main" },
    typedTransport: true,
    isValidSource,
    ...input,
  });
}

describe("source menu", () => {
  test("lists Last Turn | Uncommitted, Unstaged, Staged | Committed, Branch with Branch checked", () => {
    const { sections, selected } = model({});
    expect(sections.map((section) => section.map((entry) => entry.id))).toEqual([
      ["last-turn"],
      ["uncommitted", "unstaged", "staged"],
      ["committed", "branch"],
    ]);
    expect(selected?.id).toBe("branch");
    expect(
      sections
        .flat()
        .filter((entry) => entry.checked)
        .map((entry) => entry.id),
    ).toEqual(["branch"]);
  });

  test("a typed session offers the git sources the sidecar supports", () => {
    const entries = model({}).sections.flat();
    const target = (id: string) => entries.find((entry) => entry.id === id)?.target;
    expect(target("unstaged")).toEqual({ kind: "session", source: { kind: "unstaged", repoRoot: "/tmp/repo" } });
    expect(target("staged")).toEqual({ kind: "session", source: { kind: "staged", repoRoot: "/tmp/repo" } });
    expect(target("uncommitted")).toEqual({
      kind: "session",
      source: { kind: "branch", repoRoot: "/tmp/repo", baseRef: UNCOMMITTED_BASE_REF },
    });
    // Last Turn and Committed need the host: there is no git-only way to open them.
    expect(target("last-turn")).toBeNull();
    expect(target("committed")).toBeNull();
    expect(entries.find((entry) => entry.id === "committed")?.children).toEqual([]);
  });

  test("Branch reopens the remembered base, never the Uncommitted HEAD session", () => {
    const remembered = { kind: "branch", repoRoot: "/tmp/repo", baseRef: "release" } as const;
    const branch = (input: Partial<Parameters<typeof sourceMenuModel>[0]>) =>
      model(input)
        .sections.flat()
        .find((entry) => entry.id === "branch")?.target;
    expect(branch({ rememberedBranch: remembered, activeSource: { kind: "unstaged", repoRoot: "/tmp/repo" } })).toEqual(
      {
        kind: "session",
        source: remembered,
      },
    );
    expect(
      branch({
        rememberedBranch: { kind: "branch", repoRoot: "/tmp/repo", baseRef: UNCOMMITTED_BASE_REF },
        branchBaseRef: "main",
      }),
    ).toEqual({ kind: "session", source: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" } });
  });

  test("checks the row matching the active session", () => {
    expect(activeSourceMenuId({ kind: "patch", path: "/turn.patch" })).toBe("last-turn");
    expect(activeSourceMenuId({ kind: "staged", repoRoot: "/r" })).toBe("staged");
    expect(activeSourceMenuId({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" })).toBe("uncommitted");
    expect(activeSourceMenuId({ kind: "branch", repoRoot: "/r" })).toBe("branch");
    expect(model({ activeSource: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "HEAD" } }).selected?.id).toBe(
      "uncommitted",
    );
  });

  test("host source options win, and commit options fill the Committed submenu", () => {
    const { sections, selected } = model({
      activeSource: null,
      typedTransport: false,
      sourceOptions: [
        { value: "last-turn", label: "Last turn", url: "/last-turn.html" },
        { value: "unstaged", label: "Unstaged", url: "/unstaged.html" },
        { value: "commit:abc123", label: "abc123 Fix the toolbar", url: "/commit-abc123.html", selected: true },
      ],
    });
    const entries = sections.flat();
    expect(entries.find((entry) => entry.id === "last-turn")?.target).toEqual({ kind: "url", url: "/last-turn.html" });
    // Without a typed session, sources the host did not list are unavailable.
    expect(entries.find((entry) => entry.id === "staged")?.target).toBeNull();
    const committed = entries.find((entry) => entry.id === "committed");
    expect(committed?.checked).toBe(true);
    expect(committed?.children?.map((child) => child.text)).toEqual(["abc123 Fix the toolbar"]);
    expect(selected?.text).toBe("abc123 Fix the toolbar");
  });

  test("a disabled host option stays unavailable", () => {
    const entries = model({
      typedTransport: false,
      sourceOptions: [{ value: "staged", disabled: true, url: "/staged.html" }],
    }).sections.flat();
    expect(entries.find((entry) => entry.id === "staged")?.target).toBeNull();
  });
});

describe("overflow menu", () => {
  test("rows match the reference menu, each wired to an option or marked unavailable", () => {
    const items = overflowMenuItems({ expandUnchanged: true, wordDiffs: true }, NO_HOST_CAPABILITIES);
    expect(items.map((item) => [item.id, item.icon, item.labelKey])).toEqual([
      ["load-full-files", "file", "loadFullFiles"],
      ["rich-preview", "image", "richPreview"],
      ["word-diffs", "plusMinus", "wordDiffs"],
      ["hide-whitespace", "eye", "hideWhitespace"],
      ["hide-imports", "package", "hideImports"],
      ["copy-git-apply", "clipboard", "copyGitApplyCommand"],
    ]);
    const byId = Object.fromEntries(items.map((item) => [item.id, item]));
    expect(byId["word-diffs"]).toMatchObject({ checked: true, available: true });
    expect(byId["copy-git-apply"]?.available).toBe(true);
    expect(byId["copy-git-apply"]?.checked).toBeUndefined();
    // expandUnchanged cannot reveal context without full file contents.
    expect(byId["load-full-files"]).toMatchObject({ checked: false, available: false });
    for (const id of ["rich-preview", "hide-whitespace", "hide-imports"]) {
      expect(byId[id]?.available).toBe(false);
    }
  });

  test("Load full files follows expandUnchanged once file contents are available", () => {
    const capabilities = { ...NO_HOST_CAPABILITIES, fullFiles: true };
    const item = (expandUnchanged: boolean) =>
      overflowMenuItems({ expandUnchanged, wordDiffs: false }, capabilities).find(
        (row) => row.id === "load-full-files",
      );
    expect(item(true)).toMatchObject({ checked: true, available: true });
    expect(item(false)).toMatchObject({ checked: false, available: true });
  });
});

describe("toolbar pill", () => {
  test("buttons, order and tooltips follow the viewer state", () => {
    const buttons = toolbarPillButtons({
      options: { collapsed: false, layout: "split", wordWrap: true },
      filesVisible: true,
      optionsOpen: true,
      findOpen: false,
    });
    expect(buttons.map((button) => [button.id, button.labelKey])).toEqual([
      ["options", "options"],
      ["find", "findInDiff"],
      ["refresh", "refresh"],
      ["wrap", "wordWrap"],
      ["expand", "collapseAllDiffs"],
      ["layout", "switchToUnifiedDiff"],
      ["files", "hideFiles"],
    ]);
    expect(buttons[0]?.expanded).toBe(true);
    expect(buttons.find((button) => button.id === "wrap")?.pressed).toBe(true);
    const collapsed = toolbarPillButtons({
      options: { collapsed: true, layout: "unified", wordWrap: false },
      filesVisible: false,
      optionsOpen: false,
      findOpen: true,
    });
    expect(collapsed.find((button) => button.id === "expand")?.labelKey).toBe("expandAllDiffs");
    expect(collapsed.find((button) => button.id === "layout")?.labelKey).toBe("switchToSplitDiff");
    expect(collapsed.find((button) => button.id === "files")?.labelKey).toBe("showFiles");
    expect(collapsed.find((button) => button.id === "find")?.pressed).toBe(true);
  });

  test("roving focus wraps and honors Home and End", () => {
    expect(rovingIndex("ArrowRight", 6, 7, "horizontal")).toBe(0);
    expect(rovingIndex("ArrowLeft", 0, 7, "horizontal")).toBe(6);
    expect(rovingIndex("ArrowDown", 1, 3, "vertical")).toBe(2);
    expect(rovingIndex("ArrowDown", 1, 3, "horizontal")).toBeNull();
    expect(rovingIndex("Home", 4, 7, "horizontal")).toBe(0);
    expect(rovingIndex("End", 0, 7, "vertical")).toBe(6);
  });
});

describe("jump to file", () => {
  const items = [
    "skills/infra/tsadmin/acl.manaflow.hujson",
    "CLAUDE.md",
    "plans/cmux-tui-change-log.md",
    "scripts/cmux.sh",
  ].map((name) => ({ id: name, fileDiff: { name, hunks: [] } }) as DiffItem);

  test("rows are file name plus directory, sorted by name", () => {
    expect(jumpToFileRows(items, "", "Untitled").rows).toEqual([
      {
        id: "skills/infra/tsadmin/acl.manaflow.hujson",
        name: "acl.manaflow.hujson",
        directory: "skills/infra/tsadmin",
      },
      { id: "CLAUDE.md", name: "CLAUDE.md", directory: "" },
      { id: "plans/cmux-tui-change-log.md", name: "cmux-tui-change-log.md", directory: "plans" },
      { id: "scripts/cmux.sh", name: "cmux.sh", directory: "scripts" },
    ]);
  });

  test("a query ranks name prefix, then name, then directory matches", () => {
    expect(jumpToFileRows(items, "cmux", "Untitled").rows.map((row) => row.name)).toEqual([
      "cmux-tui-change-log.md",
      "cmux.sh",
    ]);
    expect(jumpToFileRows(items, "md", "Untitled").rows.map((row) => row.name)).toEqual([
      "CLAUDE.md",
      "cmux-tui-change-log.md",
    ]);
    expect(jumpToFileRows(items, "tsadmin", "Untitled").rows.map((row) => row.name)).toEqual(["acl.manaflow.hujson"]);
    expect(jumpToFileRows(items, "nothing", "Untitled")).toEqual({ rows: [], hidden: 0 });
  });
});

test("diff line totals sum every hunk", () => {
  const items = [
    {
      id: "a",
      fileDiff: {
        hunks: [
          { additionLines: 3, deletionLines: 1 },
          { additionLines: 2, deletionLines: 0 },
        ],
      },
    },
    { id: "b", fileDiff: { hunks: [{ additionLines: 0, deletionLines: 4 }] } },
    { id: "c" },
  ] as DiffItem[];
  expect(diffLineTotals(items)).toEqual({ additions: 5, deletions: 5 });
});
