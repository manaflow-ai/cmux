// A new Cloud chat's folder menu offers the person's GitHub repositories (githubRepos.ts): before the
// cmux GitHub App is installed one Connect to GitHub row connects in one click, after it the
// repositories are listed and a pick is the folder `github:owner/name`.
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
const { createGitHubPicker, useGitHubPicker, githubFolderRepo } =
  await import("../src/agent-session/acpmux/githubRepos");
const { cloudStartFolder, newTabProjectPick } = await import("../src/agent-session/acpmux/cloudRun");
const { installPageKey } = await import("../src/agent-session/acpmux/pageKey");
const { useState } = await import("react");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const FOLDER = "/Users/me/app";
const REPOS = [
  { full_name: "acme/api", private: true, default_branch: "main" },
  { full_name: "acme/web", private: false, default_branch: "main" },
];

type Reply = unknown | ((params: Record<string, unknown>) => unknown);
/// A host for the three wire methods: each answer (or `{ error }` to refuse) by method.
function host(answers: Record<string, Reply>) {
  const calls: [string, Record<string, unknown>][] = [];
  const call = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    const answer = answers[method];
    const value = typeof answer === "function" ? (answer as (p: Record<string, unknown>) => unknown)(params) : answer;
    if (value && typeof value === "object" && "error" in value) throw (value as { error: unknown }).error;
    return value;
  };
  // The page's key state, driven by the test: `back()` is the window coming back from the browser.
  const watchers = new Set<() => void>();
  const store = createGitHubPicker(
    call,
    (run) => {
      watchers.add(run);
      return () => void watchers.delete(run);
    },
    () => true,
  );
  return {
    calls,
    answers,
    store,
    back: async () => {
      await act(async () => {
        for (const run of Array.from(watchers)) run();
      });
      await settle();
    },
    watching: () => watchers.size,
  };
}

async function renderTray(props: Record<string, unknown>, store: ReturnType<typeof createGitHubPicker>) {
  const picked: string[] = [];
  function Tray() {
    const github = useGitHubPicker(store);
    const [folder, setFolder] = useState<string | undefined>();
    return (
      <ComposerContext
        summary={{ sessionId: "", cwd: folder ?? FOLDER }}
        projectChoices={[
          { cwd: FOLDER, label: "app" },
          { cwd: "/Users/me/notes", label: "notes" },
        ]}
        onProject={(cwd: string) => {
          picked.push(cwd);
          setFolder(cwd);
        }}
        localName="This Mac"
        runMode={{ mode: "cloud", onMode: () => {} }}
        github={github}
        {...props}
      />
    );
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Tray />));
  return { root, picked };
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
const face = () => doc().querySelector(".acpmux-location-button")?.textContent ?? "";
const CONNECT = "Connect to GitHub";
const detail = (row: HTMLElement | undefined) => row?.querySelector(".acpmux-menu-description")?.textContent;
const button = (name: string) =>
  [...doc().querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === name);

test("not connected: one click on Connect to GitHub opens GitHub in place, waits, then lists the repositories", async () => {
  const gh = host({
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { opened: true },
  });
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(gh.calls.map(([method]) => method)).toEqual(["github.status"]);
    const row = option(CONNECT);
    expect(row).toBeDefined();
    expect(row!.querySelector("[data-github-unavailable]")).toBeNull();
    expect(detail(row)).toBeUndefined();
    // It is pinned under the folders, outside their scrolling list, so a long list never hides it.
    expect(row!.closest(".ui-combobox-pinned")).not.toBeNull();
    expect(row!.closest(".ui-combobox-scroll")).toBeNull();
    expect(option("notes")!.closest(".ui-combobox-scroll")).not.toBeNull();
    await press(row!);
    // One click connects: no second step in the menu.
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
    expect(button("Install on GitHub")).toBeUndefined();
    expect(doc().body.textContent).not.toContain("Install the cmux GitHub App");
    expect(picked).toEqual([]);
    // The menu is still open on the list, and the row stays its title alone: GitHub's own page is the
    // one place the person waits, with no Waiting for GitHub… layered under the row (#46018).
    expect(doc().querySelector(".acpmux-location-search")).not.toBeNull();
    expect(option("notes")).toBeDefined();
    expect(detail(option(CONNECT))).toBeUndefined();
    expect(doc().body.textContent).not.toContain("Waiting for GitHub");
    // Coming back while it is still not installed: the status is read again, the row unchanged.
    await gh.back();
    expect(gh.calls.at(-1)?.[0]).toBe("github.status");
    expect(detail(option(CONNECT))).toBeUndefined();
    // Installed: the repositories, and no Connect to GitHub row.
    gh.answers["github.status"] = { state: "ready", repos_scope: "all" };
    gh.answers["github.repos.list"] = { repos: REPOS, truncated: false };
    await gh.back();
    expect(option("acme/api")).toBeDefined();
    expect(option(CONNECT)).toBeUndefined();
    expect(gh.watching()).toBe(0);
    expect(picked).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("with the page's own key state, coming back to the window after Connect to GitHub reads the status", async () => {
  // The real pageKey.ts wiring, not a test seam: the window's blur (GitHub opened in the browser)
  // and focus (the person is back) re-read github.status with the menu still open.
  const uninstall = installPageKey(dom.window.document);
  const answers: Record<string, unknown> = {
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { opened: true },
  };
  const calls: string[] = [];
  const store = createGitHubPicker(async (method) => {
    calls.push(method);
    return answers[method];
  });
  const { root } = await renderTray({}, store);
  try {
    await openFolderMenu();
    await press(option(CONNECT)!);
    expect(calls).toEqual(["github.status", "github.connect"]);
    await act(async () => void dom.window.dispatchEvent(new dom.window.Event("blur")));
    answers["github.status"] = { state: "ready", repos_scope: "all" };
    answers["github.repos.list"] = { repos: REPOS, truncated: false };
    await act(async () => void dom.window.dispatchEvent(new dom.window.Event("focus")));
    await settle();
    expect(calls).toEqual(["github.status", "github.connect", "github.status", "github.repos.list"]);
    expect(option("acme/api")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
    uninstall();
  }
});

test("the app finishing the install GitHub handed back (cmux-github-changed) lists the repositories with no click", async () => {
  const answers: Record<string, unknown> = {
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { opened: true },
  };
  const calls: string[] = [];
  const store = createGitHubPicker(async (method) => {
    calls.push(method);
    return answers[method];
  });
  const { root } = await renderTray({}, store);
  try {
    await openFolderMenu();
    await press(option(CONNECT)!);
    // Back in cmux before the app's completion answered: still not connected.
    answers["github.status"] = { state: "ready", repos_scope: "all" };
    answers["github.repos.list"] = { repos: REPOS, truncated: false };
    await act(async () => void dom.window.dispatchEvent(new dom.window.Event("cmux-github-changed")));
    await settle();
    expect(calls).toEqual(["github.status", "github.connect", "github.status", "github.repos.list"]);
    expect(option("acme/api")).toBeDefined();
    // A later change (Reconfigure added a repository) lists them again.
    answers["github.repos.list"] = {
      repos: [...REPOS, { full_name: "acme/docs", private: true, default_branch: "main" }],
      truncated: false,
    };
    await act(async () => void dom.window.dispatchEvent(new dom.window.Event("cmux-github-changed")));
    await settle();
    expect(option("acme/docs")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("Connect to GitHub is pinned with Add folder… under the scrolling folders, and leaves once connected", async () => {
  const gh = host({
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({ onBrowseProject: () => undefined }, gh.store);
  try {
    await openFolderMenu();
    const pinned = [...doc().querySelectorAll(".ui-combobox-pinned [role=option]")].map((item) => item.textContent);
    expect(pinned).toEqual([CONNECT, "Add folder…"]);
    gh.answers["github.status"] = { state: "ready", repos_scope: "all" };
    gh.answers["github.repos.list"] = { repos: REPOS, truncated: false };
    await gh.back();
    await act(async () => void dom.window.dispatchEvent(new dom.window.Event("cmux-github-changed")));
    await settle();
    expect([...doc().querySelectorAll(".ui-combobox-pinned [role=option]")].map((item) => item.textContent)).toEqual([
      "Add folder…",
    ]);
    expect(option("acme/api")!.closest(".ui-combobox-scroll")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a click on Connect to GitHub while it waits opens GitHub again", async () => {
  const gh = host({
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await press(option(CONNECT)!);
    expect(detail(option(CONNECT))).toBeUndefined();
    await press(option(CONNECT)!);
    expect(gh.calls.filter(([method]) => method === "github.connect")).toHaveLength(2);
    expect(option("notes")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("ready: the repositories are listed, and a pick is the folder github:owner/name", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  });
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(gh.calls).toEqual([
      ["github.status", {}],
      ["github.repos.list", { query: null }],
    ]);
    const api = option("acme/api")!;
    expect(api.querySelector("[data-section]")?.getAttribute("data-section")).toBe("GitHub");
    expect(api.querySelector(".acpmux-location-lock")?.textContent).toBe("Private");
    expect(option("acme/web")!.querySelector(".acpmux-location-lock")).toBeNull();
    // Connected: the way to the installation's page on GitHub shows whatever the scope.
    expect(option("Choose more repositories…")).toBeDefined();
    await press(api);
    expect(picked).toEqual(["github:acme/api"]);
    // The chip names the repository, not a path.
    expect(face()).toContain("acme/api");
    expect(face()).not.toContain("github:");
  } finally {
    await act(async () => root.unmount());
  }
});

test("ready with no repository granted: GitHub still shows, with the way to choose repositories", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: [], truncated: false },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    const more = option("Choose more repositories…")!;
    expect(more.querySelector("[data-section]")?.getAttribute("data-section")).toBe("GitHub");
    await press(more);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("ready with selected repositories: Choose more repositories… opens GitHub", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "selected" },
    "github.repos.list": { repos: REPOS, truncated: false },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await press(option("Choose more repositories…")!);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("repos.list refused as not connected falls back to the Connect to GitHub row", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { error: { code: "github.not_connected", message: "not installed" } },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(option(CONNECT)).toBeDefined();
    expect(doc().querySelector(".acpmux-github-error")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("another repos.list failure shows one line with Retry, which reads again", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { error: new Error("GitHub did not answer") },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    const line = doc().querySelector(".acpmux-github-error");
    expect(line?.textContent).toContain("GitHub did not answer");
    gh.answers["github.repos.list"] = { repos: REPOS, truncated: false };
    await press(button("Retry")!);
    expect(gh.calls.at(-1)).toEqual(["github.repos.list", { query: null }]);
    expect(doc().querySelector(".acpmux-github-error")).toBeNull();
    expect(option("acme/web")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("before the status answers, nothing GitHub shows; a check that did not answer shows no Connect row", async () => {
  let answer: (value: unknown) => void = () => undefined;
  const calls: string[] = [];
  const store = createGitHubPicker((method) => {
    calls.push(method);
    return new Promise((resolve) => (answer = resolve));
  });
  const { root } = await renderTray({}, store);
  try {
    await openFolderMenu();
    expect(calls).toEqual(["github.status"]);
    expect(doc().querySelector("[data-github]")).toBeNull();
    await act(async () => answer({ state: "unavailable", repos_scope: null, reason: "unreachable" }));
    await settle();
    // A connected team's check can fail too: never offer Connect to GitHub on a guess (#46018).
    expect(option(CONNECT)).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("connected, or unchecked: no Connect to GitHub row in the folder menu", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(option("acme/api")).toBeDefined();
    expect(option(CONNECT)).toBeUndefined();
    // The next open's check does not answer (offline, a team policy): still connected as far as the
    // menu knows, so no Connect row appears and nothing is clicked into a dead end.
    gh.answers["github.status"] = { state: "unavailable", repos_scope: null, reason: "unreachable" };
    await act(async () => gh.store.open());
    await settle();
    expect(gh.store.snapshot().status?.reason).toBe("unreachable");
    expect(option(CONNECT)).toBeUndefined();
    expect(gh.calls.filter(([method]) => method === "github.connect")).toHaveLength(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a refused connect shows the host's words on the row, and a click tries again", async () => {
  const gh = host({
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { error: Object.assign(new Error("GitHub didn't answer."), { code: "github.unavailable" }) },
  });
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await press(option(CONNECT)!);
    const row = option(CONNECT)!;
    expect(row.querySelector(".acpmux-menu-description")?.textContent).toBe("GitHub didn't answer.");
    gh.answers["github.connect"] = { opened: false };
    gh.answers["github.status"] = { state: "not_connected", repos_scope: null };
    await press(row);
    // Already connected as the host saw it: the status is read again, and its answer drawn.
    expect(gh.calls.map(([method]) => method)).toEqual([
      "github.status",
      "github.connect",
      "github.connect",
      "github.status",
    ]);
    expect(option(CONNECT)?.querySelector("[data-github-unavailable]")).toBeNull();
    expect(picked).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("signed out: back before the sign-in ends keeps waiting; signed in, the same row connects in one more click", async () => {
  const gh = host({
    "github.status": { state: "unavailable", repos_scope: null, reason: "signed_out" },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await press(option(CONNECT)!);
    // Back early, still signed out: the next return reads the status again; the row stays its title.
    await gh.back();
    expect(detail(option(CONNECT))).toBeUndefined();
    // Signed in, the App not installed yet: the wait is over, and the row connects again.
    gh.answers["github.status"] = { state: "not_connected", repos_scope: null };
    await gh.back();
    const row = option(CONNECT)!;
    expect(detail(row)).toBeUndefined();
    expect(row.querySelector("[data-github-unavailable]")).toBeNull();
    await press(row);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
    expect(button("Install on GitHub")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("signed out: the Connect to GitHub row is its title alone and signs in; no GitHub App here: no row", async () => {
  const gh = host({
    "github.status": { state: "unavailable", repos_scope: null, reason: "signed_out" },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    const signIn = option(CONNECT)!;
    expect(signIn.querySelector("[data-github-unavailable]")?.getAttribute("data-github-unavailable")).toBe(
      "signed_out",
    );
    expect(detail(signIn)).toBeUndefined();
    await press(signIn);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
  } finally {
    await act(async () => root.unmount());
  }
  const unset = host({
    "github.status": { state: "unavailable", repos_scope: null, reason: "not_configured" },
  });
  const second = await renderTray({}, unset.store);
  try {
    await openFolderMenu();
    // No "GitHub isn't set up for this Cloud service yet." row: there is nothing a click could connect.
    expect(option(CONNECT)).toBeUndefined();
    expect(doc().body.textContent).not.toContain("set up for this Cloud service");
    expect(doc().querySelector("[data-github]")).toBeNull();
  } finally {
    await act(async () => second.root.unmount());
  }
});

test("a host that refuses github.status reads as unreachable", async () => {
  const gh = host({ "github.status": { error: new Error("unknown method") } });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(gh.store.snapshot().status).toEqual({ state: "unavailable", reposScope: null, reason: "unreachable" });
    expect(option(CONNECT)).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("with This Mac picked, a chat that can run on Cloud still offers GitHub, and a repository's pick moves it to Cloud", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  });
  const modes: string[] = [];
  const { root, picked } = await renderTray(
    { runMode: { mode: "persistent", onMode: (mode: string) => modes.push(mode) } },
    gh.store,
  );
  try {
    await openFolderMenu();
    expect(gh.calls[0]).toEqual(["github.status", {}]);
    // A folder of this Mac leaves the chat where it is.
    await press(option("notes")!);
    expect(modes).toEqual([]);
    await openFolderMenu();
    await press(option("acme/api")!);
    expect(picked).toEqual(["/Users/me/notes", "github:acme/api"]);
    expect(modes).toEqual(["cloud"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("with This Mac picked and GitHub not connected, the Connect to GitHub row is there", async () => {
  const gh = host({ "github.status": { state: "not_connected" } });
  const { root } = await renderTray({ runMode: { mode: "persistent", onMode: () => {} } }, gh.store);
  try {
    await openFolderMenu();
    expect(option(CONNECT)).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat that cannot run on Cloud shows nothing new and asks nothing", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  });
  const { root } = await renderTray({ runMode: undefined }, gh.store);
  try {
    await openFolderMenu();
    expect(doc().querySelector("[data-github]")).toBeNull();
    expect(gh.calls).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the search filters the repositories", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    const field = doc().querySelector<HTMLInputElement>(".acpmux-location-search")!;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(field, "web");
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    await settle();
    expect(option("acme/web")).toBeDefined();
    expect(option("acme/api")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a GitHub folder goes to the Cloud start as its cwd and asks this Mac for no grant", () => {
  expect(githubFolderRepo("github:acme/api")).toBe("acme/api");
  expect(githubFolderRepo("github:https://example.com/x")).toBeUndefined();
  expect(githubFolderRepo("/Users/me/app")).toBeUndefined();
  expect(cloudStartFolder("github:acme/api")).toEqual({ cwd: "github:acme/api" });
  const asked: string[] = [];
  const { onProjectPicked } = newTabProjectPick(async (method) => {
    asked.push(method);
    return { status: "ok" };
  }, true);
  onProjectPicked?.("github:acme/api");
  expect(asked).toEqual([]);
});
