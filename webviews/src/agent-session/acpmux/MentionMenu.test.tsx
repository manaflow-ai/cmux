// The composer's @ picker (Codex parity, 2026-11-21): the plugins (computer use, browser use), then,
// for a specific word, folders and files of the chat's folder, each row with its icon, its name with
// the matched letters bold and its line or folder muted beside it. No chats. A pick writes what the
// agent reads: a path for a file or folder, `@computer-use` for a plugin.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { bundledIconPack, resolveIcon } from "./icons/iconPack";
import { MentionMenu } from "./MentionMenu";
import { type MentionState } from "./mentionMenuModel";
import {
  fuzzyIndices,
  guestMention,
  loadRecentMentionPaths,
  mentionInsert,
  mentionItems,
  mentionSelection,
  mentionWantsFiles,
  recentMentionScope,
  rememberMentionPath,
  type MentionItem,
} from "./mentionItems";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

const FILES = {
  kind: "done",
  results: [
    { path: "terminal-lab/ios/project.yml", matches: [17, 18, 19, 20, 21] },
    { path: "tools/cmux-backlog/sync_project.py", matches: [24, 25, 26, 27, 28] },
    { path: "cmux-code/python/pyproject.toml", matches: [19, 20, 21, 22, 23] },
    { path: "plans/feat-resume/claude/projects/a.jsonl", matches: [25, 26, 27, 28, 29] },
  ],
} satisfies MentionState;

async function render(
  container: HTMLElement,
  items: MentionItem[],
  picked: MentionItem[] = [],
  state: MentionState = FILES,
) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <MentionMenu state={state} items={items} active={0} onHover={() => {}} onPick={(item) => picked.push(item)} />,
    );
  });
  return picked;
}

const rows = (container: HTMLElement) => Array.from(container.querySelectorAll<HTMLElement>(".acpmux-mention-row"));
const bold = (row: HTMLElement) => Array.from(row.querySelectorAll("b"), (node) => node.textContent).join("");

test("@proje lists folders, then files, each with its icon, bold match and muted place: no chats", async () => {
  const container = installDom();
  const items = mentionItems({ query: "proje", files: FILES.results });
  await render(container, items);
  const listed = rows(container).map((row) => [
    row.dataset.mentionKind,
    row.querySelector(".acpmux-slash-name")?.textContent,
  ]);
  expect(listed).toEqual([
    ["folder", "projects"],
    ["file", "project.yml"],
    ["file", "sync_project.py"],
    ["file", "pyproject.toml"],
    ["file", "a.jsonl"],
  ]);
  const [folder, file] = rows(container);
  // A path's folder is its muted suffix.
  expect(folder!.querySelector(".acpmux-slash-description")?.textContent).toBe("plans/feat-resume/claude");
  expect(file!.querySelector(".acpmux-slash-description")?.textContent).toBe("terminal-lab/ios");
  expect(bold(folder!)).toBe("proje");
  expect(bold(file!)).toBe("proje");
  // Every row draws its own icon (a folder, a file), not the pack's stand-in for a missing one.
  for (const row of rows(container)) {
    const icon = row.querySelector<SVGElement>("[data-mention-icon] svg");
    expect(icon?.querySelector("path")?.getAttribute("d")).toBeTruthy();
    expect(resolveIcon(bundledIconPack, icon!.dataset.icon!, "line", "none")).not.toBeNull();
  }
  expect(file!.querySelector("[data-mention-icon]")?.getAttribute("data-mention-icon")).toBe("file");
});

test("a bare @ offers computer use and browser use, and no chats", async () => {
  const container = installDom();
  const items = mentionItems({
    query: "",
    files: [],
    toolName: (tool) => (tool.id === "computer-use" ? "Computer use" : "Browser use"),
  });
  await render(container, items);
  expect(rows(container).map((row) => row.querySelector(".acpmux-slash-name")?.textContent)).toEqual([
    "Computer use",
    "Browser use",
  ]);
});

test("computer use and browser use are always offered, found by their name's start, and write one word", () => {
  const keys = (query: string) => mentionItems({ query, files: [] }).map((item) => item.key);
  expect(keys("")).toEqual(["tool:computer-use", "tool:browser-use"]);
  expect(keys("comp")).toEqual(["tool:computer-use"]);
  expect(keys("BROW")).toEqual(["tool:browser-use"]);
  expect(keys("cu")).toEqual(["tool:computer-use"]);
  // A word that names neither (a file's) lists no tool, and a path never does.
  expect(keys("app")).toEqual([]);
  expect(keys("computer-use/")).toEqual([]);
  const [computer] = mentionItems({ query: "comp", files: [], toolName: () => "Computer use" });
  expect(computer?.name).toEqual([
    { text: "Comp", matched: true },
    { text: "uter use", matched: false },
  ]);
  expect(mentionInsert(computer!).shown).toBe("@computer-use ");
  // The plugin a word names leads the files it also finds, as Codex's @ does; a short word lists no files.
  const browse = [{ path: "src/browse.ts", matches: [4, 5, 6, 7] }];
  const files = mentionItems({ query: "brow", files: browse });
  expect(files.map((item) => item.key)).toEqual(["tool:browser-use", "file:src/browse.ts"]);
  expect(mentionItems({ query: "bro", files: browse }).map((item) => item.key)).toEqual(["tool:browser-use"]);
});

test("a harness mention is offered as a read-only guest and inserts its target token", () => {
  const catalog = [
    { id: "codex", name: "Codex", models: [], pickable: true, family: "codex" },
    { id: "claude", name: "Claude", models: [], pickable: true, family: "claude" },
    { id: "router", name: "Router", models: [], pickable: true, kind: "cmux-router" },
    { id: "offline", name: "Offline", models: [], pickable: true, unavailable: "missing" },
  ];
  const items = mentionItems({ query: "cod", files: [], harnesses: catalog });
  expect(items.map((item) => item.key)).toEqual(["harness:codex"]);
  expect(mentionInsert(items[0]!).shown).toBe("@codex ");
});

test("a send asks the first harness named outside code, and keeps the rest of its words", () => {
  const catalog = [
    { id: "codex", name: "Codex", models: [], pickable: true, family: "codex" },
    { id: "claude", name: "Claude", models: [], pickable: true, family: "claude" },
  ];
  expect(guestMention("@codex review @src/auth.ts for bugs", catalog)).toEqual({
    harnessId: "codex",
    question: "review @src/auth.ts for bugs",
  });
  expect(guestMention("@nobody @Claude compare this plan with @codex", catalog)).toEqual({
    harnessId: "claude",
    question: "@nobody  compare this plan with @codex",
  });
  // A code example is literal text: the send stays the main agent's.
  expect(guestMention("Why does this fail?\n```\n@codex explain retries\n```", catalog)).toBeUndefined();
  expect(guestMention("Explain what `@codex hi` does", catalog)).toBeUndefined();
  expect(guestMention("```sh\nunclosed\n@codex run", catalog)).toBeUndefined();
  expect(guestMention("email me@codex please", catalog)).toBeUndefined();
  // A folder's own profile cannot answer as a guest yet, so a send never asks one.
  const folder = [
    { id: "local", name: "Local", models: [], pickable: true, folder: { folder: "/w", state: "enabled" } },
  ];
  expect(guestMention("@local look", folder as never)).toBeUndefined();
});

test("files wait for a specific word: a bare @ lists the plugins, a word of 4 letters or a path its files", () => {
  expect(mentionWantsFiles("")).toBe(false);
  expect(mentionWantsFiles("app")).toBe(false);
  expect(mentionWantsFiles("read")).toBe(true);
  expect(mentionWantsFiles("a.t")).toBe(true);
  expect(mentionWantsFiles("s/")).toBe(true);
});

test("a bare @ offers no recent files; a specific word fuzzy-matches them", () => {
  const recent = mentionItems({
    query: "",
    files: [],
    recent: [
      { kind: "file", path: "docs/README.md" },
      { kind: "file", path: "src/app.ts" },
    ],
  });
  expect(recent.map((item) => item.key)).toEqual(["tool:computer-use", "tool:browser-use"]);
  expect(
    mentionItems({ query: "rdme", files: [], recent: [{ kind: "file", path: "docs/README.md" }] }).map(
      (item) => item.key,
    ),
  ).toEqual(["file:docs/README.md"]);
});

test("with a query, the host's results come before recent picks it did not return", () => {
  const items = mentionItems({
    query: "app.t",
    files: [{ path: "src/app.tsx", matches: [4, 5, 6, 7, 8] }],
    recent: [{ kind: "file", path: "old/app.ts" }],
  });
  expect(items.filter((item) => item.kind === "file").map((item) => item.key)).toEqual([
    "file:src/app.tsx",
    "file:old/app.ts",
  ]);
});

test("recent picks are kept per project and host, and a picked folder is remembered as a folder", () => {
  const store = new Map<string, string>();
  const scope = globalThis as Record<string, unknown>;
  const had = "localStorage" in scope;
  const saved = scope.localStorage;
  scope.localStorage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  try {
    const here = recentMentionScope("/home/dev/api", undefined);
    const there = recentMentionScope("/home/dev/web", undefined);
    const remote = recentMentionScope("/home/dev/api", "build-box");
    const [folder] = mentionItems({ query: "sour", files: [{ path: "source/app.ts" }] });
    expect(folder?.kind).toBe("folder");
    rememberMentionPath(here, folder!);
    const file = mentionItems({ query: "source", files: [{ path: "source/app.ts" }] }).find(
      (item) => item.kind === "file",
    );
    rememberMentionPath(here, file!);
    expect(loadRecentMentionPaths(here)).toEqual([
      { kind: "file", path: "source/app.ts" },
      { kind: "folder", path: "source" },
    ]);
    expect(loadRecentMentionPaths(there)).toEqual([]);
    expect(loadRecentMentionPaths(remote)).toEqual([]);
    // No folder: nothing is kept.
    rememberMentionPath(recentMentionScope(undefined, undefined), file!);
    expect(loadRecentMentionPaths(undefined)).toEqual([]);
    const bare = mentionItems({ query: "sour", files: [], recent: loadRecentMentionPaths(here) });
    const paths = bare.filter((item) => item.kind !== "tool");
    expect(paths.map((item) => item.key)).toEqual(["folder:source", "file:source/app.ts"]);
    expect(mentionInsert(paths[0]!).shown).toBe(mentionInsert(folder!).shown);
  } finally {
    if (had) scope.localStorage = saved;
    else delete scope.localStorage;
  }
});

test("picking a row hands back the row, and each kind writes what the agent reads", async () => {
  const container = installDom();
  const items = mentionItems({ query: "proje", files: FILES.results });
  const picked = await render(container, items);
  const mouseDown = (row: HTMLElement) =>
    act(async () => {
      row.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
  await mouseDown(rows(container)[0]!);
  await mouseDown(rows(container)[1]!);
  expect(picked.map((item) => mentionInsert(item).shown)).toEqual([
    "@plans/feat-resume/claude/projects/ ",
    "@terminal-lab/ios/project.yml ",
  ]);
});

test("the row moved to stays picked when the files land around it", () => {
  const before = mentionItems({ query: "brow", files: [] });
  const after = mentionItems({ query: "brow", files: [{ path: "browse/main.ts", matches: [0, 1, 2, 3] }] });
  expect(before[mentionSelection(before, "tool:browser-use", false)]!.key).toBe("tool:browser-use");
  expect(after[mentionSelection(after, "tool:browser-use", false)]!.key).toBe("tool:browser-use");
  expect(after[mentionSelection(after, "file:browse/main.ts", false)]!.key).toBe("file:browse/main.ts");
  // A row that is gone falls back to the first.
  expect(mentionSelection(after, "file:gone.ts", false)).toBe(0);
});

test("a letter that lowercases longer does not move the bold letters after it", () => {
  // `İ` is one string unit and lowercases to two (`i̇`): a folder's name keeps its bold letters in place.
  expect(fuzzyIndices("pl", "İ-pl")).toEqual([2, 3]);
  expect(fuzzyIndices("ipl", "İxpxl")).toEqual([0, 2, 4]);
});

test("the file search says nothing under rows that work: no error under a plugin, only an empty menu speaks", async () => {
  const container = installDom();
  const note = () => container.ownerDocument.querySelector(".acpmux-file-note, .acpmux-file-loading-note");
  const tools = mentionItems({ query: "comp", files: [] });
  await render(container, tools, [], { kind: "failed" });
  expect(note()).toBeNull();
  await render(container, [], [], { kind: "failed" });
  expect(note()?.textContent).not.toContain("Couldn't");
});

test("a plugin leads a guest harness the same word names: `@c` is Computer Use first", () => {
  const catalog = [{ id: "codex", name: "Codex", models: [], pickable: true, family: "codex" }];
  const keys = mentionItems({ query: "c", files: [], harnesses: catalog }).map((item) => item.key);
  expect(keys).toEqual(["tool:computer-use", "harness:codex"]);
  expect(mentionSelection(mentionItems({ query: "c", files: [], harnesses: catalog }), undefined, false)).toBe(0);
});
