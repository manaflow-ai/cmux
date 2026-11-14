// l10n-allow-file: test fixture paths and file text, not shipped UI.
// Only the chat's latest edited-files card shows its buttons at rest. Before: every card of every
// past turn drew Undo, View changes and Second opinion, so a long chat read as a column of buttons
// (Leo, 2026-11-11: "holy fuck it's so shitty to look at the transcript right now"). Now an earlier
// card's buttons show on its hover or keyboard focus, as an earlier reply's footer does. Second
// opinion is available elsewhere, not on this card; an Undo under way keeps its buttons shown.
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
  "MutationObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
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
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
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

async function renderCards(
  secondOpinion?: (rowId: string, files: readonly string[]) => void,
  onOpenDiff: (rowId: string) => void = () => undefined,
) {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const { SessionEditsContext } = await import("../src/agent-session/acpmux/turnChanges/sessionRows");
  const { SecondOpinionContext } = await import("../src/agent-session/acpmux/conversation/secondOpinion");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SessionEditsContext.Provider value={[EARLIER, LATEST]}>
        <SecondOpinionContext.Provider value={secondOpinion}>
          <EditedFilesCard row={EARLIER} onOpenDiff={onOpenDiff} />
          <EditedFilesCard row={LATEST} onOpenDiff={onOpenDiff} />
        </SecondOpinionContext.Provider>
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

test("an earlier card's View changes waits for hover; the latest card's shows at rest", async () => {
  const { earlier, latest } = await renderCards();
  expect(earlier.hasAttribute("data-earlier")).toBe(true);
  expect(latest.hasAttribute("data-earlier")).toBe(false);
  expect(shown(earlier, ".acpmux-review-changes")).toBe(false);
  expect(shown(latest, ".acpmux-review-changes")).toBe(true);
});

test("keyboard focus on an earlier card shows its buttons", async () => {
  const { earlier } = await renderCards(() => undefined);
  await act(async () => earlier.querySelector<HTMLElement>(".acpmux-review-changes")!.focus());
  expect(shown(earlier, ".acpmux-review-changes")).toBe(true);
  expect(shown(earlier, ".acpmux-edited-undo")).toBe(true);
});

test("cards retain Undo and View changes without offering Second opinion", async () => {
  const asked: string[] = [];
  const opened: string[] = [];
  const { earlier, latest } = await renderCards(
    (rowId) => asked.push(rowId),
    (rowId) => opened.push(rowId),
  );
  for (const card of [earlier, latest]) {
    expect(card.querySelector(".acpmux-second-opinion")).toBeNull();
    const actions = card.querySelector(".acpmux-edited-actions")!;
    expect([...actions.querySelectorAll("button")].map((button) => button.textContent)).toEqual([
      "Undo",
      "View changes",
    ]);
  }
  await act(async () => latest.querySelector<HTMLElement>(".acpmux-review-changes")!.click());
  expect(opened).toEqual(["edit-latest"]);
  expect(asked).toEqual([]);
});

test("a lone card with no session rows is the latest", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  root = createRoot(host);
  await act(async () => root!.render(<EditedFilesCard row={EARLIER} onOpenDiff={() => undefined} />));
  const card = host.querySelector<HTMLElement>(".acpmux-edited")!;
  expect(card.hasAttribute("data-earlier")).toBe(false);
  expect(shown(card, ".acpmux-review-changes")).toBe(true);
});

test("the aggregate is keyboard reachable and opens that card without toggling its inline diff", async () => {
  const opened: string[] = [];
  const { latest } = await renderCards(undefined, (rowId) => opened.push(rowId));
  const summary = latest.querySelector<HTMLButtonElement>(".acpmux-edited-summary")!;
  const counts = summary.querySelector<HTMLElement>(".acpmux-edited-summary-counts")!;
  const link = summary.querySelector<HTMLElement>(".acpmux-edited-summary-link")!;
  expect(summary.getAttribute("aria-label")).toBe("View changes +1 -1");
  expect(counts.textContent).toBe("+1-1");
  await act(async () => summary.focus());
  expect(window.document.activeElement).toBe(summary);
  expect(link.textContent).toBe("View changes");
  await act(async () => summary.click());
  expect(opened).toEqual(["edit-latest"]);
  expect(latest.querySelector(".acpmux-edited-diff")).toBeNull();
  await act(async () => summary.blur());
  expect(window.document.activeElement).not.toBe(summary);
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
  await act(async () => fileRows[1]!.click());
  expect(opened).toEqual([{ id: row.id, path: "src/net/client.ts" }]);
});

test("without a diff opener, the aggregate remains static counts", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  root = createRoot(host);
  await act(async () => root!.render(<EditedFilesCard row={LATEST} />));
  expect(host.querySelector(".acpmux-edited-summary")).toBeNull();
  expect(host.querySelector(".acpmux-review-changes")).toBeNull();
  expect(host.querySelector(".acpmux-edited-sub .acpmux-diff-counts")?.textContent).toBe("+1-1");
});
