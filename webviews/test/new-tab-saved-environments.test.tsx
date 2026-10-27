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
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
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
  onNewWorktree: onNewWorktreeOverride,
}: {
  previews?: boolean;
  worktree?: "ok" | "refused";
  tabCwd?: string;
  peerStart?: "ok" | "refused" | "none";
  onNewWorktree?: (cwd: string) => Promise<string | undefined>;
} = {}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
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
      <NewTabScreen
        snapshot={noChat([], {
          peers: ["devbox", "cloud-1"],
          peerKinds: { devbox: "ssh", "cloud-1": "cloud" },
        })}
        lastAgent="claude"
        cwd={tabCwd}
        projects={[
          { cwd: APP, label: "app" },
          { cwd: API, label: "api" },
        ]}
        environments={previews}
        onConnect={noop}
        onNewWorktree={
          onNewWorktreeOverride ??
          ((cwd) => {
            let folder: string | undefined;
            return newWorktree(callNative, cwd, (used) => {
              folder = used;
            }).then(() => folder);
          })
        }
        {...actions}
      />,
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
const ask = async (text: string) => {
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field");
  await type(field, text);
  await act(async () => {
    field!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
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

test("the picker lists the saved environments in a Saved section over the machines", async () => {
  const calls = await mount();
  expect(calls.filter((call) => call.method === "environment.list")).toEqual([
    { method: "environment.list", params: {} },
  ]);
  await click(environmentButton());
  const saved = rows().filter((item) => item.querySelector(".acpmux-env-saved"));
  expect(saved.map((item) => item.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "Devbox API",
    "API worktree",
    "Web",
  ]);
  expect(saved[0]!.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBe(t("composer.envSaved"));
  // The machines follow, still numbered from ⌥⌘1, and Create environment heads New environment.
  expect(
    rows()
      .find((item) => item.querySelector(".acpmux-env-key"))
      ?.querySelector(".acpmux-env-key")?.textContent,
  ).toBe("⌥⌘1");
  const created = row(t("environment.create"));
  expect(created?.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBe(t("composer.newEnvironment"));
  // No Edit environment until one is picked.
  expect(row(t("environment.edit"))).toBeUndefined();
});

test("a saved SSH environment names the strip and asks on its machine, in its folder there", async () => {
  const calls = await mount();
  await click(environmentButton());
  await click(row("Devbox API"));
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
  });
});

test("a saved local environment with Use worktree asks in a new worktree of its folder", async () => {
  const calls = await mount();
  await click(environmentButton());
  await click(row("API worktree"));
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
  await click(environmentButton());
  await click(row("API worktree"));
  await ask("fix the build");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("not a git repository");
  expect(calls.some((call) => call.method === "chat.new")).toBe(false);
  expect(host.querySelector<HTMLTextAreaElement>(".nt-field")?.value).toBe("fix the build");
});

test("picking a machine instead clears the saved environment", async () => {
  await mount();
  await click(environmentButton());
  await click(row("Web"));
  expect(folderButton()).toBeNull();
  await click(environmentButton());
  // The machine rows: this computer is the only one a New Tab chat lists.
  const machine = rows().find((item) => item.querySelector(".acpmux-env-key"));
  await click(machine);
  expect(environmentButton()?.getAttribute("aria-label")).not.toContain("Web");
  expect(folderButton()).not.toBeNull();
});

test("picking another machine acpmux lists starts the chat there", async () => {
  const calls = await mount();
  await click(environmentButton());
  await click(row("devbox"));
  expect(environmentButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: devbox`);
  // The prompt takes the keyboard back, as after a folder pick.
  expect(doc().activeElement).toBe(host.querySelector(".nt-field"));
  await ask("tail the logs");
  const asked = calls.find((call) => call.method === "chat.new")!.params!;
  expect(asked).toMatchObject({ harness: "claude", peer: "devbox" });
  // Another machine's folder is not this Mac's: no local folder check.
  expect(calls.some((call) => call.method === "workspace.useFolder")).toBe(false);
  expect(calls.find((call) => call.method === "chat.send")?.params).toEqual({ text: "tail the logs" });
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
  await click(environmentButton());
  await click(row("Web"));
  await click(environmentButton());
  await click(row("devbox"));
  await ask("tail the logs");
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({ peer: "devbox" });
});

test("picking this Mac again after another machine starts the chat here", async () => {
  const calls = await mount();
  await click(environmentButton());
  await click(row("devbox"));
  await click(environmentButton());
  await click(rows().find((item) => item.querySelector('.acpmux-env-row[data-kind="local"]')));
  await ask("fix the build");
  expect(calls.find((call) => call.method === "chat.new")?.params?.peer).toBeUndefined();
});

test("Create environment saves where the page would start and picks it", async () => {
  const calls = await mount();
  await click(environmentButton());
  await click(row(t("environment.create")));
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
  await click(environmentButton());
  await click(row(t("environment.edit")));
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
  await click(environmentButton());
  await click(row("Web"));
  await ask("run the tests");
  expect(calls.find((call) => call.method === "workspace.useFolder")?.params).toEqual({ cwd: APP });
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({ cwd: APP });
});

test("a start the SSH machine refused sends the prompt nowhere", async () => {
  const calls = await mount({ peerStart: "refused" });
  await click(environmentButton());
  await click(row("Devbox API"));
  await ask("tail the logs");
  expect(calls.some((call) => call.method === "chat.new")).toBe(true);
  expect(calls.some((call) => call.method === "chat.send")).toBe(false);
});

test("New chat after a refused worktree leaves the page's create buttons working", async () => {
  const calls = await mount({ worktree: "refused" });
  await click(environmentButton());
  await click(row("API worktree"));
  await type(host.querySelector<HTMLTextAreaElement>(".nt-field"), "fix the build");
  await click(host.querySelector('[data-create="chat"]'));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("not a git repository");
  await click(host.querySelector('[data-create="terminal"]'));
  expect(calls.some((call) => call.method === "tab.open")).toBe(true);
});

test("a start the SSH machine held without a chat sends the prompt nowhere", async () => {
  const calls = await mount({ peerStart: "none" });
  await click(environmentButton());
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
  expect(environmentButton()?.textContent).toContain("Auto · cloud-1");
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
