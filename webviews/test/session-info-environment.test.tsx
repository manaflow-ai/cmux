// l10n-allow-file: test fixture folders and branches, not shipped UI.
// Session Info's Environment (Claude Code desktop's): the machine with Save, then the chat's project
// named by its repository (never a temporary or internal folder, never a folder its tool calls
// touched), the repository, the branch. Every row does something: the project opens in the Files tree
// beside the chat, the repository and the branch link to GitHub, Save keeps the machine and folder as
// a New Tab environment. Leo, 2026-10-27: "why are these files being shown to me in the first place".
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { chatProject, internalFolder } from "../src/agent-session/acpmux/session-info/chatFolders";
import { EnvironmentSection, environmentToSave } from "../src/agent-session/acpmux/session-info/EnvironmentSection";
import { resetSessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";
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

beforeEach(() => resetSessionInfoState());

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

/// A chat that worked across several folders, as Leo's do: none of them is listed (only its project).
const projectsRows = [
  activity(
    [
      edit(`${HOME}/Projects/cmux/webviews/src/a.ts`),
      read(`${HOME}/Projects/README.md`),
      run(`cd ${HOME}/Projects/cmux-app-screenshots && ls`),
      run(`git -C "~/Projects/leo-workspace" status`),
      read(`${HOME}/.claude/CLAUDE.md`),
      read("/private/tmp/claude-501/scratch/notes.md"),
    ],
    3,
  ),
  activity([read(`${HOME}/Projects/glaeda/main.go`)], 2),
];
/// Leo's chat (2026-10-27): a harness's scratchpad, which its tool calls cd'd out of into a worktree.
const SCRATCHPAD = "/private/tmp/agent-501/-Users-leo-Projects/1d2c/scratchpad";
const scratchRows = [activity([run(`cd ${HOME}/Projects/checkouts/app--fix-login && git status`)], 1)];

const summaryAt = (cwd: string, more: Partial<Summary> = {}) => ({ sessionId: "s", cwd, ...more }) as Summary;

test("temporary and internal folders are never a project, the chat's own folder included", () => {
  for (const path of [
    SCRATCHPAD,
    "/tmp/x",
    "/private/var/folders/x/T/y",
    "/var/folders/x/T/y",
    `${HOME}/Library/Application Support/cmux/agent-home/w1`,
    HOME,
    "/",
    `${HOME}/.claude`,
    `${HOME}/Library/Caches/x.noindex/scratch`,
  ])
    expect([path, chatProject(summaryAt(path))]).toEqual([path, undefined]);
  // Not even with a branch: a temporary folder is never a project.
  expect(chatProject(summaryAt("/private/tmp/clone", { branch: "main" }))).toBeUndefined();
  expect(internalFolder(`${HOME}/.cmux/worktrees/cmux/lane`)).toBe(true);
  // A hidden folder acpmux reports in git is the project it works on: a Claude or cmux worktree.
  expect(internalFolder(`${HOME}/.cmux/worktrees/cmux/lane`, true)).toBe(false);
});

test("the project is the chat's folder, named by its repository, at its worktree's top", () => {
  expect(chatProject(summaryAt(`${HOME}/Projects/cmux/`, { branch: "main" }), "manaflow-ai/cmux")).toEqual({
    path: `${HOME}/Projects/cmux`,
    name: "cmux",
    worktree: false,
  });
  // A lane's checkout: its repository names it, not its folder.
  const lane = `${HOME}/Projects/checkouts/cmux/leo--fix`;
  expect(chatProject(summaryAt(`${lane}/webviews`, { branch: "leo/fix", worktree: lane }), "manaflow-ai/cmux")).toEqual(
    { path: lane, name: "cmux", worktree: true },
  );
  // A worktree the folder is not in says nothing about it.
  expect(chatProject(summaryAt("/srv/app", { worktree: "/srv/other" }))).toEqual({
    path: "/srv/app",
    name: "app",
    worktree: false,
  });
  expect(chatProject(undefined)).toBeUndefined();
});

test("Save keeps this Mac or the SSH machine and the folder, named after its project; a Cloud or scratch chat has none", () => {
  const base = { sessionId: "s", cwd: `${HOME}/Projects/cmux` } as Summary;
  expect(environmentToSave(base)).toEqual({ name: "cmux", kind: "local", folder: `${HOME}/Projects/cmux` });
  expect(environmentToSave({ ...base, peer: "build-box" }, { "build-box": "ssh" })).toEqual({
    name: "cmux",
    kind: "ssh",
    host: "build-box",
    folder: `${HOME}/Projects/cmux`,
  });
  // Named by its repository, from a lane's checkout.
  const lane = { ...base, cwd: `${HOME}/Projects/checkouts/cmux/leo--fix`, branch: "leo/fix" };
  expect(environmentToSave(lane, undefined, "manaflow-ai/cmux")?.name).toBe("cmux");
  expect(environmentToSave({ ...base, peer: "vm-1" }, { "vm-1": "cloud" })).toBeUndefined();
  expect(environmentToSave({ ...base, hostKind: "cloud", host: "build-01" })).toBeUndefined();
  // Leo's scratchpad chat: nothing to save.
  expect(environmentToSave({ ...base, cwd: SCRATCHPAD })).toBeUndefined();
  expect(environmentToSave({ ...base, cwd: SCRATCHPAD, peer: "build-box" }, { "build-box": "ssh" })).toBeUndefined();
});

async function renderSessionInfo(props: ComponentProps<typeof SessionInfo>): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo {...props} />);
  });
  return container.querySelector<HTMLElement>('ul[data-section="environment"]')!;
}

test("a repository's chat lists its project by name, its path only in the tooltip; it opens in Files", async () => {
  const base = chat(projectsRows);
  const folders: string[] = [];
  let saves = 0;
  const environment = await renderSessionInfo({
    summary: { ...base.summary!, cwd: `${HOME}/Projects/cmux`, branch: "leo/next-backgrounds" },
    machineName: "studio-mac",
    repository: "manaflow-ai/cmux",
    rows: projectsRows,
    onOpenFolder: (path) => folders.push(path),
    onSaveEnvironment: async () => {
      saves++;
    },
  });
  // One project row: no folder the tool calls touched, and no path text.
  const buttons = [...environment.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row")];
  expect(buttons.map((button) => button.textContent)).toEqual(["cmux"]);
  expect(environment.textContent).not.toContain("~/Projects");
  for (const touched of ["cmux-app-screenshots", "leo-workspace", "glaeda", "scratch"])
    expect(environment.textContent).not.toContain(touched);
  expect(buttons[0]!.getAttribute("title")).toBe(`${HOME}/Projects/cmux`);
  // The click asks for that folder's Files tab (App.tsx: `pane.action` Files, opened right of the chat).
  await act(async () => buttons[0]!.click());
  expect(folders).toEqual([`${HOME}/Projects/cmux`]);

  // The repository and the branch are links, which the pane opens in the browser.
  const links = [...environment.querySelectorAll<HTMLAnchorElement>("a.acpmux-session-info-row")];
  expect(links.map((link) => [link.textContent, link.getAttribute("href")])).toEqual([
    ["manaflow-ai/cmux", "https://github.com/manaflow-ai/cmux"],
    ["leo/next-backgrounds", "https://github.com/manaflow-ai/cmux/tree/leo/next-backgrounds"],
  ]);

  // Save, once: then it says Saved.
  const save = environment.querySelector<HTMLButtonElement>("button.acpmux-session-info-link")!;
  expect(save.textContent).toBe(translate("sessionInfo.environment.save"));
  await act(async () => save.click());
  expect(saves).toBe(1);
  expect(save.textContent).toBe(translate("artifact.saved"));
  expect(save.disabled).toBe(true);
});

test("a scratchpad chat lists only its machine: no folder row and no Save", async () => {
  const base = chat(scratchRows);
  const environment = await renderSessionInfo({
    summary: { ...base.summary!, cwd: SCRATCHPAD, branch: undefined, worktree: undefined },
    machineName: "studio-mac",
    rows: scratchRows,
    onOpenFolder: () => undefined,
    onSaveEnvironment: () => undefined,
  });
  expect(environment.textContent).toBe(`studio-mac${translate("composer.envLocal")}`);
  expect(environment.querySelector("button")).toBeNull();
});

// Leo, 2026-10-31: "WHY IS THERE NOTHING THAT TELLS ME IF IT'S LOCAL OR IF". The
// machine row, at the top of Session Info, says in words where the chat runs, not only a name.
test("the machine row says where the chat runs: Local, SSH or Cloud beside the machine's name", async () => {
  const container = installDom();
  root = createRoot(container);
  const base = { sessionId: "s", cwd: SCRATCHPAD } as Summary;
  const kindOf = async (summary: Summary, peerKinds?: Record<string, "ssh" | "cloud">) => {
    await act(async () =>
      root!.render(<EnvironmentSection summary={summary} machineName="studio-mac" peerKinds={peerKinds} />),
    );
    const row = container.querySelector<HTMLElement>("li[data-machine]")!;
    return [
      row.dataset.machine,
      row.querySelector(".acpmux-session-info-row__name")?.textContent,
      row.querySelector("[data-machine-kind]")?.textContent,
    ];
  };
  expect(await kindOf(base)).toEqual(["local", "studio-mac", translate("composer.envLocal")]);
  expect(await kindOf({ ...base, peer: "build-box" }, { "build-box": "ssh" })).toEqual([
    "ssh",
    "build-box",
    translate("composer.envSSH"),
  ]);
  expect(await kindOf({ ...base, peer: "vm-1" }, { "vm-1": "cloud" })).toEqual([
    "cloud",
    "vm-1",
    translate("composer.cloud"),
  ]);
  expect(await kindOf({ ...base, hostKind: "cloud", host: "build-01" })).toEqual([
    "cloud",
    "build-01",
    translate("composer.cloud"),
  ]);
});

test("without the App's actions the rows are plain text, and no Remote Control row is drawn", async () => {
  const base = chat(projectsRows);
  const environment = await renderSessionInfo({
    summary: { ...base.summary!, cwd: `${HOME}/Projects`, branch: undefined },
    machineName: "studio-mac",
    rows: projectsRows,
  });
  expect(environment.querySelector("button")).toBeNull();
  expect(environment.querySelector("a")).toBeNull();
  expect(environment.querySelector("li[title]")?.getAttribute("title")).toBe(`${HOME}/Projects`);
  expect(environment.textContent).not.toContain("glaeda");
  expect(environment.textContent).not.toContain("Remote Control");
});

test("Remote Control's row draws a pointer, not a phone outline", async () => {
  // Leo, 2026-11-01: "i think we should rethink what symbol we have for remote control at least".
  // Claude Code desktop marks its Remote Control row with a pointer; ours drew device.phone.
  const base = chat(projectsRows);
  const environment = await renderSessionInfo({
    summary: { ...base.summary!, cwd: `${HOME}/Projects`, branch: undefined },
    machineName: "studio-mac",
    rows: projectsRows,
    remoteControl: { on: true, set: () => undefined },
  });
  const row = [...environment.querySelectorAll("li")].find((li) => li.textContent?.includes("Remote Control"));
  expect(row?.querySelector("svg")?.getAttribute("data-icon")).toBe("computeruse.click");
  expect(environment.querySelector('svg[data-icon="device.phone"]')).toBeNull();
});

test("Environment Save blocks duplicates while pending and exposes a retry after rejection", async () => {
  const container = installDom();
  let attempts = 0;
  let reject!: (reason: unknown) => void;
  const onSave = () => {
    attempts++;
    return attempts === 1
      ? new Promise<void>((_resolve, fail) => {
          reject = fail;
        })
      : Promise.resolve();
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <EnvironmentSection
        summary={{ ...chat([]).summary!, cwd: "/Users/demo/Projects/atlas" }}
        machineName="Studio"
        onSave={onSave}
      />,
    );
  });
  const button = container.querySelector<HTMLButtonElement>("button.acpmux-session-info-link")!;
  await act(async () => {
    button.click();
    button.click();
  });
  expect(attempts).toBe(1);
  expect(button.disabled).toBe(true);
  expect(button.getAttribute("aria-busy")).toBe("true");
  await act(async () => reject(new TypeError("internal transport details")));
  expect(button.disabled).toBe(false);
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(
    translate("environment.saveFailed", { reason: translate("error.requestFailed") }),
  );
  expect(container.textContent).not.toContain("internal transport details");
  await act(async () => button.click());
  expect(attempts).toBe(2);
  expect(button.textContent).toBe(translate("artifact.saved"));
  expect(button.disabled).toBe(true);
  expect(container.querySelector('[role="alert"]')).toBeNull();
});

test("Environment Save also handles a synchronous callback failure", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <EnvironmentSection
        summary={{ ...chat([]).summary!, cwd: "/Users/demo/Projects/atlas" }}
        onSave={() => {
          throw new Error("fixture refusal");
        }}
      />,
    );
  });
  const button = container.querySelector<HTMLButtonElement>("button.acpmux-session-info-link")!;
  await act(async () => button.click());
  expect(button.disabled).toBe(false);
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
});

// Leo, 2026-10-29, on the composer mode menu's "Granted access" section: "What is this bottom
// fucking bullshit?" The grants moved here: each one is a row with its own Revoke.
test("what the chat was granted is listed last, each with Revoke", async () => {
  const base = chat(scratchRows);
  const revoked: string[] = [];
  const environment = await renderSessionInfo({
    summary: { ...base.summary!, cwd: SCRATCHPAD, branch: undefined, worktree: undefined },
    machineName: "studio-mac",
    rows: scratchRows,
    grants: [
      { id: "folder-trust", label: "Trusted scratchpad", onRemove: () => revoked.push("folder-trust") },
      { id: "chat-permission", label: "Allow for this chat", onRemove: () => revoked.push("chat-permission") },
    ],
  });
  const rows = [...environment.querySelectorAll<HTMLElement>("li[data-grant]")];
  expect(rows.map((row) => row.dataset.grant)).toEqual(["folder-trust", "chat-permission"]);
  expect(rows[0]!.textContent).toContain("Trusted scratchpad");
  const revoke = rows[0]!.querySelector<HTMLButtonElement>("button")!;
  expect(revoke.textContent).toBe(translate("permission.revoke"));
  expect(revoke.getAttribute("aria-label")).toBe(`${translate("permission.revoke")}: Trusted scratchpad`);
  await act(async () => revoke.click());
  await act(async () => rows[1]!.querySelector<HTMLButtonElement>("button")!.click());
  expect(revoked).toEqual(["folder-trust", "chat-permission"]);
});
