// A new Cloud chat's folder menu offers the person's GitHub repositories (githubRepos.ts): before the
// cmux GitHub App is installed one row opens the install card, after it the repositories are listed
// and a pick is the folder `github:owner/name`.
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
const card = () => doc().querySelector(".acpmux-github-card");
const button = (name: string) =>
  [...doc().querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === name);

test("not connected: one row opens the install card, whose button opens GitHub and waits", async () => {
  const gh = host({
    "github.status": { state: "not_connected", repos_scope: null },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(gh.calls.map(([method]) => method)).toEqual(["github.status"]);
    const row = option("Add repositories from GitHub");
    expect(row).toBeDefined();
    // It is the last row of the list, under the folders.
    const rows = [...doc().querySelectorAll("[role=option]")].map((item) => item.textContent);
    expect(rows.indexOf(row!.textContent)).toBeGreaterThan(rows.findIndex((text) => text?.includes("notes")));
    await press(row!);
    expect(card()?.textContent).toContain("Install the cmux GitHub App");
    expect(card()?.textContent).toContain("You choose which repositories cmux can reach");
    expect(doc().querySelector(".acpmux-location-search")).toBeNull();
    await press(button("Install on GitHub")!);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
    expect(card()?.textContent).toContain("Waiting for GitHub…");
    expect(button("Install on GitHub")).toBeUndefined();
    // Coming back while it is still not installed: the card keeps waiting.
    await gh.back();
    expect(gh.calls.at(-1)?.[0]).toBe("github.status");
    expect(card()?.textContent).toContain("Waiting for GitHub…");
    // Installed: back to the list, with the repositories.
    gh.answers["github.status"] = { state: "ready", repos_scope: "all" };
    gh.answers["github.repos.list"] = { repos: REPOS, truncated: false };
    await gh.back();
    expect(card()).toBeNull();
    expect(option("acme/api")).toBeDefined();
    expect(gh.watching()).toBe(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Back on the install card returns to the list", async () => {
  const gh = host({ "github.status": { state: "not_connected", repos_scope: null } });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await press(option("Add repositories from GitHub")!);
    await press(doc().querySelector<HTMLButtonElement>(".acpmux-github-card-back")!);
    expect(card()).toBeNull();
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
    // All repositories: no Choose more repositories….
    expect(option("Choose more repositories…")).toBeUndefined();
    await press(api);
    expect(picked).toEqual(["github:acme/api"]);
    // The chip names the repository, not a path.
    expect(face()).toContain("acme/api");
    expect(face()).not.toContain("github:");
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

test("repos.list refused as not connected falls back to the install row", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { error: { code: "github.not_connected", message: "not installed" } },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(option("Add repositories from GitHub")).toBeDefined();
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

test("unavailable shows nothing new", async () => {
  const gh = host({ "github.status": { state: "unavailable", repos_scope: null } });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(doc().querySelector("[data-github]")).toBeNull();
    expect(gh.calls.map(([method]) => method)).toEqual(["github.status"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a local chat shows nothing new and asks nothing", async () => {
  const gh = host({
    "github.status": { state: "ready", repos_scope: "all" },
    "github.repos.list": { repos: REPOS, truncated: false },
  });
  const { root } = await renderTray({ runMode: { mode: "persistent", onMode: () => {} } }, gh.store);
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
