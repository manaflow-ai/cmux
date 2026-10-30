// The Changes view's Create PR (cx-tcwj, Codex desktop's): the Branch scope, which shows what a pull
// request of the branch holds, offers Create PR beside the branch's name. The App opens the pushed
// branch's pull request and the view links it; a refusal (gh missing, not pushed) says why inline.
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
const button = (container: HTMLElement, label: string) =>
  [...container.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);

async function open(scopeLabel: string, pullRequest: () => Promise<unknown>) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = {
    diff: async () => changes,
    status: async () => ({ branch: "feature", base: "main", ahead: 1, behind: 0 }),
    pullRequest,
  };
  await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
  await settle();
  await act(async () => menuItem(scopeLabel)!.click());
  await settle();
  return { root, container };
}

test("the Branch scope's Create PR links the pull request it opened", async () => {
  let asks = 0;
  const view = await open("Branch", async () => {
    asks += 1;
    return { url: "https://github.com/o/r/pull/7", number: 7 };
  });
  try {
    await act(async () => button(view.container, "Create PR")!.click());
    await settle();
    expect(asks).toBe(1);
    const link = view.container.querySelector<HTMLAnchorElement>(".acpmux-diff-notes output a");
    expect(link?.textContent).toBe("Pull request #7");
    expect(link?.getAttribute("href")).toBe("https://github.com/o/r/pull/7");
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("a refusal says why inline, and other scopes offer no Create PR", async () => {
  const view = await open("Branch", async () => {
    throw new Error("Push this branch first; the pull request opens from what's on the remote.");
  });
  try {
    await act(async () => button(view.container, "Create PR")!.click());
    await settle();
    expect(view.container.querySelector(".acpmux-diff-notes [role=alert]")?.textContent).toBe(
      "Push this branch first; the pull request opens from what's on the remote.",
    );
  } finally {
    await act(async () => view.root.unmount());
  }
  const other = await open("Uncommitted", async () => ({}));
  try {
    expect(button(other.container, "Create PR")).toBeUndefined();
  } finally {
    await act(async () => other.root.unmount());
  }
});
