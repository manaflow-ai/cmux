// l10n-allow-file: test fixture paths and file text, not shipped UI.
// Every edited-files card shows its Undo and its one chevron at rest. Long ago: every card of every
// past turn drew Undo, View changes and Second opinion, so a long chat read as a column of buttons
// (Leo, 2026-11-11: "holy fuck it's so shitty to look at the transcript right now"). Now a card has
// one way to a change, inline (Leo, 2026-11-22: "it should be able to just open inline inside the
// fucking existing agent chat situation."): no View changes button, nothing shown only on hover;
// the opened diff's Open in Changes icon opens the changes pane. Second opinion lives elsewhere.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];
setDefaultTimeout(30_000);

const css = fs.readFileSync(
  path.join(import.meta.dir, "../src/agent-session/acpmux/turnChanges/turnChanges.css"),
  "utf8",
);

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }));
  // The card's own rules only: the hover reveal under test, nothing that needs the motion tokens.
  const style = window.document.createElement("style");
  const cardCSS = fs.readFileSync(
    path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/EditedFilesCard.css"),
    "utf8",
  );
  style.textContent = cardCSS + css.replace(/@media[^{]*\{[\s\S]*\}\s*$/, "");
  window.document.head.append(style);
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    // The inline diff loads Pierre's diff element, which registers itself on customElements.
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // Pierre's registered elements (the inline diff) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  // An opened inline diff is a transcript disclosure, kept by row id and path across renders.
  const { resetTranscriptDisclosure } =
    await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
  resetTranscriptDisclosure();
});

afterAll(async () => {
  await settleReact();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// A finished turn's edit of `file`, as the pane folds an Edit call with its diff.
const editRow = (id: string, file: string): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "activity",
  ended: true,
  items: [
    {
      id: `${id}-call`,
      kind: "tool",
      text: `Edit ${file}`,
      at: 1,
      tool: {
        id: `${id}-call`,
        title: `Edit ${file}`,
        kind: "edit",
        status: "completed",
        diffs: [{ path: file, oldText: "a\n", newText: "b\n" }],
      },
    } as never,
  ],
});

const EARLIER = editRow("edit-earlier", "/repo/src/a.ts");
const LATEST = editRow("edit-latest", "/repo/src/b.ts");

async function renderCards(onOpenDiff: (rowId: string, path?: string, opener?: HTMLElement) => void = () => undefined) {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const { SessionEditsContext } = await import("../src/agent-session/acpmux/turnChanges/sessionRows");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SessionEditsContext.Provider value={[EARLIER, LATEST]}>
        <EditedFilesCard row={EARLIER} onOpenDiff={onOpenDiff} />
        <EditedFilesCard row={LATEST} onOpenDiff={onOpenDiff} />
      </SessionEditsContext.Provider>,
    ),
  );
  const [earlier, latest] = [...host.querySelectorAll<HTMLElement>(".acpmux-edited")];
  return { earlier: earlier!, latest: latest! };
}

const shown = (card: HTMLElement, selector: string) => {
  const button = card.querySelector<HTMLElement>(selector);
  expect(button).not.toBeNull();
  return window.getComputedStyle(button!).opacity !== "0";
};

// One way to see a change, and it opens inside the card (Leo, 2026-11-22: "there's anther issue of you
// being able to click on it to view changes and also click on a view changes button. decide." then
// "it should be able to just open inline inside the fucking existing agent chat situation."): no View
// changes button, no counts that turn into a link on hover; the header (or its chevron) opens the
// diff inline, and the opened diff's Open in Changes icon is the way to the changes pane.
test("every card shows its Undo and its one chevron at rest, as the Codex app does (Lucas, 2026-11-14)", async () => {
  const { earlier, latest } = await renderCards();
  expect(earlier.hasAttribute("data-earlier")).toBe(true);
  expect(latest.hasAttribute("data-earlier")).toBe(false);
  for (const card of [earlier, latest]) {
    expect(shown(card, ".acpmux-edited-chevron")).toBe(true);
    expect(shown(card, ".acpmux-edited-undo")).toBe(true);
    expect(card.querySelector(".acpmux-review-changes")).toBeNull();
    expect(card.querySelector(".acpmux-edited-summary, .acpmux-edited-summary-link")).toBeNull();
  }
});

test("an earlier card's chevron takes keyboard focus and stays shown", async () => {
  const { earlier } = await renderCards();
  const chevron = earlier.querySelector<HTMLElement>(".acpmux-edited-chevron")!;
  await act(async () => chevron.focus());
  expect(chevron.ownerDocument.activeElement).toBe(chevron);
  expect(shown(earlier, ".acpmux-edited-chevron")).toBe(true);
  expect(shown(earlier, ".acpmux-edited-undo")).toBe(true);
});

test("cards keep only Undo in their actions, with no View changes or Second opinion", async () => {
  const opened: string[] = [];
  const { earlier, latest } = await renderCards((rowId) => opened.push(rowId));
  for (const card of [earlier, latest]) {
    expect(card.querySelector(".acpmux-second-opinion")).toBeNull();
    const actions = card.querySelector(".acpmux-edited-actions")!;
    const buttons = [...actions.querySelectorAll("button")];
    expect(buttons.map((button) => button.getAttribute("aria-label"))).toEqual(["Undo"]);
    // Undo is a quiet icon: no words drawn, its name in its label and tooltip (Leo, 2026-11-23: "why buttons here").
    expect(buttons.map((button) => button.textContent?.trim())).toEqual([""]);
    expect(buttons.map((button) => button.getAttribute("title"))).toEqual(["Undo"]);
    // Every button the card shows at rest: Undo and the one chevron, never a second way to the diff.
    expect([...card.querySelectorAll("button")].map((button) => button.getAttribute("aria-label"))).toEqual([
      "Undo",
      "View changes",
    ]);
  }
  expect(opened).toEqual([]);
});

test("a lone card with no session rows is the latest", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  root = createRoot(host);
  await act(async () => root!.render(<EditedFilesCard row={EARLIER} onOpenDiff={() => undefined} />));
  const card = host.querySelector<HTMLElement>(".acpmux-edited")!;
  expect(card.hasAttribute("data-earlier")).toBe(false);
  expect(shown(card, ".acpmux-edited-chevron")).toBe(true);
});

test("the one-file card's chevron is keyboard reachable and opens its diff inline; Open in Changes opens the pane", async () => {
  const opened: { rowId: string; path?: string; opener?: HTMLElement }[] = [];
  const { latest } = await renderCards((rowId, path, opener) => opened.push({ rowId, path, opener }));
  // The counts are plain counts: no button, no hover-revealed link.
  expect(latest.querySelector(".acpmux-edited-sub .acpmux-diff-counts")?.textContent).toBe("+1-1");
  expect(latest.querySelector(".acpmux-edited-sub button")).toBeNull();
  const chevron = latest.querySelector<HTMLButtonElement>("button.acpmux-edited-chevron")!;
  expect(chevron.getAttribute("aria-label")).toBe("View changes");
  expect(chevron.getAttribute("aria-expanded")).toBe("false");
  await act(async () => chevron.focus());
  expect(window.document.activeElement).toBe(chevron);
  await act(async () => chevron.click());
  // Inline, not the changes pane.
  expect(opened).toEqual([]);
  expect(chevron.getAttribute("aria-expanded")).toBe("true");
  expect(latest.querySelector(".acpmux-edited-diff .cv-edit-diff")).not.toBeNull();
  const open = latest.querySelector<HTMLButtonElement>(".acpmux-edited-diff button.acpmux-edited-open")!;
  expect(open.getAttribute("aria-label")).toBe("Open in Changes");
  await act(async () => open.click());
  expect(opened).toEqual([{ rowId: "edit-latest", path: "/repo/src/b.ts", opener: open }]);
  await act(async () => chevron.click());
  expect(chevron.getAttribute("aria-expanded")).toBe("false");
});

test("file rows retain shared parent paths and exact diff targets without inventing Undo support", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const first = editRow("relative-first", "src/net/retry.ts");
  const second = editRow("relative-second", "src/net/client.ts");
  const row = { ...first, items: [...first.items!, ...second.items!] };
  const opened: unknown[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(<EditedFilesCard row={row} onOpenDiff={(id, path) => opened.push({ id, path })} />),
  );
  const fileRows = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-edited-file")];
  expect(fileRows.map((file) => file.querySelector(".acpmux-edited-dir")?.textContent)).toEqual([
    "src/net/",
    "src/net/",
  ]);
  expect(fileRows.map((file) => file.querySelector(".acpmux-edited-base")?.textContent)).toEqual([
    "retry.ts",
    "client.ts",
  ]);
  expect(host.querySelector(".acpmux-edited-undo")).toBeNull();
  // A file row opens its own diff under it, not the changes pane; its Open in Changes icon does.
  expect(fileRows.map((file) => file.getAttribute("aria-expanded"))).toEqual(["false", "false"]);
  await act(async () => fileRows[1]!.click());
  expect(opened).toEqual([]);
  expect(fileRows.map((file) => file.getAttribute("aria-expanded"))).toEqual(["false", "true"]);
  const entries = [...host.querySelectorAll<HTMLElement>(".acpmux-edited-entry")];
  expect(entries.map((entry) => entry.querySelector(".acpmux-edited-diff .cv-edit-diff") !== null)).toEqual([
    false,
    true,
  ]);
  await act(async () => entries[1]!.querySelector<HTMLButtonElement>(".acpmux-edited-open")!.click());
  expect(opened).toEqual([{ id: row.id, path: "src/net/client.ts" }]);
});

test("a file outside the checkpoint reads from the chat's folder, not from the disk root (Lucas, 2026-11-14)", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const { SessionCwdContext } = await import("../src/agent-session/acpmux/turnChanges/sessionRows");
  const first = editRow("absolute-first", "/Users/me/code/app/webviews/test/scratch.test.ts");
  const second = editRow("absolute-second", "/Users/me/code/app/webviews/test/other.test.ts");
  const row = { ...first, items: [...first.items!, ...second.items!] };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SessionCwdContext.Provider value="/Users/me/code">
        <EditedFilesCard row={row} onOpenDiff={() => undefined} />
      </SessionCwdContext.Provider>,
    ),
  );
  const file = host.querySelector<HTMLElement>(".acpmux-edited-file")!;
  expect(file.querySelector(".acpmux-edited-dir-head")?.textContent).toBe("app/");
  expect(file.querySelector(".acpmux-edited-dir")?.textContent).toBe("app/webviews/test/");
  expect(file.querySelector(".acpmux-edited-base")?.textContent).toBe("scratch.test.ts");
  // The diff still opens at the full path.
  expect(file.querySelector(".acpmux-edited-path")?.getAttribute("data-path")).toBe(
    "/Users/me/code/app/webviews/test/scratch.test.ts",
  );
});

test("without a diff opener, the diff still opens inline, with no Open in Changes", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  root = createRoot(host);
  await act(async () => root!.render(<EditedFilesCard row={LATEST} />));
  expect(host.querySelector(".acpmux-review-changes")).toBeNull();
  await act(async () => host.querySelector<HTMLElement>(".acpmux-edited-head")!.click());
  expect(host.querySelector(".acpmux-edited-diff .cv-edit-diff")).not.toBeNull();
  expect(host.querySelector(".acpmux-edited-open")).toBeNull();
  expect(host.querySelector(".acpmux-edited-sub .acpmux-diff-counts")?.textContent).toBe("+1-1");
});
