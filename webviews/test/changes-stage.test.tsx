// The Changes view's Stage and Unstage (cx-tcwj, Codex desktop's staging): in a git scope, a changed
// file's More menu stages it (Unstaged, Uncommitted) or unstages it (Staged) through the view's
// source, then the scope reloads. A refusal says why in the view, without a dialog.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The file menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../src/agent-session/acpmux/DiffPanel");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\n+two\n";
const changes = { root: "/repo", files: [{ path: "a.txt", status: "modified", additions: 1, deletions: 1, patch }] };
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const menuItem = (label: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"], [role="menuitemradio"]')].find(
    (item) => item.textContent === label,
  );

async function open(
  scopeLabel: string,
  stage: (paths: string[], unstage: boolean) => Promise<unknown>,
  listed: unknown = changes,
) {
  const reads: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = {
    diff: async (scope: string) => {
      reads.push(scope);
      return listed;
    },
    stage,
  };
  await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
  await settle();
  await act(async () => menuItem(scopeLabel)!.click());
  await settle();
  const more = () => container.querySelector<HTMLButtonElement>('[aria-label="More actions for a.txt"]');
  return { root, container, reads, more };
}

test("Unstaged stages a file from its menu, then reloads", async () => {
  const asked: [string[], boolean][] = [];
  const view = await open("Unstaged", async (paths, unstage) => void asked.push([paths, unstage]));
  try {
    expect(view.reads).toEqual(["unstaged"]);
    await act(async () => view.more()!.click());
    await settle();
    await act(async () => menuItem("Stage")!.click());
    await settle();
    expect(asked).toEqual([[["a.txt"], false]]);
    expect(view.reads).toEqual(["unstaged", "unstaged"]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("Staged unstages instead, and a refusal shows inline", async () => {
  const view = await open("Staged", async () => {
    throw new Error("That folder is outside this chat's folders.");
  });
  try {
    await act(async () => view.more()!.click());
    await settle();
    expect(menuItem("Stage")).toBeUndefined();
    await act(async () => menuItem("Unstage")!.click());
    await settle();
    const notice = view.container.querySelector('.acpmux-diff-notice[role="alert"] .acpmux-diff-notice-text');
    expect(notice?.textContent).toBe("That folder is outside this chat's folders.");
    expect(view.reads).toEqual(["staged"]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

/// A refusal stayed up after later actions worked (dogfood run, hq #1893): a Stage refusal still
/// showed after a commit and a push from the same view. It has a Dismiss button now, as git's
/// own errors in the view do.
test("a refusal can be dismissed", async () => {
  const view = await open("Unstaged", async () => {
    throw new Error("That folder is outside this chat's folders.");
  });
  try {
    await act(async () => view.more()!.click());
    await settle();
    await act(async () => menuItem("Stage")!.click());
    await settle();
    const notice = () => view.container.querySelector('.acpmux-diff-notice[role="alert"]');
    const dismiss = notice()?.querySelector<HTMLButtonElement>('button[aria-label="Dismiss"]');
    expect(dismiss).toBeTruthy();
    await act(async () => dismiss!.click());
    expect(notice()).toBeNull();
  } finally {
    await act(async () => view.root.unmount());
  }
});

/// A rename is two paths in the index: unstaging only the new name would leave the old name's
/// deletion staged.
test("a rename unstages both of its paths", async () => {
  const asked: string[][] = [];
  const renamed = {
    root: "/repo",
    files: [{ path: "a.txt", previous_path: "old.txt", status: "renamed", additions: 1, deletions: 1, patch }],
  };
  const view = await open("Staged", async (paths) => void asked.push(paths), renamed);
  try {
    await act(async () => view.more()!.click());
    await settle();
    await act(async () => menuItem("Unstage")!.click());
    await settle();
    expect(asked).toEqual([["a.txt", "old.txt"]]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

// Stage hunk and Unstage hunk (cx-ncc.74): in Unstaged and Staged each hunk has its own button,
// which sends that hunk's lines (as `git.diff` showed them) and the file's path from the
// repository's top, then reloads. Uncommitted, whose hunks may be part staged, has none.
const twoHunks =
  "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n" +
  "@@ -1,2 +1,2 @@\n-one\n+two\n keep\n" +
  "@@ -20,2 +20,3 @@\n twenty\n-old\n+new\n+more\n";
const hunked = {
  root: "/repo",
  files: [{ path: "a.txt", status: "modified", additions: 3, deletions: 2, patch: twoHunks }],
};

async function openHunks(
  scopeLabel: string,
  stageHunk: (paths: string[], hunk: string[], unstage: boolean) => Promise<unknown>,
) {
  const reads: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = {
    diff: async (scope: string) => {
      reads.push(scope);
      return hunked;
    },
    stage: async () => undefined,
    stageHunk,
  };
  await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
  await settle();
  await act(async () => menuItem(scopeLabel)!.click());
  await settle();
  const button = (label: string) => container.querySelector<HTMLButtonElement>(`[aria-label="${label}"]`);
  return { root, container, reads, button };
}

test("Unstaged stages one hunk from its button, then reloads", async () => {
  const asked: [string[], string[], boolean][] = [];
  const view = await openHunks("Unstaged", async (paths, hunk, unstage) => void asked.push([paths, hunk, unstage]));
  try {
    expect(view.container.querySelectorAll(".acpmux-hunk-stage").length).toBe(2);
    await act(async () => view.button("Stage hunk at a.txt line 21")!.click());
    await settle();
    expect(asked).toEqual([[["a.txt"], [" twenty", "-old", "+new", "+more"], false]]);
    expect(view.reads).toEqual(["unstaged", "unstaged"]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("Staged unstages one hunk, and a refusal shows inline", async () => {
  const asked: [string[], string[], boolean][] = [];
  const view = await openHunks("Staged", async (paths, hunk, unstage) => {
    asked.push([paths, hunk, unstage]);
    throw new Error("That change is no longer in the file. Refresh and try again.");
  });
  try {
    expect(view.button("Stage hunk at a.txt line 1")).toBeNull();
    await act(async () => view.button("Unstage hunk at a.txt line 1")!.click());
    await settle();
    expect(asked).toEqual([[["a.txt"], ["-one", "+two", " keep"], true]]);
    const notice = view.container.querySelector('.acpmux-diff-notice[role="alert"] .acpmux-diff-notice-text');
    expect(notice?.textContent).toBe("That change is no longer in the file. Refresh and try again.");
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("Uncommitted has no hunk buttons", async () => {
  const view = await openHunks("Uncommitted", async () => undefined);
  try {
    expect(view.reads).toEqual(["uncommitted"]);
    expect(view.container.querySelectorAll(".acpmux-hunk-stage").length).toBe(0);
  } finally {
    await act(async () => view.root.unmount());
  }
});
