import type { MachineResources } from "../src/agent-session/acpmux/machineResources";
// Saved environments on the New Tab page (preview, `labs.previewFeatures`), rebuilt from #20831 on
// the environment picker of #22131: the host keeps named environments (`environment.list`,
// `environment.save`, `environment.remove`), the picker lists them in a Saved section over the
// machines, and a prompt with one picked starts on its machine, in its folder there, or on this
// computer in a new worktree of its folder. Create environment opens an inline panel.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "PointerEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "addEventListener",
  "removeEventListener",
  "dispatchEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const kept = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    HTMLTextAreaElement: dom.window.HTMLTextAreaElement,
    Element: dom.window.Element,
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
    // Milkdown (the field's editor) times its setup with global CustomEvents on the global
    // target: they are jsdom's here, so the target is jsdom's window too.
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    dispatchEvent: dom.window.dispatchEvent.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of kept) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const APP = "/Users/you/src/app";
const API = "/Users/you/src/api";
const WORKTREE = "/Users/you/wt/api-blue-fox";
const SAVED = [
  { id: "s1", name: "Devbox API", kind: "ssh", host: "devbox", folder: "/srv/api", updatedAt: 3 },
  { id: "l1", name: "API worktree", kind: "local", folder: API, worktree: true, updatedAt: 2 },
  { id: "l2", name: "Web", kind: "local", folder: APP, updatedAt: 1 },
];

type Call = { method: string; params?: Record<string, unknown> };

/// The New Tab page over a mock host: the actions App builds (screenActions, New Worktree, the
/// folder check) on a `callNative` that answers the environment, worktree and folder methods and
/// records every call.
async function mount({
  previews = true,
  worktree = "ok",
  tabCwd = "/Users/you",
  peerStart = "ok",
  peerResources,
  onNewWorktree: onNewWorktreeOverride,
  runMode,
  cloudRefusal,
  cloudStarting,
  cloudFolder,
  notOffered,
}: {
  /// Run as shows (a Cloud pick App refuses), but Cloud is not offered now.
  notOffered?: boolean;
  cloudStarting?: boolean;
  /// A folder whose newest chat went to Cloud (runLocationDefault.ts): its run location is Cloud.
  cloudFolder?: string;
  /// The Run as mode App holds (its folder default or a pick); calls record `runMode.*` and Cloud starts.
  runMode?: "persistent" | "cloud" | "sandboxed";
  /// What App's Cloud start says when it refuses (attachments, Cloud not offered now).
  cloudRefusal?: string;
  previews?: boolean;
  worktree?: "ok" | "refused";
  tabCwd?: string;
  peerStart?: "ok" | "refused" | "none";
  peerResources?: Record<string, MachineResources>;
  onNewWorktree?: (cwd: string) => Promise<string | undefined>;
} = {}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { SignInContext } = await import("../src/agent-session/acpmux/signIn");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { newWorktree, pickFolder } = await import("../src/agent-session/acpmux/startFolder");
  const calls: Call[] = [];
  const callNative = async (method: string, params?: Record<string, unknown>) => {
    calls.push({ method, ...(params ? { params } : {}) });
    switch (method) {
      case "chat.new":
        // The App's `chat.new` resolves to the chat it started (none when nothing started).
        if (params?.peer && peerStart === "refused") throw new Error("devbox is not connected");
        if (params?.peer && peerStart === "none") return undefined;
        return "session-1";
      case "environment.list":
        return { environments: SAVED };
      case "environment.save": {
        const environment = params!.environment as Record<string, unknown>;
        return { environment: { ...environment, id: "new-1", updatedAt: 9 } };
      }
      case "git.worktree.create":
        if (worktree === "refused") throw new Error("not a git repository");
        return { value: { root: WORKTREE, branch: "cmux/chat-1a2b" } };
      case "workspace.useFolder":
        return { status: "ok", cwd: params?.cwd };
      default:
        return undefined;
    }
  };
  const noop = () => {};
  const { cloudFolders } = await import("../src/agent-session/acpmux/runLocationDefault");
  // The folder's copy on a Cloud machine, as a Cloud start makes it.
  const cloudHistory = cloudFolder
    ? [
        {
          sessionId: "cloud-history",
          cwd: [...cloudFolders(cloudFolder)][0]!,
          host: "cloud-1",
          hostKind: "cloud" as const,
          createdAt: 1,
          updatedAt: 1,
        },
      ]
    : [];
  const runRows = runMode && {
    cloudOffered: !notOffered,
    runMode: {
      mode: runMode,
      onMode: (mode: string) => calls.push({ method: "runMode.pick", params: { mode } }),
      onDefault: () => calls.push({ method: "runMode.default" }),
    },
    onCloud: (agent: string, prompt: string, cwd?: string) => {
      calls.push({ method: "cloud.start", params: { agent, prompt, ...(cwd ? { cwd } : {}) } });
      return cloudRefusal ?? true;
    },
    onSandbox: (agent: string, prompt: string) => {
      calls.push({ method: "sandbox.start", params: { agent, prompt } });
      return true;
    },
  };
  const actions = newTabScreenActions({
    callNative,
    cwd: tabCwd,
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
    requestFolder: (cwd, start) => void pickFolder(callNative, cwd, start),
  });
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SignInContext.Provider
        value={{
          signedOut: {},
          logIn: noop,
          readSessionAuth: async (query) => {
            calls.push({ method: "session.auth", params: query });
            return { state: "unknown", source: "authCheck" };
          },
        }}
      >
        <NewTabScreen
          snapshot={noChat([], {
            peers: ["devbox", "cloud-1"],
            peerKinds: { devbox: "ssh", "cloud-1": "cloud" },
            ...(peerResources ? { peerResources } : {}),
          })}
          lastAgent="claude"
          cwd={tabCwd}
          projects={[
            { cwd: APP, label: "app" },
            { cwd: API, label: "api" },
          ]}
          environments={previews}
          onConnect={noop}
          onNewWorktree={(cwd) => {
            let folder: string | undefined;
            return newWorktree(callNative, cwd, (used) => {
              folder = used;
            }).then(() => folder);
          }}
          {...actions}
        />
      </SignInContext.Provider>,
    ),
  );
  await settle();
  return calls;
}

const doc = () => dom.window.document;
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const $ = <T extends Element = HTMLElement>(selector: string) => doc().querySelector<T>(selector);
const $$ = (selector: string) => [...doc().querySelectorAll<HTMLElement>(selector)];
const click = async (element: Element | null | undefined) => {
  expect(element).toBeTruthy();
  await act(async () => {
    element!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    (element as HTMLElement).click();
  });
  await settle();
};
const type = async (input: HTMLInputElement | HTMLTextAreaElement | null, text: string) => {
  expect(input).toBeTruthy();
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")!.set!;
  await act(async () => {
    setValue.call(input, text);
    input!.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await settle();
};
const environmentButton = () =>
  [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find((button) =>
    (button.getAttribute("aria-label") ?? "").startsWith(t("composer.environment") + ":"),
  );
const folderButton = () =>
  host.querySelector<HTMLButtonElement>(`.acpmux-composer-context button[aria-label="${t("composer.folder")}"]`);
const rows = () => $$(".acpmux-env-popover .acpmux-menu-item");
const row = (text: string) => rows().find((item) => item.querySelector(".acpmux-menu-label")?.textContent === text);
/// The environment control's right-click menu (Create and Edit environment, the setup actions).
const moreMenu = async () => {
  await act(async () =>
    environmentButton()!.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  return $$('[role="menu"] [role="menuitem"]');
};
const moreItem = async (text: string) => (await moreMenu()).find((item) => item.textContent === text);
/// Every machine and saved environment: Machines… on the control's right-click menu (the main list
/// is This Mac and Cloud).
const openMachines = async () => {
  const item = (await moreMenu()).find((candidate) => candidate.textContent === t("composer.machinesList"));
  expect(item, "no Machines… item").toBeTruthy();
  await act(async () => item!.click());
  await settle();
};
/// The New Tab prompt (the composer's Markdown field), once its editor is made.
const prompt = async () => {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field");
  expect(field).toBeTruthy();
  for (let turn = 0; turn < 200 && !(field!.acpmuxMarkdownField && field!.querySelector("[contenteditable]")); turn++)
    await settle();
  return field!;
};
const typePrompt = async (text: string) => {
  const field = await prompt();
  await act(async () => {
    field.acpmuxMarkdownField!.focus();
    field.acpmuxMarkdownField!.type(text);
  });
  await settle();
  return field.querySelector<HTMLElement>("[contenteditable]")!;
};
const ask = async (text: string) => {
  const editor = await typePrompt(text);
  await act(async () => {
    editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await settle();
};
const started = (calls: Call[]) =>
  calls.filter((call) => ["git.worktree.create", "workspace.useFolder", "chat.new", "chat.send"].includes(call.method));

test("previews off: no saved environments and the host is not asked", async () => {
  const calls = await mount({ previews: false });
  expect(calls.some((call) => call.method.startsWith("environment."))).toBe(false);
  expect(environmentButton()).toBeUndefined();
});

test("the saved environments are in Machines…, under This Mac; the main list is This Mac and Cloud", async () => {
  const calls = await mount();
  expect(calls.filter((call) => call.method === "environment.list")).toEqual([
    { method: "environment.list", params: {} },
  ]);
  // Leo, 2026-10-31: "it's just a cloud button". The main list names no saved environment.
  await click(environmentButton());
  expect(rows().filter((item) => item.querySelector(".acpmux-env-saved"))).toHaveLength(0);
  await click(environmentButton());
  await openMachines();
  const saved = rows().filter((item) => item.querySelector(".acpmux-env-saved"));
  expect(saved.map((item) => item.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "Devbox API",
    "API worktree",
    "Web",
  ]);
  // No header over them; This Mac is first and keeps ⌥⌘1.
  expect(doc().querySelectorAll(".acpmux-env-popover [data-section]")).toHaveLength(0);
  expect(rows()[0]!.querySelector(".acpmux-env-key")?.textContent).toBe("⌥⌘1");
  // Create environment is the control's right-click menu's, not a row of the list.
  expect(row(t("environment.create"))).toBeUndefined();
  const more = (await moreMenu()).map((item) => item.textContent);
  expect(more).toContain(t("environment.create"));
  // No Edit environment until one is picked.
  expect(more).not.toContain(t("environment.edit"));
});

test("a saved SSH environment names the strip and asks on its machine, in its folder there", async () => {
  const calls = await mount();
  await openMachines();
  await click(row("Devbox API"));
  expect(calls.filter((call) => call.method === "session.auth").at(-1)?.params).toEqual({
    target: { harness: "claude", host: "devbox", cwd: "/srv/api" },
  });
  expect(environmentButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: Devbox API`);
  // The environment names where the chat starts: no folder control beside it.
  expect(folderButton()).toBeNull();
  await ask("tail the logs");
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({
    harness: "claude",
    cwd: "/srv/api",
    peer: "devbox",
  });
  // Another machine's folder is not this Mac's: no local folder check, no worktree.
  expect(calls.some((call) => call.method === "workspace.useFolder")).toBe(false);
  expect(calls.some((call) => call.method === "git.worktree.create")).toBe(false);
  expect(calls.find((call) => call.method === "chat.send")?.params).toEqual({
    text: "tail the logs",
    expectedSessionId: "session-1",
    accepted: expect.any(Function),
  });
});

test("a saved local environment with Use worktree asks in a new worktree of its folder", async () => {
  const calls = await mount();
  await openMachines();
  await click(row("API worktree"));
  expect(calls.filter((call) => call.method === "session.auth").at(-1)?.params).toEqual({
    target: { harness: "claude", cwd: API },
  });
  await ask("fix the build");
  expect(started(calls).map((call) => call.method)).toEqual([
    "git.worktree.create",
    "workspace.useFolder",
    "workspace.useFolder",
    "chat.new",
    "chat.send",
  ]);
  expect(started(calls)[0]!.params?.cwd).toBe(API);
  const asked = calls.find((call) => call.method === "chat.new")!.params!;
  expect(asked).toMatchObject({ harness: "claude", cwd: WORKTREE });
  expect(asked.peer).toBeUndefined();
});

test("a refused worktree shows the host's reason, starts nothing and keeps the prompt", async () => {
  const calls = await mount({ worktree: "refused" });
  await openMachines();
  await click(row("API worktree"));
  await ask("fix the build");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("not a git repository");
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
  expect(host.querySelector<MarkdownFieldElement>(".nt-field")?.acpmuxMarkdownField?.value()).toBe("fix the build");
});

test("picking a machine instead clears the saved environment", async () => {
  await mount();
  await openMachines();
  await click(row("Web"));
  expect(folderButton()).toBeNull();
  await openMachines();
  // The machine rows: this computer is the only one a New Tab chat lists.
  const machine = rows().find((item) => item.querySelector(".acpmux-env-key"));
  await click(machine);
  expect(environmentButton()?.getAttribute("aria-label")).not.toContain("Web");
  expect(folderButton()).not.toBeNull();
});

test("picking another machine acpmux lists starts the chat there", async () => {
  const calls = await mount();
  await openMachines();
  await click(row("devbox"));
  expect(calls.filter((call) => call.method === "session.auth").at(-1)?.params).toEqual({
    target: { harness: "claude", host: "devbox" },
  });
  expect(environmentButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: devbox`);
  // The prompt takes the keyboard back, as after a folder pick.
  expect(doc().activeElement).toBe(host.querySelector(".nt-field [contenteditable]"));
  await ask("tail the logs");
  const asked = calls.find((call) => call.method === "chat.new")!.params!;
  expect(asked).toMatchObject({ harness: "claude", peer: "devbox" });
  // Another machine's folder is not this Mac's: no local folder check.
  expect(calls.some((call) => call.method === "workspace.useFolder")).toBe(false);
  expect(calls.find((call) => call.method === "chat.send")?.params).toEqual({
    text: "tail the logs",
    expectedSessionId: "session-1",
    accepted: expect.any(Function),
  });
});

test("the New Tab Computer menu carries cached machine health into its warning row", async () => {
  await mount({
    previews: false,
    peerResources: {
      devbox: { ramFreeGB: 1.2, coresBusy: 14, cores: 10, busy: true, lowMemory: true },
    },
  });
  const computer = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find((button) =>
    (button.getAttribute("aria-label") ?? "").startsWith(t("composer.computer")),
  );
  await click(computer);
  const machine = $$(".acpmux-location-menu .acpmux-menu-item").find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "devbox",
  );
  expect(machine).toBeDefined();
  expect(machine?.querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBe("true");
  expect(machine?.querySelector(".acpmux-menu-description")?.textContent).toBe(
    t("composer.machineHighLoad", { busy: 14, cores: 10 }),
  );
});

test("a chat started on another machine with no folder there does not take this tab's folder", async () => {
  const { newSessionHost, newSessionParams } = await import("../src/agent-session/acpmux/direct");
  const tab = { cwd: "/Users/you/src/app" };
  expect(newSessionParams(newSessionHost(tab, undefined, "devbox", false), "claude")).toEqual({
    mcpServers: [],
    _meta: { acpmux: { harness: "claude", peer: "devbox" } },
  });
  expect(newSessionHost(tab, "/srv/api", "devbox", false)).toEqual({ cwd: "/srv/api", peer: "devbox" });
  // This Mac with no folder picked still starts in the tab's.
  expect(newSessionHost(tab, undefined, undefined, false)).toEqual({ cwd: "/Users/you/src/app", peer: undefined });
});

test("a machine picked after a saved environment is where the chat starts", async () => {
  const calls = await mount();
  await openMachines();
  await click(row("Web"));
  await openMachines();
  await click(row("devbox"));
  await ask("tail the logs");
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({ peer: "devbox" });
});

test("picking this Mac again after another machine starts the chat here", async () => {
  const calls = await mount();
  await openMachines();
  await click(row("devbox"));
  await openMachines();
  await click(rows().find((item) => item.querySelector('.acpmux-env-row[data-kind="local"]')));
  await ask("fix the build");
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBeUndefined();
});

test("Create environment saves where the page would start and picks it", async () => {
  const calls = await mount();
  await click(await moreItem(t("environment.create")));
  expect($(".acpmux-env-panel")).not.toBeNull();
  await type($<HTMLInputElement>(".acpmux-env-panel input"), "  Sandbox  ");
  // Use worktree is offered for a folder on this computer.
  const folderPick = $$(".acpmux-env-panel .acpmux-location-button")[0];
  await click(folderPick);
  await click($$(".acpmux-menu-item").find((item) => item.textContent?.includes("api")));
  await click($<HTMLInputElement>(".acpmux-env-check input"));
  await click($$(".acpmux-env-panel button").find((button) => button.textContent === t("environment.create")));
  expect(calls.find((call) => call.method === "environment.save")?.params).toEqual({
    environment: { name: "Sandbox", kind: "local", folder: API, worktree: true },
  });
  expect($(".acpmux-env-panel")).toBeNull();
  expect(environmentButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: Sandbox`);
  // Picked: Edit environment opens it again, with Remove.
  await click(await moreItem(t("environment.edit")));
  expect($<HTMLInputElement>(".acpmux-env-panel input")?.value).toBe("Sandbox");
  await click($$(".acpmux-env-panel button").find((button) => button.textContent === t("environment.remove")));
  expect(calls.find((call) => call.method === "environment.remove")?.params).toEqual({
    id: "new-1",
  });
  expect($(".acpmux-env-panel")).toBeNull();
  expect(folderButton()).not.toBeNull();
});

test("a draft keeps only its kind's fields", async () => {
  const { savedEnvironmentToSave, savedEnvironmentReady } = await import("../src/agent-session/acpmux/environments");
  expect(
    savedEnvironmentToSave({
      name: " Box ",
      kind: "ssh",
      host: "devbox",
      folder: " /srv ",
      worktree: true,
    }),
  ).toEqual({ name: "Box", kind: "ssh", host: "devbox", folder: "/srv" });
  expect(savedEnvironmentToSave({ name: "Mac", kind: "local", host: "devbox", worktree: true })).toEqual({
    name: "Mac",
    kind: "local",
  });
  expect(savedEnvironmentReady({ name: "Box", kind: "ssh" })).toBe(false);
  expect(savedEnvironmentReady({ name: "Mac", kind: "local", folder: "src/app" })).toBe(false);
  expect(savedEnvironmentReady({ name: "Mac", kind: "local", folder: "~/src/app" })).toBe(true);
});

test("a saved local environment starts in its folder even when the tab already sits there", async () => {
  const calls = await mount({ tabCwd: APP });
  await openMachines();
  await click(row("Web"));
  await ask("run the tests");
  expect(calls.find((call) => call.method === "workspace.useFolder")?.params).toEqual({ cwd: APP });
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({ cwd: APP });
});

test("a start the SSH machine refused sends the prompt nowhere", async () => {
  const calls = await mount({ peerStart: "refused" });
  await openMachines();
  await click(row("Devbox API"));
  await ask("tail the logs");
  expect(calls.some((call) => call.method === "chat.new")).toBe(true);
  expect(calls.some((call) => call.method === "chat.send")).toBe(false);
});

test("New chat after a refused worktree leaves the page's create buttons working", async () => {
  const calls = await mount({ worktree: "refused" });
  await openMachines();
  await click(row("API worktree"));
  await typePrompt("fix the build");
  await click(host.querySelector('[data-create="chat"]'));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("not a git repository");
  await click(host.querySelector('[data-create="terminal"]'));
  expect(calls.some((call) => call.method === "tab.open")).toBe(true);
});

test("a start the SSH machine held without a chat sends the prompt nowhere", async () => {
  const calls = await mount({ peerStart: "none" });
  await openMachines();
  await click(row("Devbox API"));
  await ask("tail the logs");
  expect(calls.some((call) => call.method === "chat.new")).toBe(true);
  expect(calls.some((call) => call.method === "chat.send")).toBe(false);
});

test("a chat started on another machine starts on the model the page showed", async () => {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const calls: Call[] = [];
  const noop = () => {};
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push({ method, ...(params ? { params } : {}) });
      return method === "chat.new" ? "session-1" : undefined;
    },
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  actions.onAsk("claude", "tail the logs", undefined, "claude-opus-5-5", undefined, undefined, { peer: "devbox" });
  await settle();
  expect(calls.find((call) => call.method === "chat.new")?.params).toEqual({
    harness: "claude",
    model: "claude-opus-5-5",
    peer: "devbox",
  });
});

test("Auto previews the remote destination without showing the local folder it will not send", async () => {
  const calls = await mount({ tabCwd: APP });
  await type(host.querySelector<HTMLTextAreaElement>(".nt-field"), "Build in cloud");
  expect(environmentButton()?.getAttribute("aria-label")).toBe(
    `${t("composer.environment")}: ${t("composer.auto")} · cloud-1`,
  );
  expect(host.querySelector(".acpmux-composer-context")?.textContent).not.toContain("app");
  await ask("Build in cloud");
  const launch = calls.find((call) => call.method === "chat.new");
  expect(launch?.params?.peer).toBe("cloud-1");
  expect(launch?.params?.cwd).toBeUndefined();
});

test("preview features off keeps a cloud-keyword prompt on the displayed local machine", async () => {
  const calls = await mount({ previews: false, tabCwd: APP });
  await ask("Build in cloud");
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBeUndefined();
});

test("Auto keeps an ordinary coding prompt on this Mac", async () => {
  const calls = await mount({ tabCwd: APP });
  await type(host.querySelector<HTMLTextAreaElement>(".nt-field"), "Fix the build error in this repo");
  expect(environmentButton()?.textContent).toContain(t("composer.thisMac"));
  await ask("Fix the build error in this repo");
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({ harness: "claude" });
  // Local creation inherits the tab folder; no cwd override is needed.
  expect(calls.find((call) => call.method === "chat.new")?.params?.cwd).toBeUndefined();
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBeUndefined();
});

test("Auto selection wins over a pending New Worktree reply", async () => {
  const replies: ((folder: string) => void)[] = [];
  const calls = await mount({
    onNewWorktree: () => new Promise<string | undefined>((resolve) => replies.push(resolve)),
  });
  await click(folderButton());
  await click($$(".acpmux-folder-popover .acpmux-menu-item").find((item) => item.textContent?.includes("api")));
  const worktree = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find(
    (button) => button.textContent?.trim() === t("worktree.new"),
  );
  await click(worktree);
  expect(replies).toHaveLength(1);
  await click(environmentButton());
  await click(row(t("composer.auto")));
  await act(async () => replies[0]!(WORKTREE));
  await settle();
  expect(environmentButton()?.textContent).toContain(t("composer.auto"));
  await ask("fix the button");
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({ cwd: API });
  expect(calls.find((call) => call.method === "chat.new")?.params?.cwd).not.toBe(WORKTREE);
});

test.each([false, true])("Auto cancels a pending saved worktree launch (reject: %s)", async (reject) => {
  let finish!: () => void;
  const calls = await mount({
    onNewWorktree: () =>
      new Promise<string | undefined>((resolve, fail) => {
        finish = () => (reject ? fail(new Error("stale worktree failure")) : resolve(WORKTREE));
      }),
  });
  await click(environmentButton());
  await click(row("API worktree"));
  await ask("fix the button");
  await click(environmentButton());
  await click(row(t("composer.auto")));
  await act(async () => finish());
  await settle();
  expect(environmentButton()?.textContent).toContain(t("composer.auto"));
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
  expect(host.querySelector('[role="alert"]')).toBeNull();
  await ask("fix the button");
  const chats = calls.filter((call) => call.method === "chat.new");
  expect(chats).toHaveLength(1);
  expect(chats[0]?.params?.cwd).not.toBe(WORKTREE);
  expect(chats[0]?.params?.peer).toBeUndefined();
});

// The fold of #26151 into the run location (#26920): Auto is the folder's run location (App's Run as
// mode under no pick), and only a prompt that asks for a destination moves it.
test("Auto with the folder's Cloud default sends an ordinary prompt to Cloud, even one that says here", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "cloud", cloudFolder: APP });
  await type(host.querySelector<HTMLTextAreaElement>(".nt-field"), "Fix the bug here");
  expect(environmentButton()?.getAttribute("aria-label")).toBe(
    `${t("composer.environment")}: ${t("composer.auto")} · ${t("composer.cloud")}`,
  );
  await ask("Fix the bug here");
  expect(calls.find((call) => call.method === "cloud.start")?.params).toMatchObject({ prompt: "Fix the bug here" });
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
});

test.each([
  ["Run the tests on devbox", "devbox"],
  ["Run the tests locally", undefined],
])("Auto with the folder's Cloud default: %p goes where it asks, not to Cloud", async (prompt, peer) => {
  const calls = await mount({ tabCwd: APP, runMode: "cloud", cloudFolder: APP });
  await ask(prompt);
  expect(calls.some((call) => call.method === "cloud.start")).toBe(false);
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBe(peer);
});

test("Auto maps an ask for cloud work to the Cloud row, not a listed Cloud machine", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "persistent" });
  await ask("Run the tests in the cloud");
  expect(calls.find((call) => call.method === "cloud.start")?.params).toMatchObject({
    prompt: "Run the tests in the cloud",
  });
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
});

test("an ordinary prompt keeps the folder's default on this Mac", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "persistent" });
  await ask("Fix the cloud sync bug");
  expect(calls.some((call) => call.method === "cloud.start")).toBe(false);
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBeUndefined();
});

test("a folder pick keeps Auto; Auto picked again asks App for the folder's default", async () => {
  const calls = await mount({ runMode: "persistent" });
  await click(folderButton());
  await click($$(".acpmux-folder-popover .acpmux-menu-item").find((item) => item.textContent?.includes("api")));
  expect(environmentButton()?.getAttribute("aria-label")).toContain(t("composer.auto"));
  await click(environmentButton());
  await click(row(t("composer.auto")));
  expect(calls.filter((call) => call.method.startsWith("runMode."))).toEqual([{ method: "runMode.default" }]);
});

test("a Run as pick ends Auto: Cloud picked sends there whatever the prompt says", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "cloud" });
  await click(environmentButton());
  await click(
    host.ownerDocument.querySelector('.acpmux-env-popover [data-mode="cloud"]')?.closest(".acpmux-menu-item"),
  );
  expect(calls.filter((call) => call.method.startsWith("runMode."))).toEqual([
    { method: "runMode.pick", params: { mode: "cloud" } },
  ]);
  expect(environmentButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: ${t("composer.cloud")}`);
  await ask("Run the tests on devbox");
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
  expect(calls.find((call) => call.method === "cloud.start")?.params).toMatchObject({
    prompt: "Run the tests on devbox",
  });
});

test("Sandboxed carried into the tab is a pick: no Auto, and the prompt runs Sandboxed", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "sandboxed" });
  expect(environmentButton()?.getAttribute("aria-label")).toBe(
    `${t("composer.environment")}: ${t("composer.sandboxed")}`,
  );
  await ask("Run the tests on devbox");
  expect(calls.find((call) => call.method === "sandbox.start")?.params).toMatchObject({
    prompt: "Run the tests on devbox",
  });
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
});

test("a Cloud refusal for a prompt Auto sent to Cloud is said over the box, with Run as still Persistent", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "persistent", cloudRefusal: "Cloud can't take attachments yet." });
  await ask("Run the tests in the cloud");
  expect(calls.some((call) => call.method === "cloud.start")).toBe(true);
  expect(host.querySelector('.acpmux-switch-notice [role="alert"]')?.textContent).toBe(
    "Cloud can't take attachments yet.",
  );
  expect(host.querySelector<HTMLTextAreaElement>(".nt-field")?.value).toBe("Run the tests in the cloud");
});

test("This Mac picked under Auto is a pick: Run as becomes a Persistent pick and a cloud ask stays here", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "persistent" });
  await click(environmentButton());
  await click(row(t("composer.thisMac")));
  expect(calls.filter((call) => call.method.startsWith("runMode."))).toContainEqual({
    method: "runMode.pick",
    params: { mode: "persistent" },
  });
  expect(environmentButton()?.getAttribute("aria-label")).not.toContain(t("composer.auto"));
  await ask("Run the tests in the cloud");
  expect(calls.some((call) => call.method === "cloud.start")).toBe(false);
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBeUndefined();
});

test("while a Cloud start from the page is out, no send goes anywhere else", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "cloud", cloudFolder: APP, cloudStarting: true });
  await ask("Run the tests locally");
  expect(started(calls)).toEqual([]);
  expect(calls.some((call) => call.method === "cloud.start")).toBe(false);
  expect(host.querySelector<HTMLTextAreaElement>(".nt-field")?.value).toBe("Run the tests locally");
});

test("Auto reads the folder picked on the page: picking one whose last chat went to Cloud sends there", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "persistent", cloudFolder: API });
  await type(host.querySelector<HTMLTextAreaElement>(".nt-field"), "Fix the button");
  expect(environmentButton()?.getAttribute("aria-label")).not.toContain(t("composer.cloud"));
  await click(folderButton());
  await click($$(".acpmux-folder-popover .acpmux-menu-item").find((item) => item.textContent?.includes("api")));
  expect(environmentButton()?.getAttribute("aria-label")).toBe(
    `${t("composer.environment")}: ${t("composer.auto")} · ${t("composer.cloud")}`,
  );
  await ask("Fix the button");
  expect(calls.find((call) => call.method === "cloud.start")?.params).toMatchObject({ cwd: API });
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
});

test("without Cloud offered, a cloud ask under Auto takes a listed Cloud machine instead", async () => {
  const calls = await mount({ tabCwd: APP, runMode: "persistent", notOffered: true });
  await ask("Run the tests in the cloud");
  expect(calls.some((call) => call.method === "cloud.start")).toBe(false);
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBe("cloud-1");
});

test("a superseded SSH start never sends the retained prompt to a different chat", async () => {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const calls: Call[] = [];
  let current = true;
  let leaves = 0;
  let finish!: (session: string) => void;
  const actions = newTabScreenActions({
    callNative: (method, params) => {
      calls.push({ method, params });
      return method === "chat.new"
        ? new Promise<string>((resolve) => {
            finish = resolve;
          })
        : Promise.resolve();
    },
    startScope: () => () => current,
    leave: () => {
      leaves += 1;
    },
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  const started = Promise.resolve(
    actions.onAsk("claude", "only for A", undefined, undefined, undefined, undefined, { peer: "devbox" }),
  );
  current = false;
  finish("session-A");
  await expect(started).rejects.toThrow();
  expect(leaves).toBe(0);
  expect(calls.some((call) => call.method === "chat.send")).toBe(false);
});

test("a direct start keeps its draft until the first prompt is accepted, including a send preflight refusal", async () => {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  let left = 0;
  let refuse: (error: Error) => void = () => {};
  let finish: () => void = () => {};
  let accepted: () => void = () => {};
  const noop = () => {};
  const actions = newTabScreenActions({
    callNative: (method, params) =>
      method === "chat.send"
        ? new Promise((resolve, reject) => {
            refuse = reject;
            finish = () => resolve(undefined);
            accepted = params!.accepted as () => void;
          })
        : Promise.resolve(method === "chat.new" ? "session-1" : undefined),
    leave: () => {
      left += 1;
    },
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const pending = Promise.resolve(
    actions.onAsk("claude", "keep this draft", undefined, undefined, undefined, undefined, { peer: "devbox" }),
  );
  await Promise.resolve();
  expect(left).toBe(0);
  refuse(new Error("connection changed before send"));
  await expect(pending).rejects.toThrow("connection changed before send");
  expect(left).toBe(0);
  const retry = Promise.resolve(
    actions.onAsk("claude", "keep this draft", undefined, undefined, undefined, undefined, { peer: "devbox" }),
  );
  await Promise.resolve();
  expect(left).toBe(0);
  accepted();
  expect(left).toBe(1);
  finish();
  await retry;
  expect(left).toBe(1);
});
