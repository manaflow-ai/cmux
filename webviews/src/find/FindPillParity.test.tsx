// Lawrence, 2026-10-20: every Cmd-F bar must look the same. Find in Chat and Find in Diff both
// render the one shared find pill (ui/FindPill.tsx, the native FindPillView's twin): the same
// parts in the same order, the same "1 of 2" count, and the same step and close behavior.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "../pages/settings/testDom";
import type { DiffViewerLabelResolver } from "../labels";
import type { FindBarState } from "../agent-session/acpmux/conversation/chatFind";
import type { FindMatch } from "./model";
import type { DiffFindController } from "./useDiffFind";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { FindBar } = await import("./FindBar");
const { ChatFindBar } = await import("../agent-session/acpmux/conversation/ChatFindBar");

const label = ((key: string) =>
  ({
    findInDiff: "Find in diff",
    findPreviousMatch: "Previous match",
    findNextMatch: "Next match",
    findClose: "Close find",
    findCount: "{current} of {total}",
    findNoMatches: "No results",
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

type Calls = { next: number; previous: number; close: number };

async function render(node: (calls: Calls) => React.ReactNode) {
  const calls: Calls = { next: 0, previous: 0, close: 0 };
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => root.render(node(calls)));
  return { host, calls, done: async () => (await act(async () => root.unmount()), host.remove()) };
}

const diff = (matches: FindMatch[]) => (calls: Calls) => {
  const controller: DiffFindController = {
    matches,
    activeIndex: 0,
    activeMatch: matches[0] ?? null,
    setQuery: () => undefined,
    goToNext: () => void calls.next++,
    goToPrevious: () => void calls.previous++,
    closeFind: () => void calls.close++,
    findBarRef: () => undefined,
  };
  return <FindBar controller={controller} label={label} query="needle" requestToken={1} />;
};

const chat = (count: number) => (calls: Calls) => {
  const find = {
    open: true,
    query: "needle",
    matches: Array.from({ length: count }, (_, i) => i),
    active: 0,
    focusRequest: 1,
    setQuery: () => undefined,
    next: () => void calls.next++,
    previous: () => void calls.previous++,
    hide: () => void calls.close++,
  } as unknown as FindBarState;
  return <ChatFindBar find={find} />;
};

/** The pill's parts in order, by class: what a person sees from left to right. */
const anatomy = (host: HTMLElement) =>
  [...(host.querySelector(".find-pill")?.children ?? [])].map((part) => part.className.split(" ")[0]);

test("Find in Chat and Find in Diff are the same pill, part for part", async () => {
  const a = await render(diff([match(1), match(2)]));
  const b = await render(chat(2));
  expect(a.host.querySelectorAll(".find-pill")).toHaveLength(1);
  expect(b.host.querySelectorAll(".find-pill")).toHaveLength(1);
  expect(anatomy(a.host)).toEqual([
    "find-pill__icon",
    "find-pill__field",
    "find-pill__count",
    "find-pill__separator",
    "find-pill__button",
    "find-pill__button",
    "find-pill__button",
  ]);
  expect(anatomy(b.host)).toEqual(anatomy(a.host));
  expect(a.host.querySelector(".find-pill__count")?.textContent).toBe("1 of 2");
  expect(b.host.querySelector(".find-pill__count")?.textContent).toBe("1 of 2");
  await a.done();
  await b.done();
});

test("both say nothing matched the same way and disable the steps", async () => {
  for (const make of [diff([]), chat(0)]) {
    const r = await render(make);
    const count = r.host.querySelector(".find-pill__count")!;
    expect(count.hasAttribute("data-none")).toBe(true);
    const buttons = [...r.host.querySelectorAll<HTMLButtonElement>(".find-pill__button")];
    expect(buttons.filter((button) => button.disabled)).toHaveLength(2);
    await r.done();
  }
});

test("Enter, Shift-Enter and Escape step and close in both", async () => {
  for (const make of [diff([match(1), match(2)]), chat(2)]) {
    const r = await render(make);
    const field = r.host.querySelector<HTMLInputElement>(".find-pill__field")!;
    const key = (init: KeyboardEventInit) =>
      act(async () => field.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, ...init })));
    await key({ key: "Enter" });
    await key({ key: "Enter", shiftKey: true });
    await key({ key: "Escape" });
    expect(r.calls).toEqual({ next: 1, previous: 1, close: 1 });
    await r.done();
  }
});
