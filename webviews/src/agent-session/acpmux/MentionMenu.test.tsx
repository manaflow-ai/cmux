// The composer's @ picker (Claude desktop parity, 2026-10-19): what follows the @ matches other
// chats by title, then folders, then files of the chat's folder, in that order, each row with its
// icon, its name with the matched letters bold and its project or folder muted beside it. A pick
// writes what the agent reads: a path for a file or folder, the chat's title and id for a chat.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { bundledIconPack, resolveIcon } from "./icons/iconPack";
import { MentionMenu, type MentionState } from "./MentionMenu";
import {
  fuzzyIndices,
  loadRecentMentionPaths,
  mentionInsert,
  mentionItems,
  mentionSelection,
  recentMentionScope,
  rememberMentionPath,
  type MentionItem,
} from "./mentionItems";
import type { AcpmuxSessionEntry } from "./sessionList";

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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const SESSIONS: AcpmuxSessionEntry[] = [
  { sessionId: "this-chat-0000-0000-0000-000000000000", title: "Projects cleanup", cwd: "/Users/leo/Projects" },
  {
    sessionId: "0cfd5322-a913-4e01-b71c-aaf0edfb4de8",
    displayTitle: "Resume: projects-70 coordinator (0cfd5322)",
    cwd: "/Users/leo/Projects",
    updatedAt: 2,
  },
  {
    sessionId: "4f1e0c11-7a2b-4c3d-9e8f-0a1b2c3d4e5f",
    title: "Fix the dock",
    cwd: "/Users/leo/Projects/cmux",
    updatedAt: 3,
  },
  { sessionId: "9a9a9a9a-0000-4000-8000-000000000001", title: "Old projection notes", archived: true },
];

const FILES = {
  kind: "done",
  results: [
    { path: "terminal-lab/ios/project.yml", matches: [17, 18, 19, 20, 21] },
    { path: "tools/cmux-backlog/sync_project.py", matches: [24, 25, 26, 27, 28] },
    { path: "cmux-code/python/pyproject.toml", matches: [19, 20, 21, 22, 23] },
    { path: "plans/feat-resume/claude/projects/a.jsonl", matches: [25, 26, 27, 28, 29] },
  ],
} satisfies MentionState;

async function render(container: HTMLElement, items: MentionItem[], picked: MentionItem[] = []) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <MentionMenu state={FILES} items={items} active={0} onHover={() => {}} onPick={(item) => picked.push(item)} />,
    );
  });
  return picked;
}

const rows = (container: HTMLElement) => Array.from(container.querySelectorAll<HTMLElement>(".acpmux-mention-row"));
const bold = (row: HTMLElement) => Array.from(row.querySelectorAll("b"), (node) => node.textContent).join("");

test("@proje lists other chats, then folders, then files, each with its icon, bold match and muted place", async () => {
  const container = installDom();
  const items = mentionItems({
    query: "proje",
    files: FILES.results,
    sessions: SESSIONS,
    chatId: SESSIONS[0]!.sessionId,
  });
  await render(container, items);
  const listed = rows(container).map((row) => [
    row.dataset.mentionKind,
    row.querySelector(".acpmux-slash-name")?.textContent,
  ]);
  expect(listed).toEqual([
    // This chat and archived chats are not offered.
    ["session", "Resume: projects-70 coordinator (0cfd5322)"],
    ["folder", "projects"],
    ["file", "project.yml"],
    ["file", "sync_project.py"],
    ["file", "pyproject.toml"],
    ["file", "a.jsonl"],
  ]);
  const [session, folder, file] = rows(container);
  // The chat's project is its muted suffix; a path's folder is.
  expect(session!.querySelector(".acpmux-slash-description")?.textContent).toBe("Projects");
  expect(folder!.querySelector(".acpmux-slash-description")?.textContent).toBe("plans/feat-resume/claude");
  expect(file!.querySelector(".acpmux-slash-description")?.textContent).toBe("terminal-lab/ios");
  expect(bold(session!)).toBe("proje");
  expect(bold(folder!)).toBe("proje");
  expect(bold(file!)).toBe("proje");
  // Every row draws its own icon (a chat, a folder, a file), not the pack's stand-in for a missing one.
  for (const row of rows(container)) {
    const icon = row.querySelector<SVGElement>("[data-mention-icon] svg");
    expect(icon?.querySelector("path")?.getAttribute("d")).toBeTruthy();
    expect(resolveIcon(bundledIconPack, icon!.dataset.icon!, "line", "none")).not.toBeNull();
  }
  expect(file!.querySelector("[data-mention-icon]")?.getAttribute("data-mention-icon")).toBe("file");
});

test("a bare @ offers the most recent other chats before anything is typed", async () => {
  const container = installDom();
  const items = mentionItems({ query: "", files: [], sessions: SESSIONS, chatId: SESSIONS[0]!.sessionId });
  await render(container, items);
  expect(rows(container).map((row) => row.querySelector(".acpmux-slash-name")?.textContent)).toEqual([
    "Fix the dock",
    "Resume: projects-70 coordinator (0cfd5322)",
  ]);
});

test("a bare @ also offers recently picked files, and a query fuzzy-matches them", () => {
  const recent = mentionItems({
    query: "",
    files: [],
    recent: [
      { kind: "file", path: "docs/README.md" },
      { kind: "file", path: "src/app.ts" },
    ],
    sessions: [],
  });
  expect(recent.map((item) => item.key)).toEqual(["file:docs/README.md", "file:src/app.ts"]);
  expect(
    mentionItems({ query: "rmd", files: [], recent: [{ kind: "file", path: "docs/README.md" }], sessions: [] }).map(
      (item) => item.key,
    ),
  ).toEqual(["file:docs/README.md"]);
});

test("with a query, the host's results come before recent picks it did not return", () => {
  const items = mentionItems({
    query: "app",
    files: [{ path: "src/app.tsx", matches: [4, 5, 6] }],
    recent: [{ kind: "file", path: "old/app.ts" }],
    sessions: [],
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
    const [folder] = mentionItems({ query: "sr", files: [{ path: "src/app.ts" }], sessions: [] });
    expect(folder?.kind).toBe("folder");
    rememberMentionPath(here, folder!);
    const [file] = mentionItems({ query: "", files: [{ path: "src/app.ts" }], sessions: [] });
    rememberMentionPath(here, file!);
    expect(loadRecentMentionPaths(here)).toEqual([
      { kind: "file", path: "src/app.ts" },
      { kind: "folder", path: "src" },
    ]);
    expect(loadRecentMentionPaths(there)).toEqual([]);
    expect(loadRecentMentionPaths(remote)).toEqual([]);
    // No folder: nothing is kept.
    rememberMentionPath(recentMentionScope(undefined, undefined), file!);
    expect(loadRecentMentionPaths(undefined)).toEqual([]);
    const bare = mentionItems({ query: "", files: [], recent: loadRecentMentionPaths(here), sessions: [] });
    expect(bare.map((item) => item.key)).toEqual(["folder:src", "file:src/app.ts"]);
    expect(mentionInsert(bare[0]!).shown).toBe(mentionInsert(folder!).shown);
  } finally {
    if (had) scope.localStorage = saved;
    else delete scope.localStorage;
  }
});

test("picking a row hands back the row, and each kind writes what the agent reads", async () => {
  const container = installDom();
  const items = mentionItems({
    query: "proje",
    files: FILES.results,
    sessions: SESSIONS,
    chatId: SESSIONS[0]!.sessionId,
  });
  const picked = await render(container, items);
  const mouseDown = (row: HTMLElement) =>
    act(async () => {
      row.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
  await mouseDown(rows(container)[0]!);
  await mouseDown(rows(container)[1]!);
  await mouseDown(rows(container)[2]!);
  expect(picked.map((item) => mentionInsert(item).shown)).toEqual([
    'cmux session "Resume: projects-70 coordinator (0cfd5322)" (0cfd5322-a913-4e01-b71c-aaf0edfb4de8) ',
    "@plans/feat-resume/claude/projects/ ",
    "@terminal-lab/ios/project.yml ",
  ]);
});

test("a long history lists its five best chats, best first and ties in history order", () => {
  const history: AcpmuxSessionEntry[] = Array.from({ length: 2000 }, (_, index) => ({
    sessionId: `chat-${index}`,
    title: `Chat ${index}`,
    // Recency repeats, so ties have to keep the order the history lists them in.
    updatedAt: index % 700,
  }));
  const names = (query: string) =>
    mentionItems({ query, files: [], sessions: history }).map((item) => (item.kind === "session" ? item.title : ""));
  expect(names("")).toEqual(["Chat 699", "Chat 1399", "Chat 698", "Chat 1398", "Chat 697"]);
  // The composer never sends a space (it ends the @word), so a chat is found by one word of it.
  expect(names("1999")).toEqual(["Chat 1999"]);
});

test("an emoji in a chat's name bolds whole, and the letters after it bold where they are", async () => {
  const container = installDom();
  const sessions: AcpmuxSessionEntry[] = [{ sessionId: "emoji-chat", title: "Ship 😀launch" }];
  await render(container, mentionItems({ query: "😀la", files: [], sessions }));
  expect(bold(rows(container)[0]!)).toBe("😀la");
  await render(container, mentionItems({ query: "😀", files: [], sessions }));
  expect(bold(rows(container)[0]!)).toBe("😀");
});

test("a chat named across lines is offered and written on one line", async () => {
  const container = installDom();
  const sessions: AcpmuxSessionEntry[] = [{ sessionId: "multi-line", displayTitle: "Task\n# heading\n- item" }];
  const items = mentionItems({ query: "task", files: [], sessions });
  await render(container, items);
  expect(rows(container)[0]!.querySelector(".acpmux-slash-name")?.textContent).toBe("Task # heading - item");
  const { markdown, shown } = mentionInsert(items[0]!);
  expect(shown).toBe('cmux session "Task # heading - item" (multi-line) ');
  expect(markdown).not.toContain("\n");
});

// A chat named for its first prompt has the whole prompt as its title (sessionList.ts sessionTitle):
// its letters hold most short queries in order, and Return would write the chat for a file.
const PROMPT_CHAT: AcpmuxSessionEntry = {
  sessionId: "prompt-chat",
  displayTitle:
    "Can you add a parser for the plist files and make sure the tests pass on every platform we support, then update the app docs",
  updatedAt: 5,
};

test("a chat named for a long prompt does not take @app from the files", () => {
  const files = [{ path: "src/app.ts", matches: [4, 5, 6] }];
  const items = mentionItems({ query: "app", files, sessions: [PROMPT_CHAT] });
  // Its letters a…p…p are in order, and `app` is a word only past the first hundred characters.
  expect(items.map((item) => item.key)).toEqual(["file:src/app.ts"]);
  expect(items[mentionSelection(items, undefined, false)]!.key).toBe("file:src/app.ts");
  expect(mentionItems({ query: "ts", files: [], sessions: [PROMPT_CHAT] })).toEqual([]);
});

test("a chat whose title has the word lists first; a path-like word lists the files first", () => {
  const sessions: AcpmuxSessionEntry[] = [
    PROMPT_CHAT,
    { sessionId: "app-store", title: "App Store review notes", updatedAt: 1 },
    { sessionId: "web-app", title: "Fix the web app login", updatedAt: 2 },
    { sessionId: "mid-word", title: "Wrapped lines", updatedAt: 3 },
  ];
  const files = [{ path: "src/app.ts", matches: [4, 5, 6] }];
  const keys = (query: string) => mentionItems({ query, files, sessions }).map((item) => item.key);
  // A title starting with it first, then by how early the word is; `wrApped` is not a word start.
  expect(keys("app")).toEqual(["session:app-store", "session:web-app", "file:src/app.ts"]);
  expect(keys("app.")).toEqual(["file:src/app.ts"]);
  expect(keys("src/")).toEqual(["file:src/app.ts"]);
  const pathFirst = mentionItems({ query: "app.", files, sessions: [{ sessionId: "a", title: "app.ts crash" }] });
  expect(pathFirst.map((item) => item.kind)).toEqual(["file", "session"]);
});

test("while the files are on their way a chat is listed but not picked unasked", () => {
  const sessions: AcpmuxSessionEntry[] = [{ sessionId: "app-store", title: "App Store review notes" }];
  const before = mentionItems({ query: "app", files: [], sessions });
  expect(mentionSelection(before, undefined, true)).toBe(-1);
  // Moving to it picks it; once the files land, the first row is the pick.
  expect(mentionSelection(before, "session:app-store", true)).toBe(0);
  const after = mentionItems({ query: "app", files: [{ path: "src/app.ts", matches: [4, 5, 6] }], sessions });
  expect(mentionSelection(after, undefined, true)).toBe(1);
  expect(mentionSelection(after, undefined, false)).toBe(0);
});

test("the row moved to stays picked when the files land around it", () => {
  const sessions: AcpmuxSessionEntry[] = [
    { sessionId: "app-store", title: "App Store review notes" },
    { sessionId: "web-app", title: "Fix the web app login" },
  ];
  const before = mentionItems({ query: "app", files: [], sessions });
  const after = mentionItems({ query: "app", files: [{ path: "app/main.ts", matches: [0, 1, 2] }], sessions });
  expect(before[mentionSelection(before, "session:web-app", false)]!.key).toBe("session:web-app");
  expect(after[mentionSelection(after, "session:web-app", false)]!.key).toBe("session:web-app");
  // A row that is gone falls back to the first.
  expect(mentionSelection(after, "file:gone.ts", false)).toBe(0);
});

test("a letter that lowercases longer does not move the bold letters after it", async () => {
  const container = installDom();
  // `İ` is one string unit and lowercases to two (`i̇`).
  const sessions: AcpmuxSessionEntry[] = [{ sessionId: "istanbul", title: "İstanbul trip plan" }];
  await render(container, mentionItems({ query: "trip", files: [], sessions }));
  expect(bold(rows(container)[0]!)).toBe("trip");
  await render(container, mentionItems({ query: "i̇stan", files: [], sessions }));
  expect(bold(rows(container)[0]!)).toBe("İstan");
  // A folder's name is matched the same way.
  expect(fuzzyIndices("pl", "İ-pl")).toEqual([2, 3]);
  expect(fuzzyIndices("ipl", "İxpxl")).toEqual([0, 2, 4]);
});

test("a chat title with a quote is written as one quoted string", () => {
  const [item] = mentionItems({ query: "say", files: [], sessions: [{ sessionId: "q", title: 'Say "hi" \\ bye' }] });
  const { shown } = mentionInsert(item!);
  expect(shown).toBe('cmux session "Say \\"hi\\" \\\\ bye" (q) ');
  expect(JSON.parse(shown.slice("cmux session ".length, shown.lastIndexOf(" (")))).toBe('Say "hi" \\ bye');
});
