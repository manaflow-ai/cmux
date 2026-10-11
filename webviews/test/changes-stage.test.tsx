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

async function open(scopeLabel: string, stage: (paths: string[], unstage: boolean) => Promise<unknown>) {
  const reads: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = {
    diff: async (scope: string) => {
      reads.push(scope);
      return changes;
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
    const notice = view.container.querySelector('.acpmux-diff-notice[role="alert"]');
    expect(notice?.textContent).toBe("That folder is outside this chat's folders.");
    expect(view.reads).toEqual(["staged"]);
  } finally {
    await act(async () => view.root.unmount());
  }
});
