// Show more lines in the changes view (cx-ncc.85, Claude parity): in a git scope, a changed file is
// read again with every unchanged line (`git.diff` with `paths` and `context_lines`), so the lines
// between and around its hunks can be expanded where the diff says how many are hidden.
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
  // Every observed file is on screen, as the first files of a pane are.
  IntersectionObserver: class {
    constructor(private readonly report: (entries: { isIntersecting: boolean }[]) => void) {}
    observe() {
      queueMicrotask(() => this.report([{ isIntersecting: true }]));
    }
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

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const menuItem = (label: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"], [role="menuitemradio"]')].find(
    (item) => item.textContent === label,
  );

/// A 30-line file whose lines 2 and 25 changed: two hunks, 16 unchanged lines between them.
const before = Array.from({ length: 30 }, (_, index) => `line ${index + 1}`);
const after = before.map((line, index) => (index === 1 ? "line two" : index === 24 ? "line twenty-five" : line));
const header = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n";
const hunk = (from: number, to: number) =>
  `@@ -${from},${to - from + 1} +${from},${to - from + 1} @@\n` +
  before
    .slice(from - 1, to)
    .map((line, offset) => (line === after[from - 1 + offset] ? ` ${line}` : `-${line}\n+${after[from - 1 + offset]}`))
    .join("\n") +
  "\n";
const listed = (patch: string) => ({
  root: "/repo",
  files: [{ path: "a.txt", status: "modified", additions: 2, deletions: 2, patch }],
});

async function open(
  wholeFile?: (scope: string, path: string) => Promise<unknown>,
  shown = header + hunk(1, 5) + hunk(22, 28),
) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = { diff: async () => listed(shown), wholeFile };
  await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
  await settle();
  await act(async () => menuItem("Unstaged")!.click());
  for (let step = 0; step < 5; step++) await settle();
  const diff = container.querySelector(".acpmux-diff-file")!;
  const shadow = () => diff.querySelector("diffs-container")?.shadowRoot;
  return { root, container, diff, shadow };
}

const expanders = (view: { shadow: () => ShadowRoot | null | undefined }) =>
  [...(view.shadow()?.querySelectorAll<HTMLElement>("[data-expand-button]") ?? [])].filter(
    (button) => button.tagName !== "symbol",
  );
const shows = (view: { shadow: () => ShadowRoot | null | undefined }, text: string) =>
  (view.shadow()?.textContent ?? "").includes(text);

test("a git scope's file is read whole, and the lines between its hunks can be shown", async () => {
  const asked: [string, string][] = [];
  const view = await open(async (scope, path) => {
    asked.push([scope, path]);
    return listed(header + hunk(1, 30));
  });
  try {
    expect(asked).toEqual([["unstaged", "a.txt"]]);
    expect(view.diff.hasAttribute("data-whole-file")).toBe(true);
    expect(expanders(view).length).toBeGreaterThan(0);
    // Line 12 sits between the hunks: hidden until the separator between them expands.
    expect(shows(view, "line 12")).toBe(false);
    const between = expanders(view).find((button) => button.hasAttribute("data-expand-both"));
    expect(between).toBeDefined();
    await act(async () =>
      between!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, composed: true })),
    );
    for (let step = 0; step < 3; step++) await settle();
    expect(shows(view, "line 12")).toBe(true);
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("a whole read whose changes differ from the shown diff is not used", async () => {
  // The file changed since the scope loaded: line 2 now reads otherwise.
  const view = await open(async () => listed(header + hunk(1, 30).replace("+line two", "+line 2b")));
  try {
    expect(view.diff.hasAttribute("data-whole-file")).toBe(false);
    expect(expanders(view)).toEqual([]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

// A host that ignores or caps `context_lines` answers with the hunk's own context: a read that does
// not start at the file's first line is not the whole file (review, #19780).
test("a read that does not start at the first line is not used", async () => {
  // Shown: only line 25 changed (the fixture's line 2 change is left out of both).
  const lateOnly = (from: number, to: number) => hunk(from, to).replace("-line 2\n+line two", " line 2");
  const view = await open(async () => listed(header + lateOnly(20, 30)), header + lateOnly(22, 28));
  try {
    expect(view.diff.hasAttribute("data-whole-file")).toBe(false);
    expect(expanders(view)).toEqual([]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("without a whole-file read the diff stays as git listed it", async () => {
  const view = await open();
  try {
    expect(view.diff.hasAttribute("data-whole-file")).toBe(false);
    expect(expanders(view)).toEqual([]);
  } finally {
    await act(async () => view.root.unmount());
  }
});
