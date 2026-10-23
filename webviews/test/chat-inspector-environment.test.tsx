// l10n-allow-file: test fixture folders and branches, not shipped UI.
// The Inspector's Environment (Claude Code desktop's): the machine with Save, then every folder the
// chat worked in (its own, then each project its tool calls touched), the repository, the branch.
// Every row does something: a folder opens in the Files tree beside the chat, the repository and the
// branch link to GitHub, Save keeps the machine and folder as a New Tab environment.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { ChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { chatFolders, projectFolder } from "../src/agent-session/acpmux/inspector/chatFolders";
import { environmentToSave } from "../src/agent-session/acpmux/inspector/EnvironmentSection";
import { resetInspectorState } from "../src/agent-session/acpmux/inspector/inspectorState";
import { translate } from "../src/agent-session/acpmux/i18n";
import { activity, chat, tool } from "../src/gallery/fixtures/acpmux";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => resetInspectorState());

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

const HOME = "/Users/leo";
const edit = (path: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path, oldText: "a\n", newText: "b\n" }] });
const read = (path: string) => tool(`Read ${path}`, "read", "completed", { locations: [{ path }] });
const run = (command: string) => tool(command, "execute", "completed", { command, output: "", exitCode: 0 });

/// A chat in ~/Projects (no repository) that worked across several projects, as Leo's do.
const projectsRows = [
  activity(
    [
      edit(`${HOME}/Projects/cmux/webviews/src/a.ts`),
      read(`${HOME}/Projects/README.md`),
      run(`cd ${HOME}/Projects/cmux-app-screenshots && ls`),
      run(`git -C "~/Projects/leo-workspace" status`),
      read(`${HOME}/.claude/CLAUDE.md`),
      read("/private/tmp/claude-501/scratch/notes.md"),
      run("cd ../elsewhere && ls"),
      edit(`${HOME}/Projects/cmux/webviews/src/b.ts`),
    ],
    3,
  ),
  activity([read(`${HOME}/Projects/glaeda/main.go`)], 2),
];

test("a plain folder's chat lists itself, then each child project its tool calls touched, once, in order", () => {
  expect(chatFolders(projectsRows, `${HOME}/Projects`, false)).toEqual([
    `${HOME}/Projects`,
    `${HOME}/Projects/cmux`,
    `${HOME}/Projects/cmux-app-screenshots`,
    `${HOME}/Projects/leo-workspace`,
    `${HOME}/Projects/glaeda`,
  ]);
});

test("a repository's chat keeps its own files in it and lists the projects beside it", () => {
  const cwd = `${HOME}/Projects/cmux`;
  expect(chatFolders(projectsRows, cwd, true)).toEqual([
    cwd,
    `${HOME}/Projects/cmux-app-screenshots`,
    `${HOME}/Projects/leo-workspace`,
    `${HOME}/Projects/glaeda`,
  ]);
  // A path's project, seen from the repository.
  expect(projectFolder(`${cwd}/src/deep/file.ts`, true, cwd, true)).toBe(cwd);
  expect(projectFolder(`${HOME}/notes.md`, true, cwd, true)).toBeUndefined();
  expect(projectFolder("/opt/homebrew/etc/nginx.conf", true, cwd, true)).toBe("/opt/homebrew/etc");
  expect(projectFolder("/var/folders/x/T/tmp.txt", true, cwd, true)).toBeUndefined();
  expect(projectFolder("relative/path.ts", true, cwd, true)).toBeUndefined();
});

test("with no folder, the projects are the folders the files are in", () => {
  expect(chatFolders([activity([edit("/srv/app/main.py")], 1)], undefined, false)).toEqual(["/srv/app"]);
});

test("Save keeps this Mac or the SSH machine and the folder, named after it; a Cloud chat has none", () => {
  const base = { sessionId: "s", cwd: `${HOME}/Projects/cmux` } as Summary;
  expect(environmentToSave(base)).toEqual({ name: "cmux", kind: "local", folder: `${HOME}/Projects/cmux` });
  expect(environmentToSave({ ...base, peer: "huge-blue" }, { "huge-blue": "ssh" })).toEqual({
    name: "cmux",
    kind: "ssh",
    host: "huge-blue",
    folder: `${HOME}/Projects/cmux`,
  });
  expect(environmentToSave({ ...base, peer: "vm-1" }, { "vm-1": "cloud" })).toBeUndefined();
  expect(environmentToSave({ ...base, hostKind: "cloud", host: "build-01" })).toBeUndefined();
});

test("every Environment row does something: folders open in Files, the repository and branch link to GitHub, Save", async () => {
  const container = installDom();
  const base = chat(projectsRows);
  // A repository's chat: its own files are its folder; the projects beside it are listed after it.
  const summary: Summary = { ...base.summary!, cwd: `${HOME}/Projects/cmux`, branch: "leo/next-backgrounds" };
  const folders: string[] = [];
  let saves = 0;
  const props: ComponentProps<typeof ChatInspector> = {
    summary,
    machineName: "cosmic-gray",
    repository: "manaflow-ai/cmux",
    rows: projectsRows,
    onOpenFolder: (path) => folders.push(path),
    onSaveEnvironment: async () => {
      saves++;
    },
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<ChatInspector {...props} />);
  });
  const environment = container.querySelector<HTMLElement>('ul[data-section="environment"]')!;
  const buttons = [...environment.querySelectorAll<HTMLButtonElement>("button.acpmux-chat-inspector-row")];
  // Claude's list: the chat's folder with its parent, then each project by name.
  expect(buttons.map((button) => button.textContent)).toEqual([
    "cmux~/Projects",
    "cmux-app-screenshots",
    "leo-workspace",
    "glaeda",
  ]);
  expect(buttons[1]!.getAttribute("title")).toBe(`${HOME}/Projects/cmux-app-screenshots`);
  await act(async () => buttons[0]!.click());
  await act(async () => buttons[3]!.click());
  expect(folders).toEqual([`${HOME}/Projects/cmux`, `${HOME}/Projects/glaeda`]);

  // The repository and the branch are links, which the pane opens in the browser.
  const links = [...environment.querySelectorAll<HTMLAnchorElement>("a.acpmux-chat-inspector-row")];
  expect(links.map((link) => [link.textContent, link.getAttribute("href")])).toEqual([
    ["manaflow-ai/cmux", "https://github.com/manaflow-ai/cmux"],
    ["leo/next-backgrounds", "https://github.com/manaflow-ai/cmux/tree/leo/next-backgrounds"],
  ]);

  // Save, once: then it says Saved.
  const save = environment.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-link")!;
  expect(save.textContent).toBe(translate("chatInspector.environment.save"));
  await act(async () => save.click());
  expect(saves).toBe(1);
  expect(save.textContent).toBe(translate("artifact.saved"));
  expect(save.disabled).toBe(true);
});

test("without the App's actions the rows are plain text, and no Remote Control row is drawn", async () => {
  const container = installDom();
  const base = chat(projectsRows);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ChatInspector
        // A plain folder (no branch): each child project it touched is listed.
        summary={{ ...base.summary!, cwd: `${HOME}/Projects`, branch: undefined }}
        machineName="cosmic-gray"
        rows={projectsRows}
      />,
    );
  });
  const environment = container.querySelector<HTMLElement>('ul[data-section="environment"]')!;
  expect(environment.querySelector("button")).toBeNull();
  expect(environment.querySelector("a")).toBeNull();
  expect(environment.textContent).toContain("glaeda");
  expect(environment.textContent).not.toContain("Remote Control");
});
