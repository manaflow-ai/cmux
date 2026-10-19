// The composer's @ picker (Claude desktop parity, 2026-10-19): what follows the @ matches other
// chats by title, then folders, then files of the chat's folder, in that order, each row with its
// icon, its name with the matched letters bold and its project or folder muted beside it. A pick
// writes what the agent reads: a path for a file or folder, the chat's title and id for a chat.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MentionMenu, type MentionState } from "./MentionMenu";
import { mentionInsert, mentionItems, type MentionItem } from "./mentionItems";
import type { AcpmuxSessionEntry } from "./sessionList";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "customElements",
    "HTMLTemplateElement",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // The file-type icon set (@pierre/trees) registers its tree element when it loads.
    customElements: dom.window.customElements,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
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
  // Every row has an icon: a chat, a folder, and a file's type.
  for (const row of rows(container)) expect(row.querySelector("[data-mention-icon]")).not.toBeNull();
  expect(file!.querySelector("[data-mention-icon]")?.getAttribute("data-mention-icon")).toBe("file");
  // A file's icon is its type's, once the icon module lands: YAML, Python, TOML's default.
  await act(async () => {
    await import("./changes/FileTypeIcon");
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const types = rows(container)
    .filter((row) => row.dataset.mentionKind === "file")
    .map((row) => row.querySelector("svg[data-icon]")?.getAttribute("data-icon"));
  expect(types.slice(0, 2)).toEqual(["yml", "python"]);
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
