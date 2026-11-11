// l10n-allow-file: test fixtures.
// The New Tab composer, driven the way a person drives it, through every combination of its picks:
// the agent (Claude, Codex), the folder (a repository, a folder of projects like ~/Projects, No
// folder), the permission mode (the agent's default, or its widest: Bypass permissions, Full access),
// where the chat runs (this Mac, Cloud) and the account Cloud runs in (Personal, a team). Each cell
// renders the real page and the real composer chips, picks in the folder chooser and the mode menu,
// types a prompt and presses Send, then reads what the page handed the host. Leo, 2026-11-10:
// "nothing tested starting from a folder like ~/Projects i already told you to test these" /
// "THE COMBINATIONS". The Cloud checks (PR proof, hourly journey, probes) start chats from the
// command line in one small repository, so none of them crosses this page.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "HTMLElement",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "localStorage",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  class NoResize {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  Object.assign(dom.window, { ResizeObserver: NoResize });
  const { proseMirrorGlobals } = await import("../src/agent-session/acpmux/promptFieldTesting");
  Object.assign(scope, {
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: NoResize,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  // The DOM constructors the menus and App's registered elements read at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  const { setCloudTeamForTest } = await import("../src/agent-session/acpmux/cloudMachines");
  setCloudTeamForTest(undefined);
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const HOME = "/Users/me";
/// Where the page starts before any pick: a scratch folder, so every folder below is a real pick.
const SCRATCH = `${HOME}/scratch`;
const FOLDERS = {
  repository: { cwd: `${HOME}/Projects/cmux`, label: "cmux" },
  // The folder holding the person's projects, not one repository (Leo's ~/Projects).
  projects: { cwd: `${HOME}/Projects`, label: "Projects" },
  none: undefined,
} as const;
type FolderPick = keyof typeof FOLDERS;

const HARNESSES = {
  claude: {
    name: "Claude Code",
    widest: "bypassPermissions",
    widestName: "Bypass permissions",
  },
  codex: {
    name: "Codex",
    widest: "agent-full-access",
    widestName: "Full access",
  },
} as const;
type Harness = keyof typeof HARNESSES;

const TEAMS = {
  personal: { name: "Personal", personal: true },
  team: { name: "Manaflow", personal: false },
} as const;
type Team = keyof typeof TEAMS;

type Where = "this-mac" | "cloud";
type Mode = "default" | "widest";
type Cell = {
  harness: Harness;
  folder: FolderPick;
  mode: Mode;
  where: Where;
  team: Team;
};
type Call = { method: string; params: Record<string, unknown> };

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

/// Renders the New Tab page as App does, with App's own New Tab chips. Every host request (the
/// page's actions and the native host) lands in `calls`.
async function renderPage(cell: Cell, calls: Call[]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { cloudStartFolder } = await import("../src/agent-session/acpmux/cloudRun");
  const { setCloudTeamForTest } = await import("../src/agent-session/acpmux/cloudMachines");
  await import("../src/agent-session/acpmux/lastPick");
  const { noChat } = await import("../src/gallery/fixtures/acpmux");
  const { callNative } = await import("../src/agent-session/acpmux/callNative");

  // The page's actions, as the connect installs them: each call is recorded and answered.
  const record =
    (method: string) =>
    async (params: Record<string, unknown> = {}) => {
      calls.push({ method, params });
      if (method === "chat.new") return `session-${calls.length}`;
      return undefined;
    };
  (dom.window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    {
      get: (_, method) => (typeof method === "string" && /^(chat|cloud)\./.test(method) ? record(method) : undefined),
    },
  );
  setCloudTeamForTest(TEAMS[cell.team]);

  const actions = newTabScreenActions({
    callNative,
    cwd: SCRATCH,
    chatCwd: SCRATCH,
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  const projects = Object.values(FOLDERS).filter((folder) => folder !== undefined);
  // App's own onCloud (App.tsx): the harness, the folder Cloud copies (cloudStartFolder) and the model.
  const onCloud = (harness: string, text: string, cwd: string | undefined, model: string | undefined) => {
    void callNative("cloud.startChat", {
      task: text,
      harness,
      ...cloudStartFolder(cwd),
      ...(model ? { model } : {}),
    });
    return true;
  };
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <NewTabScreen
          snapshot={noChat()}
          home={HOME}
          cwd={SCRATCH}
          startCwd={SCRATCH}
          lastAgent={cell.harness}
          projects={[...projects]}
          knownProjects={[SCRATCH, ...projects.map((project) => project.cwd)]}
          pageWidgets={new Set(["projects"])}
          chips={NewTabComposerChips}
          onAsk={actions.onAsk}
          onOpen={() => {}}
          onSearch={() => {}}
          onShell={() => {}}
          onJump={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
          environments
          runMode={{
            mode: cell.where === "cloud" ? "cloud" : "persistent",
            onMode: () => {},
          }}
          onCloud={onCloud}
        />
      </QueryClientProvider>,
    ),
  );
  await settle();
}

/// The folder chooser on the page: picks the cell's folder, or No folder.
async function pickFolder(folder: FolderPick) {
  const button = host.querySelector<HTMLButtonElement>(".nt-env .acpmux-project-button");
  expect(button, "no folder chooser on the page").toBeTruthy();
  await act(async () => button!.click());
  await settle();
  const wanted = FOLDERS[folder];
  const rows = [...dom.window.document.querySelectorAll<HTMLElement>('[role="option"]')];
  const row = wanted
    ? rows.find(
        (candidate) =>
          candidate.textContent?.trim().startsWith(wanted.label) && !candidate.textContent?.includes("No folder"),
      )
    : rows.find((candidate) => candidate.textContent?.includes("No folder"));
  expect(
    row,
    `no "${wanted?.label ?? "No folder"}" row in the folder chooser: ${rows.map((r) => r.textContent).join(" | ")}`,
  ).toBeTruthy();
  await act(async () => row!.click());
  await settle();
}

/// The mode menu under the box: picks the agent's widest mode by its name.
async function pickWidestMode(harness: Harness) {
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  await settle();
  const name = HARNESSES[harness].widestName;
  const items = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")];
  const item = items.find((row) => row.textContent?.includes(name));
  expect(item, `no "${name}" in the mode menu: ${items.map((r) => r.textContent).join(" | ")}`).toBeTruthy();
  await act(async () => item!.click());
  await settle();
}

async function send(text: string) {
  const field = host.querySelector<
    HTMLElement & {
      acpmuxMarkdownField?: {
        writeText(t: string, a: number, b: number): void;
      };
    }
  >(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await settle();
  field.acpmuxMarkdownField!.writeText(text, text.length, text.length);
  await settle();
  await act(async () => host.querySelector<HTMLButtonElement>(".nt-send")!.click());
  await settle();
  await settle();
}

const CELLS: Cell[] = [];
for (const harness of Object.keys(HARNESSES) as Harness[])
  for (const folder of Object.keys(FOLDERS) as FolderPick[])
    for (const mode of ["default", "widest"] as Mode[])
      for (const where of ["this-mac", "cloud"] as Where[])
        for (const team of (where === "cloud" ? ["personal", "team"] : ["personal"]) as Team[])
          CELLS.push({ harness, folder, mode, where, team });

const cellName = (cell: Cell) =>
  [
    HARNESSES[cell.harness].name,
    cell.folder === "none" ? "No folder" : `in ${FOLDERS[cell.folder]!.cwd.replace(HOME, "~")}`,
    cell.mode === "widest" ? HARNESSES[cell.harness].widestName : "default mode",
    cell.where === "cloud" ? `Cloud (${TEAMS[cell.team].name})` : "this Mac",
  ].join(", ");

for (const cell of CELLS) {
  // A Cloud start carries no mode yet (CloudStart has no mode field; the Cloud machine starts in an
  // asking mode): manaflow-ai/cmux#40956 sends the pick. Until it lands these cells are listed, not run.
  if (cell.where === "cloud" && cell.mode === "widest") {
    test.todo(`${cellName(cell)}: the Cloud start carries the mode picked (#40956)`, () => {});
    continue;
  }
  test(cellName(cell), async () => {
    const calls: Call[] = [];
    await renderPage(cell, calls);
    await pickFolder(cell.folder);
    if (cell.mode === "widest") await pickWidestMode(cell.harness);
    const prompt = `combination ${cellName(cell)}`;
    await send(prompt);
    const folder = FOLDERS[cell.folder]?.cwd;

    if (cell.where === "cloud") {
      // Nothing starts on this Mac.
      expect(calls.filter((call) => call.method === "chat.new" || call.method === "chat.send")).toEqual([]);
      const starts = calls.filter((call) => call.method === "cloud.startChat");
      expect(starts.length).toBe(1);
      // The agent picked, and the folder picked: copied to the machine, or its home with nothing copied.
      expect(starts[0]!.params).toMatchObject({
        task: prompt,
        harness: cell.harness,
      });
      if (folder) expect(starts[0]!.params.cwd).toBe(folder);
      else expect(starts[0]!.params).toMatchObject({ home: true });
      expect(starts[0]!.params.cwd).not.toBe(SCRATCH);
      // The account the chat runs in is the app's active one: the Where control names it before Send.
      const where = host.querySelector<HTMLElement>('.acpmux-location-picker[data-kind="computer"] button');
      const named = `${where?.getAttribute("aria-label") ?? ""} ${where?.textContent ?? ""}`;
      expect(named).toContain(TEAMS[cell.team].name);
      return;
    }

    // This Mac: one chat starts, with the agent and folder picked, and takes the prompt.
    const starts = calls.filter((call) => call.method === "chat.new" && call.params.deferred !== true);
    expect(starts.length).toBe(1);
    expect(starts[0]!.params.harness).toBe(cell.harness);
    if (folder) expect(starts[0]!.params.cwd).toBe(folder);
    else expect(starts[0]!.params).toMatchObject({ noProject: true });
    const sends = calls.filter((call) => call.method === "chat.send");
    expect(sends.map((call) => call.params.text)).toEqual([prompt]);
    expect(calls.some((call) => call.method === "cloud.startChat")).toBe(false);

    const modes = calls.filter((call) => call.method === "chat.mode");
    if (cell.mode === "default") {
      expect(modes).toEqual([]);
      return;
    }
    // The mode pick goes to the chat that starts: the same agent, in the same folder, before the prompt.
    expect(modes.map((call) => call.params.modeId)).toEqual([HARNESSES[cell.harness].widest]);
    const behind = calls.filter((call) => call.method === "chat.new" && call.params.deferred === true);
    expect(behind.length).toBeGreaterThan(0);
    for (const start of behind) {
      expect(start.params.harness).toBe(cell.harness);
      expect(start.params.cwd).toBe(folder);
    }
    expect(calls.indexOf(modes[0]!)).toBeLessThan(calls.indexOf(sends[0]!));
  });
}
