// Saved environments on the New Tab page (cx-ncc.104, Labs `savedEnvironments`): the composer
// strip's Choose environment lists the host's saved environments (`environment.list`), Local, SSH
// then Cloud, and searches them; New environment opens an inline panel whose Create environment
// saves through the host (`environment.save`, the page/host contract's shape); the picked one
// names the strip; and a prompt with it starts the chat in its first folder (through a new
// worktree when that folder says so; on its machine for SSH). With the flag off nothing shows.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "DOMRect",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "MutationObserver",
  "ResizeObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  }));
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    DOMRect: window.DOMRect,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  window.document.documentElement.removeAttribute("data-labs");
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const APP = "/Users/me/src/app";
const API = "/Users/me/src/api";
const WORKTREE = "/Users/me/.cmux/worktrees/app/chat-1a2b";

const SAVED = [
  {
    id: "c1",
    name: "Sandbox",
    kind: "cloud",
    folders: [],
    env: [],
    cloud: { network: "none", domains: [] },
    updatedAt: 3,
  },
  { id: "s1", name: "Devbox API", kind: "ssh", host: "devbox", folders: [{ path: "/srv/api" }], env: [], updatedAt: 2 },
  { id: "l1", name: "Web", kind: "local", folders: [{ path: APP }], env: [], updatedAt: 1 },
];

type Call = { method: string; params?: Record<string, unknown> };

/// The New Tab page over a mock host: the actions App builds (screenActions) on a `callNative`
/// that answers the environment, worktree and folder methods and records every call.
async function mount({ labs = true }: { labs?: boolean } = {}) {
  if (labs) window.document.documentElement.setAttribute("data-labs", "savedEnvironments");
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const calls: Call[] = [];
  const callNative = async (method: string, params?: Record<string, unknown>) => {
    calls.push({ method, ...(params ? { params } : {}) });
    switch (method) {
      case "environment.list":
        return { environments: SAVED };
      case "environment.save": {
        const environment = params!.environment as Record<string, unknown>;
        return { environment: { ...environment, id: "new-1", updatedAt: 9 } };
      }
      case "git.worktree.create":
        return { value: { root: WORKTREE, branch: "cmux/chat-1a2b" } };
      case "workspace.useFolder":
        return { status: "ok", cwd: params?.cwd };
      default:
        return undefined;
    }
  };
  const actions = newTabScreenActions({
    callNative,
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/me"
        projects={[
          { cwd: APP, label: "app" },
          { cwd: API, label: "api" },
        ]}
        {...actions}
      />,
    ),
  );
  await settle();
  return calls;
}

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const $ = <T extends Element = HTMLElement>(selector: string) => window.document.querySelector<T>(selector);
const $$ = (selector: string) => [...window.document.querySelectorAll<HTMLElement>(selector)];
const click = async (element: Element | null | undefined) => {
  expect(element).toBeTruthy();
  await act(async () => (element as HTMLElement).click());
  await settle();
};
const type = async (input: HTMLInputElement | null, text: string) => {
  expect(input).toBeTruthy();
  const setValue = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(input, text);
    input!.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await settle();
};
const option = (text: string) => $$("[role=option]").find((item) => item.textContent?.includes(text));
const environmentButton = () => $<HTMLButtonElement>('.acpmux-env-picker button[aria-label="Environment"]');
const openEnvironments = () => click(environmentButton());
const ask = async (text: string) => {
  const field = $<HTMLInputElement>(".nt-field");
  await type(field, text);
  await act(async () => {
    field!.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  await settle();
};

test("with the Labs flag off the strip offers no environment and the host is not asked", async () => {
  const calls = await mount({ labs: false });
  expect($(".acpmux-env-picker")).toBeNull();
  expect($('.acpmux-composer-context button[aria-label="Folder"]')).not.toBeNull();
  expect(calls.some((call) => call.method.startsWith("environment."))).toBe(false);
});

test("Choose environment lists the saved environments grouped Local, SSH, Cloud and searches them", async () => {
  const calls = await mount();
  expect(calls.filter((call) => call.method === "environment.list")).toEqual([
    { method: "environment.list", params: {} },
  ]);
  expect(environmentButton()?.textContent).toBe("Choose environment");
  await openEnvironments();
  const rows = $$(".acpmux-env-row");
  expect(rows.map((row) => row.textContent?.split(" ·")[0])).toEqual(["Web", "Devbox API", "Sandbox"]);
  expect(rows.map((row) => row.dataset.group)).toEqual(["Local", "SSH", "Cloud"]);
  expect(option("New environment")).toBeDefined();
  await type($<HTMLInputElement>(".acpmux-env-popover input"), "devbox");
  expect($$(".acpmux-env-row").map((row) => row.textContent?.split(" ·")[0])).toEqual(["Devbox API"]);
});

test("a new Local environment with two folders, one in a worktree, saves the contract's shape and names the strip", async () => {
  const calls = await mount();
  await openEnvironments();
  await click(option("New environment"));
  const panel = $(".acpmux-env-panel");
  expect(panel).not.toBeNull();
  await type($<HTMLInputElement>(".acpmux-env-panel input"), "  App + API  ");
  // + Add: the recent folders (`project.list`), twice.
  const addButton = () => $$(".acpmux-env-panel .acpmux-location-button").find((b) => b.textContent?.includes("Add"));
  await click(addButton());
  await click(option("app"));
  await click(addButton());
  await click(option("api"));
  expect($$(".acpmux-env-folder-name").map((name) => name.textContent)).toEqual(["app", "api"]);
  // The first folder's ⋮ menu: Use worktree.
  await click($('.acpmux-env-folder button[aria-label="Actions for app"]'));
  await click($$("[role=menuitemcheckbox]").find((item) => item.textContent?.includes("Use worktree")));
  expect($(".acpmux-env-tag")?.textContent).toBe("Worktree");
  await click($$(".acpmux-env-panel button").find((b) => b.textContent === "Create environment"));
  expect(calls.find((call) => call.method === "environment.save")?.params).toEqual({
    environment: {
      name: "App + API",
      kind: "local",
      folders: [{ path: APP, worktree: true }, { path: API }],
      env: [],
    },
  });
  // Saved: the panel closes and the strip names the environment instead of the folder and computer.
  expect($(".acpmux-env-panel")).toBeNull();
  expect(environmentButton()?.textContent).toBe("App + API");
  expect($('.acpmux-composer-context button[aria-label="Folder"]')).toBeNull();

  // A prompt with it starts in a new worktree of its first folder, with the composer's agent.
  await ask("fix the build");
  const started = calls.filter((call) =>
    ["git.worktree.create", "workspace.useFolder", "chat.new", "chat.send"].includes(call.method),
  );
  expect(started.map((call) => call.method)).toEqual([
    "git.worktree.create",
    "workspace.useFolder",
    "chat.new",
    "chat.send",
  ]);
  expect(started[0]!.params?.cwd).toBe(APP);
  // The composer's agent and the model its chip names, whatever the harness.
  expect(started[2]!.params).toMatchObject({ harness: "claude", cwd: WORKTREE });
  expect(started[2]!.params?.peer).toBeUndefined();
  expect(started[3]!.params).toEqual({ text: "fix the build" });
});

test("asking with a saved SSH environment starts the chat in its folder on its machine", async () => {
  const calls = await mount();
  await openEnvironments();
  await click(option("Devbox API"));
  expect(environmentButton()?.textContent).toBe("Devbox API");
  await ask("tail the logs");
  expect(calls.find((call) => call.method === "chat.new")?.params).toMatchObject({
    harness: "claude",
    cwd: "/srv/api",
    peer: "devbox",
  });
  // Another machine's folder is not this Mac's: no local folder check.
  expect(calls.some((call) => call.method === "workspace.useFolder")).toBe(false);
  expect(calls.some((call) => call.method === "git.worktree.create")).toBe(false);
});

test("No environment clears the pick and the strip shows the folder again", async () => {
  await mount();
  await openEnvironments();
  await click(option("Web"));
  expect($('.acpmux-composer-context button[aria-label="Folder"]')).toBeNull();
  await openEnvironments();
  await click(option("No environment"));
  expect(environmentButton()?.textContent).toBe("Choose environment");
  expect($('.acpmux-composer-context button[aria-label="Folder"]')).not.toBeNull();
});
