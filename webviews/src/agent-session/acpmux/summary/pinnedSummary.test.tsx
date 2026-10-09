// The pinned summary card (PinnedSummaryCard.tsx) and its header button (SummaryButton.tsx): the
// Codex app's pinned card at parity (PINNED-SUMMARY P1-P6) and typed custom sections (S1).
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const dom = new JSDOM("<!doctype html><div id=outside></div><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "customElements",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
// The pane's width decides between the pinned card and the popover (matchMedia), as the app's window does.
let wide = true;
const listeners = new Set<() => void>();
Object.defineProperty(dom.window, "matchMedia", {
  configurable: true,
  value: (query: string) => ({
    get matches() {
      return wide;
    },
    media: query,
    addEventListener: (_: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_: string, listener: () => void) => listeners.delete(listener),
  }),
});
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    callback(Date.now());
    return 0;
  },
  cancelAnimationFrame: () => undefined,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  localStorage: dom.window.localStorage,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement, Fragment } = await import("react");
const { createRoot } = await import("react-dom/client");
const { SummaryButton } = await import("./SummaryButton");
const { PinnedSummaryCard } = await import("./PinnedSummaryCard");
const { sanitizeSection, MAX_ROWS } = await import("./summaryRows");
const { PIN_KEY } = await import("./summaryPin");
const { UiProvider } = await import("../../../ui/UiProvider");
const SharedUiProvider = UiProvider as any;
type Props = Parameters<typeof PinnedSummaryCard>[0];

const tool = (fields: Partial<NonNullable<AcpmuxActivity["tool"]>>): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id: fields.title ?? "t", title: "", status: "completed", ...fields },
});
const rows: AcpmuxRow[] = [
  { id: "user-1", version: 1, at: 1, kind: "user", text: "go" },
  {
    id: "activity-2",
    version: 1,
    at: 2,
    kind: "activity",
    items: [
      tool({ id: "edit", kind: "edit", title: "Write", diffs: [{ path: "/repo/notes.md", newText: "hi\n" }] }),
      tool({
        id: "edit2",
        kind: "edit",
        title: "Write",
        diffs: [{ path: "/repo/a.ts", oldText: "a\n", newText: "b\n" }],
      }),
    ],
  },
];

let root: ReturnType<typeof createRoot> | undefined;
beforeEach(() => {
  wide = true;
  dom.window.localStorage.clear();
});
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
});

/// The header button and the card, as App mounts them, sharing one set of props.
async function render(props: Partial<Props> = {}) {
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  const all: Props = { rows, project: "atlas-web", folder: "/repo", ...props };
  await act(async () =>
    root!.render(
      createElement(
        SharedUiProvider,
        { container: container.ownerDocument.body, dir: "ltr" },
        createElement(Fragment, null, createElement(SummaryButton, all), createElement(PinnedSummaryCard, all)),
      ),
    ),
  );
  return {
    button: () => container.querySelector<HTMLButtonElement>(".acpmux-summary-button")!,
    card: () => dom.window.document.querySelector<HTMLElement>("[data-summary-card]"),
    popover: () => dom.window.document.querySelector<HTMLElement>(".acpmux-summary-popover"),
  };
}

test("a wide pane pins the card by default; the button unpins it and the choice persists", async () => {
  const view = await render();
  expect(view.card()).not.toBeNull();
  expect(view.card()!.textContent).toContain("atlas-web");
  expect(view.button().getAttribute("aria-pressed")).toBe("true");
  await act(async () => view.button().click());
  expect(view.card()).toBeNull();
  expect(dom.window.localStorage.getItem(PIN_KEY)).toBe("0");
  await act(async () => root!.unmount());
  const again = await render();
  expect(again.card()).toBeNull();
  // Unpinned, the button opens the popover; its pin control pins the card again.
  await act(async () => again.button().click());
  const pin = again.popover()!.querySelector<HTMLButtonElement>("[data-summary-pin]")!;
  await act(async () => pin.click());
  expect(again.card()).not.toBeNull();
  expect(again.popover()).toBeNull();
  expect(dom.window.localStorage.getItem(PIN_KEY)).toBe("1");
});

test("a narrow pane shows no card, pinned or not; the button opens the popover", async () => {
  wide = false;
  dom.window.localStorage.setItem(PIN_KEY, "1");
  const view = await render();
  expect(view.card()).toBeNull();
  await act(async () => view.button().click());
  expect(view.popover()).not.toBeNull();
  expect(view.popover()!.textContent).toContain("Changes");
});

test("the Changes row counts the chat's files and opens the changes view", async () => {
  let opened = 0;
  const view = await render({ onOpenChanges: () => (opened += 1) });
  const changes = view.card()!.querySelector<HTMLButtonElement>("[data-summary-changes]")!;
  expect(changes.textContent).toContain("2");
  await act(async () => changes.click());
  expect(opened).toBe(1);
});

test("custom rows are text only, links are allowlisted, and a section holds at most 50 rows", async () => {
  const section = sanitizeSection(
    {
      id: "ci",
      title: "CI",
      source: "user",
      rows: [
        { title: "<b>bold</b>", href: "javascript:alert(1)" },
        { title: "page", href: "https://ci.example.test/run/1" },
        { title: "data", href: "data:text/html,<script>1</script>" },
        { title: "notes", href: "/repo/notes.md" },
        ...Array.from({ length: 80 }, (_, index) => ({ title: `row ${index}` })),
      ],
    },
    "/repo",
  );
  expect(section.rows.length).toBe(MAX_ROWS);
  expect(section.rows[0]!.link).toBeUndefined();
  expect(section.rows[1]!.link).toEqual({
    kind: "url",
    url: "https://ci.example.test/run/1",
    host: "ci.example.test",
    confirm: false,
  });
  expect(section.rows[2]!.link).toBeUndefined();
  expect(section.rows[3]!.link).toEqual({ kind: "path", path: "/repo/notes.md" });
  const opened: string[] = [];
  const view = await render({
    onOpenOutput: (path) => opened.push(path),
    sections: [
      {
        id: "ci",
        title: "CI",
        source: "user",
        rows: [{ title: "<b>bold</b>" }, { title: "notes", href: "/repo/notes.md" }],
      },
    ],
  });
  const card = view.card()!;
  expect(card.textContent).toContain("<b>bold</b>");
  expect(card.querySelector("b")).toBeNull();
  await act(async () => card.querySelector<HTMLButtonElement>('[data-summary-path="/repo/notes.md"]')!.click());
  expect(opened).toEqual(["/repo/notes.md"]);
});

test("an agent's link asks first; a path inside the chat folder opens directly", async () => {
  const opened: string[] = [];
  const view = await render({
    onOpenOutput: (path) => opened.push(path),
    sections: [
      {
        id: "agent-ci",
        title: "Checks",
        source: "agent",
        rows: [
          { title: "run", href: "https://ci.example.test/run/2" },
          { title: "log", href: "/repo/log.txt" },
          { title: "outside", href: "/etc/passwd" },
        ],
      },
    ],
  });
  const card = view.card()!;
  const run = card.querySelector<HTMLElement>('[data-summary-url="https://ci.example.test/run/2"]')!;
  expect(run.tagName).toBe("BUTTON");
  await act(async () => run.click());
  const confirm = card.querySelector<HTMLElement>("[data-summary-confirm]")!;
  expect(confirm.textContent).toContain("ci.example.test");
  const open = confirm.querySelector<HTMLAnchorElement>("a[href]")!;
  expect(open.getAttribute("href")).toBe("https://ci.example.test/run/2");
  await act(async () => card.querySelector<HTMLButtonElement>('[data-summary-path="/repo/log.txt"]')!.click());
  expect(opened).toEqual(["/repo/log.txt"]);
  expect(card.querySelector('[data-summary-path="/etc/passwd"]')).toBeNull();
});

test("a failed provider shows one row with its reason", async () => {
  const view = await render({
    sections: [{ id: "deploys", title: "Deploys", source: "user", error: "command exited 2: not logged in" }],
  });
  const section = view.card()!.querySelector<HTMLElement>('[data-summary-section="deploys"]')!;
  expect(section.textContent).toContain("Deploys");
  expect(section.textContent).toContain("command exited 2: not logged in");
});
