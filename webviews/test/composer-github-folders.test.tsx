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
const { createGitHubPicker, useGitHubPicker, githubFolderRepo, githubStatusFromReply } =
  await import("../src/agent-session/acpmux/githubRepos");
const { cloudStartFolder } = await import("../src/agent-session/acpmux/cloudRun");
const { setNativeHost } = await import("../src/agent-session/acpmux/native");
const { installPageKey } = await import("../src/agent-session/acpmux/pageKey");
const { widestLines } = await import("../src/agent-session/acpmux/FolderPopover");
const { useState } = await import("react");
const { forgetAddedRepos, rememberAddedRepo, setFolderUseTimes } = await import(
  "../src/agent-session/acpmux/addedRepos"
);

// Each test starts with no repository added as a project and no folder times.
beforeEach(() => {
  forgetAddedRepos();
  setFolderUseTimes(() => undefined);
});

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
  const picked: [string, string | undefined][] = [];
  function Tray() {
    const github = useGitHubPicker(store);
    const [folder, setFolder] = useState<{ cwd: string; peer?: string }>();
    return (
      <ComposerContext
        summary={{ sessionId: "", cwd: folder?.cwd ?? FOLDER, peer: folder?.peer }}
        projectChoices={[
          { cwd: FOLDER, label: "app" },
          { cwd: "/Users/me/notes", label: "notes" },
        ]}
        onProject={(cwd: string, peer?: string) => {
          picked.push([cwd, peer]);
          setFolder({ cwd, peer });
        }}
        onNoProject={() => setFolder({ cwd: "" })}
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
/// The folder disclosure follows the combobox's arrow navigation and stays out of the tab order.
const expectOnlyOptionsInListbox = () => {
  for (const listbox of doc().querySelectorAll("[role=listbox]")) {
    expect(
      listbox.querySelectorAll(
        "button:not(.acpmux-location-worktrees[tabindex='-1']), [role=button], [role=alert], [role=status]",
      ).length,
    ).toBe(0);
  }
};
const openFolderMenu = async () => {
  await act(async () => doc().querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  await settle();
  expect(doc().querySelector(".acpmux-folder-popover [role=listbox]")).not.toBeNull();
  expectOnlyOptionsInListbox();
};
const option = (name: string) =>
  [...doc().querySelectorAll<HTMLElement>("[role=option]")].find((item) => item.textContent?.includes(name));
const press = async (element: HTMLElement) => {
  await act(async () => element.click());
  await settle();
  expectOnlyOptionsInListbox();
};
const openSources = () => press(option("Add project…")!);
const labels = (selector: string) =>
  [...doc().querySelectorAll(`${selector} .acpmux-menu-label`)].map((label) => label.textContent);
const face = () => doc().querySelector(".acpmux-location-button")?.textContent ?? "";
const status = (state: string, extra: Record<string, unknown> = {}) => ({ state, repos_scope: null, ...extra });
const ready = status("ready", { repos_scope: "selected" });
const installed = { repos: REPOS, truncated: false };
const palette = () => doc().querySelector<HTMLElement>(".acpmux-add-project-palette");
const source = (id: string) => palette()?.querySelector<HTMLElement>(`[data-source="${id}"]`);
const gitHubRow = () => source("github")!;
const githubStatus = () => gitHubRow().querySelector(".acpmux-source-status")?.textContent;
const message = () => palette()?.querySelector("output")?.textContent;
const scopeChip = (label: string) =>
  [...(palette()?.querySelectorAll<HTMLElement>(".acpmux-add-project-scope-label") ?? [])].find(
    (chip) => chip.textContent === label,
  );
const highlightedSource = () =>
  palette()?.querySelector("[data-highlighted] [data-source]")?.getAttribute("data-source");
const pressOutside = async () => {
  const outside = doc().body;
  await act(async () => {
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
      outside.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
  });
  await settle();
};
const field = () => doc().querySelector<HTMLInputElement>(".acpmux-location-search")!;
const type = async (value: string) => {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field(), value);
    field().dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await settle();
};
const key = async (key: string, options: KeyboardEventInit = {}) => {
  await act(async () =>
    (doc().activeElement ?? doc().body).dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...options }),
    ),
  );
  await settle();
};

test("Add project closes the folder menu and opens a named palette with the search focused", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(palette()?.getAttribute("aria-label")).toBe("Add project");
    expect(field()?.getAttribute("placeholder")).toBe("Search sources");
    expect(doc().activeElement === field()).toBe(true);
    expect(palette()?.getAttribute("aria-modal")).not.toBe("true");
    expect(doc().querySelector(".ui-backdrop")).toBeNull();
    expect(palette()?.querySelector("h2, button")).toBeNull();
    expect(doc().querySelector(".acpmux-folder-popover")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("outside click closes the empty source search and preserves a typed filter", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    await type("github");
    expect(labels(".acpmux-add-project-palette [data-source]")).toEqual(["GitHub repository"]);
    await pressOutside();
    expect(field().value).toBe("github");
    await type("");
    await pressOutside();
    expect(palette()).toBeNull();
    expect(doc().activeElement?.getAttribute("aria-label")).toBe("Folder");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Escape returns focus to Folder after focus has moved outside the palette", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root } = await renderTray({}, gh.store);
  const outside = doc().createElement("button");
  doc().body.append(outside);
  try {
    await openFolderMenu();
    await openSources();
    await type("github");
    await act(async () => outside.focus());
    expect(doc().activeElement === outside).toBe(true);
    expect(palette()).not.toBeNull();
    await key("Escape");
    expect(palette()).toBeNull();
    expect(doc().activeElement?.getAttribute("aria-label")).toBe("Folder");
  } finally {
    outside.remove();
    await act(async () => root.unmount());
  }
});

test.each([
  ["signed out", status("unavailable", { reason: "signed_out" }), "Sign in", "github.connect", "Sign in"],
  [
    "no App",
    status("unavailable", { reason: "not_configured" }),
    "Connect to GitHub",
    "github.connect",
    "Connect to GitHub",
  ],
  ["disabled by policy", status("unavailable", { reason: "not_allowed" }), "Off for team", null, null],
  ["offline", status("unavailable", { reason: "unreachable" }), "Offline", "github.status", "Retry"],
  ["connection needed", status("not_connected"), "Connect to GitHub", "github.connect", "Connect to GitHub"],
  [
    "pending approval",
    status("not_connected", { pending_approval: true }),
    "Needs approval",
    "github.connect",
    "Connect to GitHub",
  ],
  ["opening GitHub", status("not_connected", { connecting: true }), "Opening…", null, null],
] as const)("GitHub status and action for %s", async (_name, answer, label, action, button) => {
  const gh = host({ "github.status": answer, "github.connect": { opened: true } });
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(githubStatus()).toBe(label);
    // Never a dead row: every state hovers and answers a press.
    expect(gitHubRow().getAttribute("aria-disabled")).toBeNull();
    await press(gitHubRow());
    expect(scopeChip("GitHub")).toBeDefined();
    if (button) await press(option(button)!);
    // Add project read the status, once: the folder chip and its menu read nothing (cmux#53226).
    const reads = ["github.status"];
    expect(gh.calls.map(([method]) => method)).toEqual(action ? [...reads, action] : reads);
    expect(picked).toEqual([]);
    if (!action) expect(message()).toBeTruthy();
  } finally {
    await act(async () => root.unmount());
  }
});

test("while status is loading GitHub stays visible and answers a press", async () => {
  let answer!: (value: unknown) => void;
  const gh = host({
    "github.status": new Promise((resolve) => {
      answer = resolve;
    }),
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(githubStatus()).toBe("Checking…");
    expect(gitHubRow().getAttribute("aria-disabled")).toBeNull();
    await press(gitHubRow());
    expect(message()).toBe("Checking…");
    await act(async () => answer(status("not_connected")));
    expect(option("Connect to GitHub")!).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("connecting keeps the GitHub step open and shows a refused request in place", async () => {
  let answer!: (value: unknown) => void;
  const gh = host({
    "github.status": status("not_connected"),
    "github.connect": new Promise((resolve) => {
      answer = resolve;
    }),
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    await press(gitHubRow());
    await press(option("Connect to GitHub")!);
    expect(message()).toBe("Opening…");
    // A separate request rejects on retry, as the real native bridge does.
    await act(async () => answer({ opened: false }));
    gh.answers["github.connect"] = { error: new Error("The installation could not open.") };
    await press(option("Connect to GitHub")!);
    expect(message()).toBe("The installation could not open.");
  } finally {
    await act(async () => root.unmount());
  }
});

test("empty installation opens Choose repositories", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": { repos: [] }, "github.connect": { opened: true } });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(githubStatus()).toBe("No repos yet");
    await press(gitHubRow());
    expect(message()).toBe("No repositories yet");
    await press(option("Choose more repositories…")!);
    expect(gh.calls.at(-1)?.[0]).toBe("github.connect");
  } finally {
    await act(async () => root.unmount());
  }
});

test("install completion and window refocus refresh the repository status", async () => {
  const uninstall = installPageKey(doc());
  const gh = host({ "github.status": status("not_connected"), "github.connect": { opened: true } });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    await press(gitHubRow());
    await press(option("Connect to GitHub")!);
    expect(gh.watching()).toBe(1);
    await gh.back();
    expect(gh.calls.at(-1)?.[0]).toBe("github.status");
    gh.answers["github.status"] = ready;
    gh.answers["github.repos.list"] = installed;
    await act(async () => dom.window.dispatchEvent(new dom.window.Event("cmux-github-changed")));
    await settle();
    await key("Escape");
    expect(githubStatus()).toBe("Connected");
    expect(gh.watching()).toBe(0);
    await press(gitHubRow());
    expect(option("acme/api")?.textContent).toContain("Private");
    await press(option("Choose more repositories…")!);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
  } finally {
    await act(async () => root.unmount());
    uninstall();
  }
});

test.each([
  [{ code: "github.unavailable" }, "Offline", "Couldn't load repositories"],
  [{ code: "github.rate_limited" }, "Busy", "GitHub is busy"],
  [{ code: "rate_limited", details: { retry_after: 23 } }, "Busy", "Try again in 23 s"],
] as const)("repository errors show a retryable step: %j", async (error, label, detail) => {
  const gh = host({ "github.status": ready, "github.repos.list": { error } });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(githubStatus()).toBe(label);
    await press(gitHubRow());
    expect(message()).toBe(detail);
    gh.answers["github.repos.list"] = installed;
    await press(option("Retry")!);
    expect(option("acme/api")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a disconnected installation during listing offers Connect to GitHub again", async () => {
  const gh = host({
    "github.status": ready,
    "github.repos.list": { error: { code: "github.not_connected" } },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(githubStatus()).toBe("Connect to GitHub");
    await press(gitHubRow());
    await press(option("Connect to GitHub")!);
    expect(gh.calls.at(-1)?.[0]).toBe("github.connect");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Cloud repo selection uses the repo identity and private rows have a label", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    await press(gitHubRow());
    expect(option("acme/api")?.textContent).toContain("Private");
    await press(option("acme/api")!);
    expect(picked).toEqual([["github:acme/api", undefined]]);
    expect(face()).toContain("acme/api");
    expect(cloudStartFolder(picked[0]?.[0])).toEqual({ cwd: "github:acme/api" });
    expect(githubFolderRepo("github:acme/../api")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("folder search matches the repositories added as projects and Return selects a result", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  rememberAddedRepo({ fullName: "acme/api", private: true }, 1);
  rememberAddedRepo({ fullName: "acme/web", private: false }, 2);
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await type("acme web");
    expect(option("acme/api")).toBeUndefined();
    expect(option("acme/web")).toBeDefined();
    await key("Enter");
    expect(picked).toEqual([["github:acme/web", undefined]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("repository search survives an outside click, Back returns, and Escape closes", async () => {
  const gh = host({
    "github.status": ready,
    "github.repos.list": ({ query }) =>
      query ? { repos: [REPOS[1]], truncated: false } : { repos: [REPOS[0]], truncated: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(doc().activeElement === field()).toBe(true);
    await press(gitHubRow());
    expect(field().getAttribute("aria-label")).toBe("Search repositories");
    await type("web");
    await key("Enter");
    expect(gh.calls.at(-1)).toEqual(["github.repos.list", { query: "web" }]);
    expect(option("acme/web")).toBeDefined();
    await pressOutside();
    expect(field().value).toBe("web");
    expect(scopeChip("GitHub")).toBeDefined();
    await key("Escape");
    expect(field()?.getAttribute("placeholder")).toBe("Search sources");
    expect(doc().activeElement === field()).toBe(true);
    await press(gitHubRow());
    expect(field().value).toBe("");
    expect(option("acme/api")).toBeDefined();
    expect(option("acme/web")).toBeUndefined();
    await key("Backspace");
    expect(field()?.getAttribute("placeholder")).toBe("Search sources");
    await key("Escape");
    expect(field()).toBeNull();
    expect(doc().activeElement?.getAttribute("aria-label")).toBe("Folder");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Cloud source rows and searches exclude local folders, paths, and Git URLs", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  rememberAddedRepo({ fullName: "acme/api", private: true }, 2);
  rememberAddedRepo({ fullName: "acme/web", private: false }, 1);
  let empty = 0;
  const { root } = await renderTray(
    {
      onBrowseProject: () => {
        throw new Error("Cloud must never browse local folders");
      },
      onCloneRepository: async () => {
        throw new Error("Cloud must never clone locally");
      },
      onNoProject: () => {
        empty++;
      },
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    expect(field().getAttribute("aria-label")).toBe("Search folders or type a path");
    expect(labels(".ui-combobox-pinned [role=option]")).toEqual(["Add project…", "No folder"]);
    expect(labels(".ui-combobox-scroll [role=option]")).toEqual(["acme/api", "acme/web"]);
    expect(option("acme/api")?.querySelector(".acpmux-location-action-icon svg")).toBeTruthy();
    expect(option("notes")).toBeUndefined();
    await type(FOLDER);
    expect(labels("[role=option]")).toEqual(["Add project…", "No folder"]);
    expect(doc().querySelectorAll("[data-use-path]").length).toBe(0);
    await type("");
    await openSources();
    expect(labels(".acpmux-add-project-palette [data-source]")).toEqual([
      "GitHub repository",
      "Folder on a Cloud machine",
      "Empty project",
    ]);
    expect(source("folders")?.querySelector(".acpmux-source-status")?.textContent).toBe("None yet");
    expect(source("url")).toBeNull();
    expect(source("browse")).toBeNull();
    await press(source("folders")!);
    expect(message()).toBe("No Cloud folders yet");
    await key("Escape");
    await press(source("empty")!);
    expect(palette()).toBeNull();
    expect(empty).toBe(1);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Cloud folders group by peer and picking one passes its exact peer and folder", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const { root, picked } = await renderTray(
    {
      sessions: [
        { id: "1", peer: "peer-north", host: "North", hostKind: "cloud", cwd: "/home/cmux/work/api" },
        { id: "2", peer: "peer-south", host: "South", hostKind: "cloud", cwd: "/home/cmux/work/api" },
        { id: "3", peer: "peer-north", hostKind: "cloud", cwd: "/home/cmux/chats/private-scratch" },
        { id: "4", peer: "peer-ssh", hostKind: "ssh", cwd: "/home/me/private-ssh" },
        { id: "5", hostKind: "local", cwd: FOLDER },
      ],
      peers: ["peer-north", "peer-south", "peer-ssh"],
      peerKinds: { "peer-north": "cloud", "peer-south": "cloud", "peer-ssh": "ssh" },
      peerConnected: { "peer-north": true, "peer-south": true },
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    const rows = [...doc().querySelectorAll<HTMLElement>("[role=option] [data-section]")];
    expect(rows.map((row) => row.dataset.section)).toEqual(["North", "South"]);
    expect(option("private-scratch")).toBeUndefined();
    expect(option("private-ssh")).toBeUndefined();
    expect(labels(".ui-combobox-pinned [role=option]")).toEqual(["Add project…", "No folder"]);
    expect(labels(".ui-combobox-scroll [role=option]")).not.toContain("No folder");
    expect(rows.every((row) => row.querySelector(".acpmux-location-action-icon svg"))).toBe(true);
    await openSources();
    expect(source("folders")?.querySelector(".acpmux-source-status")?.textContent).toBe("North");
    await press(source("folders")!);
    expect(scopeChip("Cloud machine")).toBeDefined();
    expect(labels(".acpmux-add-project-palette [data-source]")).toEqual(["North", "South"]);
    expect([...palette()!.querySelectorAll('[role="option"]')].map((row) => row.getAttribute("aria-setsize"))).toEqual([
      "2",
      "2",
    ]);
    await press(option("North")!);
    expect(scopeChip("North")).toBeDefined();
    expect(field().getAttribute("placeholder")).toBe("Search folders");
    expect(option("/home/cmux/work/api")?.querySelector("[title]")?.getAttribute("title")).toBe("/home/cmux/work/api");
    await key("Backspace");
    expect(field().getAttribute("placeholder")).toBe("Search Cloud machines");
    await type("south");
    await key("Enter");
    expect(scopeChip("South")).toBeDefined();
    await type("api");
    await key("Enter");
    expect(picked).toEqual([["/home/cmux/work/api", "peer-south"]]);
    await openFolderMenu();
    expect(
      [...doc().querySelectorAll<HTMLElement>("[role=option] [data-current]")].map((row) => row.dataset.section),
    ).toEqual(["South"]);
    expect(labels(".ui-combobox-pinned [role=option]")).toEqual(["Add project…", "No folder"]);
    expect(doc().querySelectorAll(".ui-combobox-pinned [data-no-folder] > svg")).toHaveLength(0);
    await press(option("No folder")!);
    expect(face()).toContain("No folder");
    await openFolderMenu();
    expect(labels(".ui-combobox-pinned [role=option]")).toEqual(["Add project…", "No folder"]);
    expect(doc().querySelectorAll(".ui-combobox-pinned [data-no-folder] > svg")).toHaveLength(1);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the filesystem root stays out of the projects list and can still be used as a path", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      projectChoices: [
        { cwd: FOLDER, label: "app" },
        { cwd: "/", label: "/" },
        { cwd: "/Users/me/notes", label: "notes" },
      ],
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    const folders = [...doc().querySelectorAll(".ui-combobox-scroll [role=option]")];
    expect(folders.map((row) => row.textContent)).toEqual(["app", "notes"]);
    const fit = doc().querySelector(".acpmux-folder-fit")!;
    expect(fit.getAttribute("aria-hidden")).toBe("true");
    expect(new Set([...fit.children].map((line) => line.getAttribute("data-text")))).toEqual(new Set(["app", "notes"]));
    expect(fit.textContent).toBe("");
    expect(labels(".ui-combobox-pinned [role=option]")).toEqual(["Add project…", "No folder"]);
    expect(option("No folder")?.querySelector("[data-no-folder] .acpmux-location-action-icon svg")).toBeTruthy();
    expect(option("notes")?.querySelector(".acpmux-project-badge svg")).toBeTruthy();
    await type("/");
    const usePath = option("Use /");
    expect(usePath?.textContent).toBe("Use /");
    expect(usePath?.querySelector("[data-use-path] .acpmux-location-action-icon svg")).toBeTruthy();
    await press(usePath!);
    expect(picked).toEqual([["/", undefined]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test.each([
  ["persistent", "no matching project", "No matching folders"],
  ["cloud", "", "No recent folders"],
] as const)("the %s folder menu puts its empty state above the actions", async (mode, query, message) => {
  const gh = host({ "github.status": status("not_connected") });
  const { root } = await renderTray({ runMode: { mode, onMode: () => {} } }, gh.store);
  try {
    await openFolderMenu();
    if (query) await type(query);
    const menu = doc().querySelector(".acpmux-folder-popover")!;
    const empty = menu.querySelector(".acpmux-location-empty")!;
    const actions = menu.querySelector(".ui-combobox-pinned")!;
    const afterActions = [...menu.querySelectorAll("*")].filter(
      (element) =>
        !actions.contains(element) &&
        actions.compareDocumentPosition(element) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING &&
        element.textContent?.trim(),
    );
    expect(empty.textContent).toBe(message);
    expect(empty.parentElement?.getAttribute("role")).toBe("presentation");
    expect(empty.compareDocumentPosition(actions) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(afterActions.map((element) => element.textContent)).toEqual([]);
    await openSources();
    expect(doc().querySelector(".acpmux-source-footer")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a GitHub project moves the chat to Cloud when no local checkout action is available", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  rememberAddedRepo({ fullName: "acme/api", private: true }, 1);
  const modes: string[] = [];
  const { root, picked } = await renderTray(
    { runMode: { mode: "persistent", onMode: (mode: string) => modes.push(mode) } },
    gh.store,
  );
  try {
    await openFolderMenu();
    await press(option("notes")!);
    expect(modes).toEqual([]);
    await openFolderMenu();
    await press(option("acme/api")!);
    expect(picked).toEqual([
      ["/Users/me/notes", undefined],
      ["github:acme/api", undefined],
    ]);
    expect(modes).toEqual(["cloud"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("This Mac makes the native folder chooser available through Add project and keeps typed paths", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      onBrowseProject: () => "/Users/me/other",
      onCloneRepository: async () => "/Users/me/cloned",
      onNewProject: () => undefined,
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    expect(labels(".ui-combobox-pinned [role=option]")).toEqual(["Add project…", "No folder"]);
    expect(labels(".ui-combobox-scroll [role=option]")).toEqual(["app", "notes"]);
    await openSources();
    expect(labels(".acpmux-add-project-palette [data-source]")).toEqual([
      "GitHub repository",
      "Folder on this Mac",
      "Git URL",
      "Empty project",
    ]);
    expect([...palette()!.querySelectorAll(".acpmux-source-status")].map((row) => row.textContent)).toEqual([
      "Connect to GitHub",
      "Choose…",
      "Clone",
      "New folder",
    ]);
    expect(palette()!.querySelector(".acpmux-menu-description")).toBeNull();
    await key("ArrowDown");
    expect(highlightedSource()).toBe("browse");
    await key("ArrowUp");
    expect(highlightedSource()).toBe("github");
    expect(doc().activeElement === field()).toBe(true);
    await key("Escape");
    expect(palette()).toBeNull();
    expect(doc().activeElement).toBe(doc().querySelector(".acpmux-location-button"));
    await openFolderMenu();
    await type("/tmp/project");
    await key("Enter");
    expect(picked).toEqual([["/tmp/project", undefined]]);
    await openFolderMenu();
    await openSources();
    await press(source("browse")!);
    expect(picked).toEqual([
      ["/tmp/project", undefined],
      ["/Users/me/other", undefined],
    ]);
    expect(doc().querySelector(".acpmux-folder-popover")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("the folder menu expands worktrees and completes paths from the keyboard", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const worktree = "/Users/me/.cmux/worktrees/app/feature";
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      projectChoices: [
        { cwd: FOLDER, label: "app", repo: { name: "app", root: FOLDER, branch: "main" } },
        { cwd: worktree, label: "worktrees/feature", repo: { name: "app", root: FOLDER, branch: "feature" } },
      ],
      onNewWorktree: () => {},
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    expect(option("New worktree")).toBeUndefined();
    expect(option("feature")).toBeUndefined();
    const disclosure = doc().querySelector<HTMLButtonElement>("button[aria-label='Show 1 worktree']");
    expect(disclosure?.getAttribute("aria-expanded")).toBe("false");
    await key("ArrowDown");
    await key("ArrowRight");
    expect(option("feature")).toBeDefined();
    expect(disclosure?.getAttribute("aria-label")).toBe("Hide worktrees");
    expect(disclosure?.getAttribute("aria-expanded")).toBe("true");
    expect(labels("[role=option]:has([data-worktree])")).toEqual(["New worktree", "feature"]);
    await key("ArrowLeft");
    expect(option("feature")).toBeUndefined();
    expect(option("New worktree")).toBeUndefined();
    await type("feature");
    expect(option("feature")).toBeDefined();
    expect(disclosure?.getAttribute("aria-expanded")).toBe("true");
    await press(disclosure!);
    expect(option("feature")).toBeUndefined();
    await type("feat");
    expect(option("feature")).toBeDefined();
    await key("ArrowDown");
    await key("Tab");
    expect(field().value).toBe(worktree);
    await key("Enter");
    expect(picked).toEqual([[worktree, undefined]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the current worktree opens under its main checkout and the disclosure keeps the menu open", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const worktree = "/Users/me/app/worktrees/feature";
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      summary: { sessionId: "", cwd: worktree },
      projectChoices: [
        { cwd: worktree, label: "worktrees/feature" },
        { cwd: FOLDER, label: "app", repo: { name: "app", root: FOLDER, top: FOLDER } },
      ],
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    expect(labels("[role=option]:has([data-worktree][data-current])")).toEqual(["feature"]);
    expect(option("feature")?.getAttribute("aria-current")).toBe("true");
    const disclosure = doc().querySelector<HTMLButtonElement>("button[aria-label='Hide worktrees']")!;
    await act(async () => {
      for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
        disclosure.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
    });
    await settle();
    expect(option("feature")).toBeUndefined();
    expect(picked).toEqual([]);
    await press(disclosure);
    expect(labels("[role=option]:has([data-worktree][data-current])")).toEqual(["feature"]);
    await press(option("app")!);
    expect(picked).toEqual([[FOLDER, undefined]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Git URL warns about credentials, shows clone progress and errors, and picks the retry result", async () => {
  const gh = host({ "github.status": status("not_connected") });
  let finish!: (path: string) => void;
  const urls: string[] = [];
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      onCloneRepository: (url: string) => {
        urls.push(url);
        if (urls.length === 1) return Promise.reject({ code: "repo.destination_taken" });
        return new Promise<string>((resolve) => {
          finish = resolve;
        });
      },
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    await openSources();
    await press(source("url")!);
    expect(field().getAttribute("aria-label")).toBe("Git URL");
    expect(scopeChip("Git URL")).toBeDefined();
    await type("https://a:secret@example.com/owner/name");
    await key("Enter");
    expect(message()).toContain("without credentials");
    expect(urls).toEqual([]);
    await type("https://example.com/owner/name.git");
    await pressOutside();
    expect(field().value).toBe("https://example.com/owner/name.git");
    await key("Enter");
    expect(message()).toContain("already uses");
    await key("Enter");
    expect(face()).toContain("name · Cloning…");
    expect(field().readOnly).toBe(true);
    await act(async () => finish("/Users/me/cmux/repos/example.com/owner/name"));
    expect(picked).toEqual([["/Users/me/cmux/repos/example.com/owner/name", undefined]]);
    expect(palette()).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a clone that finishes after leaving its step cannot replace a newer folder", async () => {
  const gh = host({ "github.status": status("not_connected") });
  let finish!: (path: string) => void;
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      onCloneRepository: () =>
        new Promise<string>((resolve) => {
          finish = resolve;
        }),
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    await openSources();
    await press(source("url")!);
    await type("https://example.com/owner/name");
    await key("Enter");
    await key("Escape");
    expect(field()?.getAttribute("placeholder")).toBe("Search sources");
    await key("Escape");
    await openFolderMenu();
    await type("notes");
    await key("Enter");
    await act(async () => finish("/Users/me/cloned"));
    expect(picked).toEqual([["/Users/me/notes", undefined]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("GitHub parser ignores an approval field on a ready connection", () => {
  expect(githubStatusFromReply({ ...ready, pending_approval: true }).pendingApproval).toBeUndefined();
  expect(githubStatusFromReply(status("not_connected", { pending_approval: true })).pendingApproval).toBe(true);
});

test("the folder menu keeps a bounded width sample", () => {
  const row = (text: string) => ({ text, kind: "row" as const });
  const many = Array.from({ length: 4000 }, (_, index) => row("f" + index));
  const picked = widestLines([...many, row("a much longer folder name"), row("f1")]);
  expect(picked).toHaveLength(6);
  expect(picked[0]).toEqual(row("a much longer folder name"));
  expect(widestLines([row("api"), row("api"), row("web")])).toEqual([row("api"), row("web")]);
  const count = { text: "app 24", kind: "count" as const };
  expect(widestLines([row("a folder"), count], 1)).toEqual([count]);
});

test("a paused Cloud folder resumes its machine and keeps the exact folder until the peer is ready", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const resume: string[] = [];
  const picked: [string, string | undefined][] = [];
  const pending: boolean[] = [];
  let link!: (ready: boolean) => void;
  const machine = { id: "vm-builder", name: "builder", stage: "paused" };
  function Tray() {
    const github = useGitHubPicker(gh.store);
    const [connected, setConnected] = useState(false);
    link = setConnected;
    return (
      <ComposerContext
        summary={{ sessionId: "", cwd: FOLDER }}
        projectChoices={[]}
        peers={["builder"]}
        peerKinds={{ builder: "cloud" }}
        peerConnected={{ builder: connected }}
        sessions={[
          { sessionId: "1", peer: "builder", hostKind: "cloud", cwd: "/home/cmux/work/default" },
          { sessionId: "2", peer: "builder", hostKind: "cloud", cwd: "/home/cmux/work/other" },
        ]}
        cloudMachines={[connected ? { ...machine, stage: "ready" } : machine]}
        onCloudMachine={(machine) => {
          resume.push(machine.id);
        }}
        onCloudFolderWaiting={(waiting) => {
          pending.push(waiting);
        }}
        onProject={(cwd, peer) => {
          picked.push([cwd, peer]);
        }}
        runMode={{ mode: "cloud", onMode: () => {} }}
        github={github}
      />
    );
  }
  const root = createRoot(doc().getElementById("root")!);
  try {
    await act(async () => root.render(<Tray />));
    await openFolderMenu();
    await openSources();
    await press(source("folders")!);
    expect(option("builder")?.textContent).toContain("Paused");
    await press(option("builder")!);
    await press(option("/home/cmux/work/other")!);
    expect(resume).toEqual(["vm-builder"]);
    expect(pending.at(-1)).toBe(true);
    expect(picked).toEqual([]);
    await act(async () => link(true));
    expect(pending.at(-1)).toBe(false);
    expect(picked).toEqual([["/home/cmux/work/other", "builder"]]);
  } finally {
    await act(async () => root.unmount());
  }
});

function mockProjectPalette(shown = true) {
  const calls: {
    method: string;
    id: string;
    push?: boolean;
    model?: import("../src/agent-session/acpmux/projectPaletteHost").ProjectPalettePage;
  }[] = [];
  setNativeHost(async (method, params) => {
    if (!method.startsWith("projectPalette.")) return undefined;
    calls.push({
      method,
      id: params.id as string,
      push: params.push as boolean | undefined,
      model: params.model as (typeof calls)[number]["model"],
    });
    return { shown };
  });
  const events = async (...batch: Record<string, unknown>[]) => {
    const session = calls.find(({ method }) => method === "projectPalette.show")?.id;
    await act(async () => {
      for (const detail of batch)
        dom.window.dispatchEvent(
          new dom.window.CustomEvent("cmux-project-palette", { detail: { session, ...detail } }),
        );
    });
  };
  return { calls, model: () => calls.filter(({ model }) => model).at(-1)?.model, event: events };
}

test.each([true, false])("Add project omits the extra-folder source with native acceptance %s", async (shown) => {
  const gh = host({ "github.status": status("not_connected") });
  const native = mockProjectPalette(shown);
  const { root } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      extraFolders: { onChange: () => {} },
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    await openSources();
    expect(native.model()?.rows.map(({ id }) => id)).not.toContain("extra");
    if (shown) {
      await native.event({ type: "back", page: "extra", text: "" });
      expect(native.model()?.page).toBe("add");
    } else {
      expect(source("extra")).toBeNull();
    }
  } finally {
    await act(async () => root.unmount());
    setNativeHost(undefined);
  }
});

test("Add project sends the native palette its source rows and handles filtered repository picks", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const native = mockProjectPalette();
  const { root, picked } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(palette()).toBeNull();
    expect(doc().querySelector(".acpmux-folder-popover")).toBeNull();
    expect(native.calls[0]).toMatchObject({
      method: "projectPalette.show",
      model: { title: "Add project", page: "add", placeholder: "Search sources" },
    });
    expect(native.model()?.rows).toContainEqual({
      id: "github",
      label: "GitHub repository",
      icon: "github",
      status: "Connected",
      enabled: true,
    });
    await native.event({ type: "query", page: "add", text: "repository" });
    expect(native.model()?.rows.map(({ id }) => id)).toEqual(["github"]);

    await native.event({ type: "pick", page: "add", id: "github", session: "stale" });
    expect(native.model()?.page).toBe("add");
    await native.event({ type: "pick", page: "add", id: "github" });
    expect(native.model()).toMatchObject({ page: "github", scope: { label: "GitHub", icon: "github" } });
    expect(native.calls.at(-1)?.push).toBe(true);
    await native.event({ type: "query", page: "github", text: "api" });
    expect(native.model()?.rows).toContainEqual({
      id: "acme/api",
      label: "acme/api",
      icon: "github",
      status: "Private",
      enabled: true,
    });
    expect(native.model()?.rows.some(({ id }) => id === "acme/web")).toBe(false);
    await native.event({ type: "back", page: "add", text: "repository" }, { type: "query", page: "add", text: "repo" });
    expect(native.model()).toMatchObject({ page: "add", query: "repo" });
    expect(native.calls.at(-1)?.push).toBe(false);
    await native.event({ type: "pick", page: "add", id: "github" });
    await native.event({ type: "pick", page: "github", id: "acme/api" });
    expect(picked).toEqual([["github:acme/api", undefined]]);
    expect(native.calls.at(-1)?.method).toBe("projectPalette.close");
    expect(doc().activeElement).toBe(doc().querySelector(".acpmux-location-button"));
  } finally {
    await act(async () => root.unmount());
    setNativeHost(undefined);
  }
});

test("native Submit shares URL validation and clone state, and closing ignores a late clone result", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const native = mockProjectPalette();
  const urls: string[] = [];
  let completed: ((path: string) => void) | undefined;
  const { root, picked } = await renderTray(
    {
      runMode: { mode: "persistent", onMode: () => {} },
      onCloneRepository: (url: string) => {
        urls.push(url);
        return new Promise<string>((resolve) => {
          completed = resolve;
        });
      },
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    await openSources();
    await native.event({ type: "pick", page: "add", id: "url" });
    expect(native.model()).toMatchObject({ page: "url", scope: { label: "Git URL", icon: "link" } });
    const invalid = "https://user:secret@example.com/owner/name";
    await native.event({ type: "query", page: "url", text: invalid });
    await native.event({ type: "submit", page: "url", text: invalid });
    expect(urls).toEqual([]);
    expect(native.model()?.rows[0]?.label).toContain("without credentials");

    const url = "https://example.com/owner/name.git";
    await native.event({ type: "query", page: "url", text: url });
    await native.event({ type: "submit", page: "url", text: url });
    await native.event({ type: "submit", page: "url", text: url });
    expect(urls).toEqual([url]);
    expect(native.model()?.rows).toEqual([{ id: "\0message", label: "Cloning…", enabled: false }]);
    await native.event({ type: "closed" });
    expect(doc().activeElement).toBe(doc().querySelector(".acpmux-location-button"));
    await act(async () => completed?.("/Users/me/late"));
    expect(picked).toEqual([]);
  } finally {
    await act(async () => root.unmount());
    setNativeHost(undefined);
  }
});

test("the native Cloud page drills into a machine and picks that machine's folder", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const native = mockProjectPalette();
  const cwd = "/home/cmux/work/api";
  const { root, picked } = await renderTray(
    {
      sessions: [
        { id: "1", peer: "peer-north", host: "North", hostKind: "cloud", cwd },
        { id: "2", peer: "peer-south", host: "South", hostKind: "cloud", cwd },
      ],
      peers: ["peer-north", "peer-south"],
      peerKinds: { "peer-north": "cloud", "peer-south": "cloud" },
      peerConnected: { "peer-north": true, "peer-south": true },
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    await openSources();
    await native.event({ type: "pick", page: "add", id: "folders" });
    expect(native.model()?.rows.map(({ label }) => label)).toEqual(["North", "South"]);
    await native.event({ type: "pick", page: "machines", id: "peer-south" });
    expect(native.model()).toMatchObject({ page: "folders", scope: { label: "South", icon: "folder" } });
    await native.event({ type: "back", page: "machines", text: "" });
    expect(native.model()?.page).toBe("machines");
    await native.event({ type: "pick", page: "machines", id: "peer-south" });
    await native.event({ type: "pick", page: "folders", id: cwd });
    expect(picked).toEqual([[cwd, "peer-south"]]);
  } finally {
    await act(async () => root.unmount());
    setNativeHost(undefined);
  }
});

test("a host that declines Add project leaves the shared glass web picker available", async () => {
  const gh = host({ "github.status": status("not_connected") });
  const native = mockProjectPalette(false);
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    await openSources();
    expect(native.calls[0]?.method).toBe("projectPalette.show");
    expect(palette()?.matches(".ui-glass.ui-glass-material")).toBe(true);
    expect(doc().activeElement).toBe(field());
  } finally {
    await act(async () => root.unmount());
    setNativeHost(undefined);
  }
});

test("a not_connected status carries the host's message, and only that state does (why Connect is needed again)", () => {
  expect(
    githubStatusFromReply({
      state: "not_connected",
      repos_scope: null,
      problem: "needs_reauth",
      message: " GitHub access was suspended. ",
    }),
  ).toEqual({
    state: "not_connected",
    reposScope: null,
    message: "GitHub access was suspended.",
  });
  expect(githubStatusFromReply({ state: "not_connected", repos_scope: null, problem: null, message: null })).toEqual({
    state: "not_connected",
    reposScope: null,
  });
  expect(githubStatusFromReply({ state: "ready", repos_scope: "all", message: "ignored" })).toEqual({
    state: "ready",
    reposScope: "all",
  });
});

test("a pending connection's words never sit under Connect to GitHub, and a click still connects (#46018)", async () => {
  const gh = host({
    "github.status": {
      state: "not_connected",
      repos_scope: null,
      problem: "linking",
      message: "Finish connecting GitHub in your browser.",
    },
    "github.connect": { opened: true },
  });
  const { root } = await renderTray({}, gh.store);
  try {
    // Connect lives in Add project's GitHub source: its label alone, and its page's Connect still connects.
    await openFolderMenu();
    await openSources();
    expect(githubStatus()).toBe("Connect to GitHub");
    await press(gitHubRow());
    await press(option("Connect to GitHub")!);
    expect(gh.calls.at(-1)).toEqual(["github.connect", {}]);
  } finally {
    await act(async () => root.unmount());
  }
});

// cmux#53226: the This Mac folder menu listed GitHub right under the last folder, its heading with no
// line over it, and its repositories arrived after the open, the rows filling in under the pointer.
const persistent = { runMode: { mode: "persistent", onMode: () => {} } };
const listRow = (name: string) =>
  [...doc().querySelectorAll<HTMLElement>(".ui-combobox-scroll [role=option]")].find((item) =>
    item.textContent?.includes(name),
  );

test("one list, most recently used first: an added GitHub repository sits among the folders under no heading (cmux#53226)", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  setFolderUseTimes((folder) => ({ [FOLDER]: 3000, "/Users/me/notes": 1000 })[folder]);
  rememberAddedRepo({ fullName: "acme/web", private: false }, 2000);
  const { root } = await renderTray(persistent, gh.store);
  try {
    await openFolderMenu();
    // The repository used between the two folders is listed between them; acme/api, on the account but
    // never added as a project, is not listed.
    expect(labels(".ui-combobox-scroll [role=option]")).toEqual(["app", "acme/web", "notes"]);
    expect(listRow("acme/api")).toBeUndefined();
    // No GitHub section: no heading and no hairline anywhere in the list.
    expect(doc().querySelectorAll(".ui-combobox-scroll [data-section], .ui-combobox-scroll [data-divider]")).toHaveLength(
      0,
    );
    expect(listRow("acme/web")?.querySelector("[data-github] .acpmux-location-action-icon svg")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a folder that is a clone of an added GitHub repository is its one row, with the GitHub glyph (cmux#53226)", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  rememberAddedRepo({ fullName: "acme/api", private: true }, 2000);
  rememberAddedRepo({ fullName: "acme/web", private: false }, 1000);
  const { root } = await renderTray(
    {
      ...persistent,
      projectChoices: [
        { cwd: FOLDER, label: "app" },
        // This Mac's clone of acme/api, as `project.list` names its GitHub origin.
        { cwd: "/Users/me/src/api", label: "api", repo: { root: "/Users/me/src/api", name: "api", github: "Acme/API" } },
      ],
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    // Before, the clone was listed as a folder and the repository again under GitHub.
    expect(labels(".ui-combobox-scroll [role=option]")).toEqual(["acme/web", "app", "api"]);
    const clone = listRow("api")!;
    expect(clone.querySelector("[data-github] .acpmux-location-action-icon svg")).not.toBeNull();
    // A plain folder keeps its own icon.
    expect(listRow("app")?.querySelector("[data-github]")).toBeNull();
    await type("api");
    expect(labels(".ui-combobox-scroll [role=option]")).toEqual(["api"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the folder chip and its menu read nothing from GitHub; Add project reads it (cmux#53226)", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root } = await renderTray(persistent, gh.store);
  try {
    await settle();
    await openFolderMenu();
    expect(gh.calls).toEqual([]);
    await openSources();
    expect(gh.calls.map(([method]) => method)).toEqual(["github.status", "github.repos.list"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a repository added through Add project is listed in the folder menu from then on (cmux#53226)", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    expect(listRow("acme/web")).toBeUndefined();
    await openSources();
    await press(gitHubRow());
    await press(option("acme/web")!);
    await openFolderMenu();
    expect(listRow("acme/web")).toBeDefined();
    expect(listRow("acme/api")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a folder named by a bare UUID is never listed (cmux#53226)", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  const { root } = await renderTray(
    {
      ...persistent,
      projectChoices: [
        { cwd: FOLDER, label: "app" },
        { cwd: "/Users/me/scratch/f05f40b0-8fc6-4074-ba2b-0ab797700efa", label: "f05f40b0-8fc6-4074-ba2b-0ab797700efa" },
      ],
    },
    gh.store,
  );
  try {
    await openFolderMenu();
    expect(labels(".ui-combobox-scroll [role=option]")).toEqual(["app"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Cloud lists the added repositories first, with no GitHub heading over them (cmux#53226)", async () => {
  const gh = host({ "github.status": ready, "github.repos.list": installed });
  rememberAddedRepo({ fullName: "acme/api", private: true }, 1);
  const { root } = await renderTray({}, gh.store);
  try {
    await openFolderMenu();
    const first = doc().querySelector<HTMLElement>(".ui-combobox-scroll [role=option] .acpmux-location-row")!;
    expect(first.textContent).toContain("acme/api");
    expect(first.hasAttribute("data-section")).toBe(false);
    expect(first.hasAttribute("data-divider")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});
