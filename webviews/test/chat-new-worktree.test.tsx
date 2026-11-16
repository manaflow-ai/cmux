// New Worktree (cx-lyqio.2, Codex/Conductor style): a new chat's folder menu offers a worktree of
// that folder. The host makes it on a branch of its own (`git.worktree.create`), and the chat
// starts there through the same path as a picked folder (`workspace.useFolder`). A refusal starts
// nothing and says why.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  DOMRect: dom.window.DOMRect,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
const { newChatInWorktree, newWorktree } = await import("../src/agent-session/acpmux/startFolderModel");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const FOLDER = "/Users/me/app";
const ROOT = "/Users/me/.cmux/worktrees/app/chat-1a2b3c";

async function renderTray(props: Record<string, unknown>) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(
      <ComposerContext
        summary={{ sessionId: "", cwd: FOLDER }}
        projectChoices={[{ cwd: FOLDER, label: "app" }]}
        onProject={() => {}}
        localName="This Mac"
        {...props}
      />,
    ),
  );
  return root;
}

const openFolderMenu = async () => {
  const button = dom.window.document.querySelector<HTMLButtonElement>(".acpmux-location-button")!;
  await act(async () => button.click());
  await settle();
};

const menuItem = (name: string) =>
  // Project actions are pinned under search, before the scrolling folders.
  [
    ...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitem], [role=option], .ui-combobox-pinned button"),
  ].find((item) => item.textContent?.includes(name));

test("a new chat's folder menu offers New Worktree for its folder", async () => {
  const asked: string[] = [];
  const root = await renderTray({ onNewWorktree: (cwd: string) => asked.push(cwd) });
  try {
    await openFolderMenu();
    const item = menuItem("New Worktree");
    expect(item).toBeDefined();
    await act(async () => item!.click());
    await settle();
    expect(asked).toEqual([FOLDER]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat without a folder of its own offers no worktree", async () => {
  const root = await renderTray({ summary: { sessionId: "" }, projectChoices: [], onNewWorktree: () => {} });
  try {
    await openFolderMenu();
    expect(menuItem("New Worktree")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("New Worktree makes the worktree from the folder and starts the chat in it", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const native = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "git.worktree.create")
      return { value: { root: ROOT, branch: "cmux/chat-1a2b3c", base: "main" }, replayed: false };
    if (method === "workspace.useFolder") return { status: "ok", cwd: params?.cwd };
    throw new Error(`unexpected ${method}`);
  };
  const used: string[] = [];
  const made = await newWorktree(native, FOLDER, (cwd) => used.push(cwd));
  expect(made).toEqual({ root: ROOT, branch: "cmux/chat-1a2b3c" });
  expect(calls.map(([method]) => method)).toEqual(["git.worktree.create", "workspace.useFolder"]);
  expect(calls[0]![1]?.cwd).toBe(FOLDER);
  expect(typeof calls[0]![1]?.idempotency_key).toBe("string");
  expect(calls[1]![1]).toEqual({ cwd: ROOT });
  expect(used).toEqual([ROOT]);
});

test("a refused worktree starts nothing and says why", async () => {
  const calls: string[] = [];
  const native = async (method: string) => {
    calls.push(method);
    throw Object.assign(new Error("main names no commit to branch from"), { code: "native.failed" });
  };
  const used: string[] = [];
  await expect(newWorktree(native, FOLDER, (cwd) => used.push(cwd))).rejects.toThrow(
    "main names no commit to branch from",
  );
  expect(calls).toEqual(["git.worktree.create"]);
  expect(used).toEqual([]);
});

test("the refusal names the session host's reason, not the pane's generic failure", async () => {
  const native = async () => {
    throw Object.assign(new Error("The commit or push did not go through."), {
      code: "operation.failed",
      details: { reason: "not_a_repository", extra: { message: "/Users/me/app is not in a git repository" } },
    });
  };
  await expect(newWorktree(native, FOLDER, () => {})).rejects.toThrow("/Users/me/app is not in a git repository");
});

// From op-next-icons: the host may ask about the worktree's folder before a chat starts there
// (`workspace.useFolder` answers confirm). New Worktree hands back that question for the pane to
// show above the composer, as a picked folder's is; nothing starts until the user answers.
test("a folder question about the worktree comes back to ask, and starts nothing yet", async () => {
  const native = async (method: string, params?: Record<string, unknown>) => {
    if (method === "git.worktree.create")
      return { value: { root: ROOT, branch: "cmux/chat-1a2b3c", base: "main" }, replayed: false };
    if (method === "workspace.useFolder") return { status: "confirm", reason: "home", cwd: params?.cwd };
    throw new Error(`unexpected ${method}`);
  };
  const used: string[] = [];
  const made = await newWorktree(native, FOLDER, (cwd) => used.push(cwd));
  expect(made).toEqual({ root: ROOT, branch: "cmux/chat-1a2b3c", ask: { cwd: ROOT, reason: "home" } });
  expect(used).toEqual([]);
});

// cmuxterm-hq#7856 ("whatever works on a local chat should work on a Cloud chat"): a new chat on a
// Cloud machine offers New Worktree for its folder there; the host makes it on that machine.
const VM_FOLDER = "/home/cmux/work/app";
const cloudSummary = { sessionId: "", cwd: VM_FOLDER, host: "kind-aqua-sandpiper", hostKind: "cloud" as const };

const anyButton = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>("button, [role=menuitem], [role=option]")].find((item) =>
    item.textContent?.includes(name),
  );

test("a new Cloud chat's folder menu offers New Worktree for its folder on that machine", async () => {
  const asked: string[] = [];
  const root = await renderTray({
    summary: cloudSummary,
    projectChoices: [],
    machineFolders: [{ cwd: VM_FOLDER, label: "app" }],
    onNewWorktree: (cwd: string) => asked.push(cwd),
  });
  try {
    await openFolderMenu();
    const item = anyButton("New Worktree");
    expect(item).toBeDefined();
    await act(async () => item!.click());
    await settle();
    expect(asked).toEqual([VM_FOLDER]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a Cloud chat offers no worktree when the page gives none", async () => {
  const root = await renderTray({
    summary: cloudSummary,
    projectChoices: [],
    machineFolders: [{ cwd: VM_FOLDER, label: "app" }],
  });
  try {
    await openFolderMenu();
    expect(anyButton("New Worktree")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a worktree made for a chat that started meanwhile opens a new chat on the same machine", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const native = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return undefined;
  };
  await newChatInWorktree(native, ROOT, false);
  await newChatInWorktree(native, "/home/cmux/.cmux/worktrees/app/chat-1", true);
  expect(calls).toEqual([
    ["chat.new", { cwd: ROOT }],
    // A Cloud or SSH chat's worktree is that machine's folder: never a chat of this Mac there.
    ["chat.newHere", { cwd: "/home/cmux/.cmux/worktrees/app/chat-1" }],
  ]);
});
