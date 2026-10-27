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
import { chooseEnvironmentFolder } from "../src/agent-session/acpmux/inspector/environmentActions";
import { environmentConnection, environmentToSave } from "../src/agent-session/acpmux/inspector/EnvironmentSection";
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
    HTMLInputElement: dom.window.HTMLInputElement,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    localStorage: dom.window.localStorage,
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

for (const kind of ["move", "bringBack"] as const) {
  test(`Environment opens the existing ${kind} action and keeps folder choice separate`, async () => {
    const host = installDom();
    const calls: string[] = [];
    await act(async () => {
      root = createRoot(host);
      root.render(
        <ChatInspector
          summary={chat([]).summary}
          machineName="Studio"
          environmentControls={{
            move: {
              kind,
              run: (value) => {
                calls.push(value);
              },
              refresh: () => {
                calls.push("refresh");
              },
            },
            chooseFolder: () => {
              calls.push("folder");
            },
            connection: { label: translate("composer.envConnected"), connected: true },
          }}
        />,
      );
    });
    const machine = host.querySelector<HTMLButtonElement>(".acpmux-location-button")!;
    expect(machine.getAttribute("aria-label")).toContain("Studio");
    const folder = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
      (b) => b.textContent === translate("composer.chooseFolderMenu"),
    )!;
    expect(folder.getAttribute("aria-label")).toBe(translate("chatInspector.environment.chooseFolderNewChat"));
    await act(async () => folder.click());
    expect(calls).toEqual(["folder"]);
    await act(async () => {
      machine.dispatchEvent(new dom!.window.MouseEvent("pointerdown", { bubbles: true }));
      machine.click();
    });
    expect(calls).toEqual(["folder", "refresh"]);
    const menu = dom!.window.document.querySelector(".acpmux-env-popover")!;
    const actions = [...menu.querySelectorAll<HTMLElement>(".acpmux-menu-item")].filter((row) =>
      row.querySelector(".acpmux-env-new"),
    );
    expect(actions).toHaveLength(1);
    expect(actions[0]!.textContent).toContain(
      translate(kind === "move" ? "composer.moveToCloud" : "composer.bringBackLocal"),
    );
    await act(async () => actions[0]!.click());
    expect(calls).toEqual(["folder", "refresh", kind]);
    expect(dom!.window.document.querySelector(".acpmux-env-popover")).toBeNull();
  });
}

test("Environment without supported actions has no machine or choose-folder button", async () => {
  const host = installDom();
  await act(async () => {
    root = createRoot(host);
    root.render(
      <ChatInspector
        machineName="Studio"
        environmentControls={{
          connection: { label: translate("header.disconnected"), connected: false },
        }}
      />,
    );
  });
  expect(host.querySelector(".acpmux-location-button")).toBeNull();
  expect(host.querySelector('[aria-label*="Choose folder"]')).toBeNull();
  expect(host.querySelector('[data-connected="false"]')?.textContent).toBe(translate("header.disconnected"));
});

test("Choose folder cancellation, chat changes and machine moves discard the native result", async () => {
  const before = {
    ...chat([]),
    sessionId: "session",
    summary: { ...chat([]).summary!, cwd: "/Users/you/src", host: "Studio", hostKind: "local" as const },
  };
  const opened: string[] = [];
  for (const after of [
    undefined,
    { ...before, sessionId: "other" },
    { ...before, summary: { ...before.summary, peer: "remote" } },
    { ...before, summary: { ...before.summary, host: "cloud", hostKind: "cloud" as const } },
  ]) {
    await chooseEnvironmentFolder(
      before,
      async () => "/picked",
      () => after,
      (cwd) => {
        opened.push(cwd);
      },
    );
  }
  await chooseEnvironmentFolder(
    before,
    async () => undefined,
    () => before,
    (cwd) => {
      opened.push(cwd);
    },
  );
  expect(opened).toEqual([]);
  await chooseEnvironmentFolder(
    before,
    async () => "/picked",
    () => before,
    (cwd) => {
      opened.push(cwd);
    },
  );
  expect(opened).toEqual(["/picked"]);
  expect(before.summary.cwd).toBe("/Users/you/src");
});

for (const [connection, key] of [
  ["connected", "composer.envConnected"],
  ["connecting", "rail.connectorPending"],
  ["connecting: refused", "header.reconnecting"],
  ["disconnected", "header.disconnected"],
  ["failed: permission", "header.failed"],
] as const) {
  test(`Environment describes ${connection} from the pane snapshot`, () => {
    const state = environmentConnection({ ...chat([]), connection }, translate);
    expect(state?.label).toBe(translate(key));
    expect(state?.connected).toBe(connection === "connected");
  });
}

test("normal events keep transport state; offline and unknown snapshots never claim connected", () => {
  const base = chat([]);
  for (const connection of ["attached", "history", "session changed", "permission", "turn_started"]) {
    expect(environmentConnection({ ...base, connection, transportConnected: true }, translate)?.connected).toBe(true);
  }
  expect(
    environmentConnection({ ...base, connection: "connected", transportConnected: false }, translate)?.connected,
  ).toBe(false);
  expect(environmentConnection({ ...base, connection: "unknown" }, translate)).toBeUndefined();
});

test("a trailing slash does not duplicate the primary folder", async () => {
  const host = installDom();
  const opened: string[] = [];
  await act(async () => {
    root = createRoot(host);
    root.render(
      <ChatInspector
        summary={{ ...chat([]).summary!, cwd: "/Users/you/src/atlas-web/" }}
        onOpenFolder={(path) => {
          opened.push(path);
        }}
        environmentControls={{ chooseFolder: () => undefined }}
      />,
    );
  });
  const folders = [...host.querySelectorAll<HTMLButtonElement>('button[title="/Users/you/src/atlas-web"]')];
  expect(folders).toHaveLength(1);
  expect(host.querySelectorAll(".acpmux-environment-folder")).toHaveLength(1);
  await act(async () => folders[0]!.click());
  expect(opened).toEqual(["/Users/you/src/atlas-web"]);
});

test("a disconnected peer is not shown connected just because the local transport is open", () => {
  const snapshot = {
    ...chat([]),
    connection: "session changed",
    transportConnected: true,
    summary: { ...chat([]).summary!, peer: "builder" },
    peerConnected: { builder: false },
  };
  expect(environmentConnection(snapshot, translate)).toEqual({
    label: translate("composer.envNotConnected"),
    connected: false,
  });
});

for (const connected of [true, false]) {
  test(`Environment connection accessible name includes its ${connected ? "connected" : "disconnected"} state`, async () => {
    const host = installDom();
    const label = translate(connected ? "composer.envConnected" : "header.disconnected");
    await act(async () => {
      root = createRoot(host);
      root.render(<ChatInspector environmentControls={{ connection: { connected, label } }} />);
    });
    const row = host.querySelector(".acpmux-environment-status")!.closest("li")!;
    expect(row.getAttribute("aria-label")).toBe(`${translate("inspector.connection")}: ${label}`);
  });
}

for (const canChoose of [true, false]) {
  test(`compact Environment shows the primary folder once ${canChoose ? "with" : "without"} folder choice`, async () => {
    const host = installDom();
    const opened: string[] = [];
    let choices = 0;
    let moveOpens = 0;
    await act(async () => {
      root = createRoot(host);
      root.render(
        <ChatInspector
          summary={{ ...chat([]).summary!, cwd: `${HOME}/Projects/primary-env-folder`, branch: undefined }}
          rows={[activity([read(`${HOME}/Projects/secondary-env-folder/file.ts`)], 1)]}
          machineName="Studio"
          environmentLook="compact"
          environmentControls={{
            move: canChoose
              ? {
                  kind: "move",
                  run: () => undefined,
                  refresh: () => {
                    moveOpens++;
                  },
                }
              : undefined,
            chooseFolder: canChoose
              ? () => {
                  choices++;
                }
              : undefined,
            connection: { label: translate("composer.envConnected"), connected: true },
          }}
          onOpenFolder={(path) => opened.push(path)}
        />,
      );
    });
    const environment = host.querySelector('ul[data-section="environment"]')!;
    expect(environment.textContent!.match(/primary-env-folder/g)).toHaveLength(1);
    expect(environment.querySelector("[data-machine]")!.textContent).toContain("primary-env-folder");
    expect(environment.children).toHaveLength(canChoose ? 3 : 2);
    const primary = environment.querySelector<HTMLButtonElement>(
      `[data-machine] button[title="${HOME}/Projects/primary-env-folder"]`,
    );
    expect(primary).not.toBeNull();
    expect(primary!.parentElement!.closest("button")).toBeNull();
    await act(async () => primary!.click());
    expect(opened).toEqual([`${HOME}/Projects/primary-env-folder`]);
    expect(moveOpens).toBe(0);
    expect(dom!.window.document.querySelector(".acpmux-env-popover")).toBeNull();
    const choose = environment.querySelector<HTMLButtonElement>(
      `[aria-label="${translate("chatInspector.environment.chooseFolderNewChat")}"]`,
    );
    if (canChoose) {
      await act(async () => choose!.click());
      expect(choices).toBe(1);
    } else expect(choose).toBeNull();
    const secondary = environment.querySelector<HTMLButtonElement>(
      `button[title="${HOME}/Projects/secondary-env-folder"]`,
    )!;
    await act(async () => secondary.click());
    expect(opened).toEqual([`${HOME}/Projects/primary-env-folder`, `${HOME}/Projects/secondary-env-folder`]);
  });
}
