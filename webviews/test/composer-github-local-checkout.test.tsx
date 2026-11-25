// A new chat on this Mac's folder menu lists the person's GitHub repositories too (githubRepos.ts), and a
// repository's pick stays on this Mac: the composer hands it to `onGitHubHere` with the folders here whose
// remote names it, so the host can use that checkout or clone it, then make the chat's worktree. A chat on
// Cloud still takes the pick as its folder `github:owner/name` for the machine to clone.
import { afterAll, beforeEach, expect, test } from "bun:test";
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
const { createGitHubPicker, useGitHubPicker } = await import("../src/agent-session/acpmux/githubRepos");
const { newWorktree } = await import("../src/agent-session/acpmux/startFolderModel");
const { forgetAddedRepos, rememberAddedRepo } = await import("../src/agent-session/acpmux/addedRepos");

// acme/api and acme/web were added as projects (Add project… → GitHub); the folder menu lists only those.
beforeEach(() => {
  forgetAddedRepos();
  rememberAddedRepo({ fullName: "acme/api", private: true }, 2);
  rememberAddedRepo({ fullName: "acme/web", private: false }, 1);
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const FOLDER = "/Users/me/app";
const CHECKOUT = "/Users/me/src/api";
const REPOS = [
  { full_name: "acme/api", private: true, default_branch: "main" },
  { full_name: "acme/web", private: false, default_branch: "main" },
];

function store() {
  const calls: string[] = [];
  const answers: Record<string, unknown> = {
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  };
  const picker = createGitHubPicker(
    async (method) => {
      calls.push(method);
      return answers[method];
    },
    () => () => {},
    () => true,
  );
  return { calls, picker };
}

async function render(props: Record<string, unknown>, picker: ReturnType<typeof createGitHubPicker>) {
  const picked: string[] = [];
  const here: [string, string[]][] = [];
  const modes: string[] = [];
  function Tray() {
    const github = useGitHubPicker(picker);
    return (
      <ComposerContext
        summary={{ sessionId: "", cwd: FOLDER }}
        projectChoices={[
          { cwd: FOLDER, label: "app" },
          // This Mac's checkout of acme/api, as `project.list` names its GitHub origin.
          { cwd: CHECKOUT, label: "api", repo: { root: CHECKOUT, name: "api", github: "acme/api" } },
        ]}
        onProject={(cwd: string) => picked.push(cwd)}
        onGitHubHere={(repo: string, candidates: string[]) => here.push([repo, candidates])}
        localName="This Mac"
        runMode={{ mode: "persistent", onMode: (mode: string) => modes.push(mode) }}
        github={github}
        {...props}
      />
    );
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Tray />));
  return { root, picked, here, modes };
}

const doc = () => dom.window.document;
const openFolderMenu = async () => {
  await act(async () => doc().querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  await settle();
};
const option = (name: string) =>
  [...doc().querySelectorAll<HTMLElement>("[role=option]")].find((item) => item.textContent?.includes(name));
const press = async (element: HTMLElement) => {
  await act(async () => element.click());
  await settle();
};

test("with This Mac picked, a repository's pick stays on this Mac; one it has a checkout of is that checkout's row", async () => {
  const { picker } = store();
  const { root, picked, here, modes } = await render({}, picker);
  try {
    await openFolderMenu();
    // acme/api has a checkout here: its one row is the checkout, with the GitHub glyph (cmux#53226).
    expect(option("acme/api")).toBeUndefined();
    expect(option("api")?.querySelector("[data-github]")).not.toBeNull();
    // A repository this Mac has no checkout of: the host clones it.
    await press(option("acme/web")!);
    expect(here).toEqual([["acme/web", []]]);
    // Not a Cloud pick: the chat stays on This Mac, and no `github:` folder goes to the start.
    expect(modes).toEqual([]);
    expect(picked).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat on this Mac that cannot run on Cloud still lists the repositories when it can check them out here", async () => {
  const { picker, calls } = store();
  const { root, here } = await render({ runMode: undefined }, picker);
  try {
    await openFolderMenu();
    // Nothing is read from GitHub for the folder menu (cmux#53226).
    expect(calls).toEqual([]);
    await press(option("acme/web")!);
    expect(here).toEqual([["acme/web", []]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("with Cloud picked the repository is still the Cloud start's folder, never this Mac's checkout", async () => {
  const { picker } = store();
  const { root, picked, here } = await render({ runMode: { mode: "cloud", onMode: () => {} } }, picker);
  try {
    await openFolderMenu();
    await press(option("acme/api")!);
    expect(picked).toEqual(["github:acme/api"]);
    expect(here).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the page asks the host for the repository's checkout and worktree in one call, then uses that worktree", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const used: string[] = [];
  const callNative = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "github.repos.checkout")
      return { value: { root: "/Users/me/.cmux/worktrees/api/lane" }, checkout: CHECKOUT, cloned: false };
    if (method === "workspace.useFolder") return { status: "ok", cwd: params.cwd };
    return undefined;
  };
  const result = await newWorktree(callNative as never, "github:acme/api", (folder) => used.push(folder), {
    repo: "acme/api",
    candidates: [CHECKOUT],
  });
  expect(calls[0]?.[0]).toBe("github.repos.checkout");
  expect(calls[0]?.[1]).toMatchObject({ repo: "acme/api", candidates: [CHECKOUT] });
  expect(typeof calls[0]?.[1].idempotency_key).toBe("string");
  // No `git.worktree.create` of its own: the host made the worktree on the same click.
  expect(calls.some(([method]) => method === "git.worktree.create")).toBe(false);
  expect(result.root).toBe("/Users/me/.cmux/worktrees/api/lane");
  expect(used).toEqual(["/Users/me/.cmux/worktrees/api/lane"]);
});

test("a repository picked with This Mac picked waits on the chip by its name, not cloning yet (cmux#53226)", async () => {
  const { picker } = store();
  const { root } = await render({ pendingRepository: "acme/web" }, picker);
  try {
    const chip = doc().querySelector<HTMLElement>(".acpmux-location-button [data-pending-repository]");
    expect(chip?.textContent?.trim()).toBe("acme/web");
    expect(doc().querySelector(".acpmux-location-button")?.getAttribute("title")).toBe("acme/web");
  } finally {
    await act(async () => root.unmount());
  }
  // While its checkout runs, the chip says so instead.
  const cloning = await render({ pendingRepository: "acme/web", cloningRepository: "acme/web" }, picker);
  try {
    expect(doc().querySelector("[data-pending-repository]")).toBeNull();
    expect(doc().querySelector(".acpmux-source-cloning")?.textContent).toContain("acme/web");
  } finally {
    await act(async () => cloning.root.unmount());
  }
});
