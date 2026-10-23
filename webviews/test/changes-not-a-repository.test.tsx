// The Changes view in a folder outside any git repository (a scratch folder): the turn's files
// still show, with a quiet note that the folder is not a repository and no Commit or Push, never
// the red "branch state could not be read" (Leo 2026-10-21). Any other failed status read still
// says so, with Refresh.
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
type TurnFile = import("../src/agent-session/acpmux/diff").TurnFile;

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const created: TurnFile = {
  path: "/private/tmp/scratch/batch103.sh",
  displayPath: "batch103.sh",
  edits: [],
  additions: 18,
  deletions: 0,
  created: true,
};

async function open(status: () => Promise<unknown>) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = {
    diff: async () => ({ root: "/private/tmp/scratch", files: [] }),
    status,
    commit: async () => ({}),
    push: async () => ({}),
  };
  await act(async () => root.render(<DiffPanel files={[created]} onClose={() => {}} source={source} />));
  await settle();
  return { root, container };
}

test("a folder outside any repository shows the turn's files and a quiet note, no error", async () => {
  const view = await open(async () => {
    throw Object.assign(new Error("not in a git repository"), {
      code: "operation.failed",
      details: { extra: { code: "not_a_repository" } },
    });
  });
  const text = view.container.textContent ?? "";
  // The file list shows (its tree draws no rows without layout, so its names aren't in the text).
  expect(view.container.querySelector(".acpmux-diff-tree")).not.toBeNull();
  expect(text).not.toContain("No file changes in this turn.");
  expect(text).toContain("+18");
  expect(text).toContain("This chat's folder is not in a git repository.");
  expect(text).not.toContain("The branch state could not be read");
  expect(view.container.querySelector('[role="alert"]')).toBeNull();
  expect(view.container.querySelector('[data-tool="commit"]')).toBeNull();
  expect(view.container.querySelector('[data-tool="push"]')).toBeNull();
  await act(async () => view.root.unmount());
});

test("any other failed status read still reports it", async () => {
  const view = await open(async () => {
    throw new Error("timed out");
  });
  expect(view.container.querySelector('[role="alert"]')?.textContent).toContain("The branch state could not be read");
  expect(view.container.querySelector('[data-tool="commit"]')).not.toBeNull();
  await act(async () => view.root.unmount());
});
