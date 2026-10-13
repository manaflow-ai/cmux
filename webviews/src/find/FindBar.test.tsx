import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "../pages/settings/testDom";
import type { DiffViewerLabelResolver } from "../labels";
import type { FindMatch } from "./model";
import { FindBar } from "./FindBar";
import type { DiffFindController } from "./useDiffFind";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");

const label = ((key: string) =>
  ({
    findInDiff: "Find in diff",
    findPreviousMatch: "Previous match",
    findNextMatch: "Next match",
    findClose: "Close find",
  })[key] ?? key) as DiffViewerLabelResolver;

const match = (lineNumber: number): FindMatch => ({
  itemId: "fixture.ts",
  side: "additions",
  lineNumber,
  start: 0,
  length: 6,
  occurrence: 0,
  lineText: "needle",
});

async function renderBar(overrides: Partial<DiffFindController> = {}) {
  let nextCalls = 0;
  let previousCalls = 0;
  let closeCalls = 0;
  const controller: DiffFindController = {
    matches: [match(1), match(2)],
    activeIndex: 0,
    activeMatch: match(1),
    setQuery: () => undefined,
    goToNext: () => {
      nextCalls += 1;
    },
    goToPrevious: () => {
      previousCalls += 1;
    },
    closeFind: () => {
      closeCalls += 1;
    },
    findBarRef: () => undefined,
    ...overrides,
  };
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(<FindBar controller={controller} label={label} query="needle" requestToken={1} />);
  });
  return {
    host,
    root,
    controller,
    calls: () => ({ nextCalls, previousCalls, closeCalls }),
  };
}

test("focuses and selects the recovered query, then reports the active match count", async () => {
  const rendered = await renderBar();
  const input = rendered.host.querySelector<HTMLInputElement>("#diff-find-input")!;
  expect(document.activeElement).toBe(input);
  expect(rendered.host.querySelector("#diff-find-count")?.textContent).toBe("1/2");
  await act(async () => rendered.root.unmount());
  rendered.host.remove();
});

test("Enter, Shift+Enter, and Escape delegate to the controller", async () => {
  const rendered = await renderBar();
  const input = rendered.host.querySelector<HTMLInputElement>("#diff-find-input")!;
  await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  await act(async () =>
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", shiftKey: true, bubbles: true })),
  );
  await act(async () => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  expect(rendered.calls()).toEqual({ nextCalls: 1, previousCalls: 1, closeCalls: 1 });
  await act(async () => rendered.root.unmount());
  rendered.host.remove();
});

test("disables navigation buttons when the query has no matches", async () => {
  const rendered = await renderBar({ matches: [], activeMatch: null });
  const buttons = [...rendered.host.querySelectorAll<HTMLButtonElement>("button")];
  expect(buttons.filter((button) => button.disabled)).toHaveLength(2);
  await act(async () => rendered.root.unmount());
  rendered.host.remove();
});
