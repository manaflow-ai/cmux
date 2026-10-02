import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSessionEntry } from "./sessionList";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { SearchChats, searchChats } = await import("./SearchChats");

const sessions: AcpmuxSessionEntry[] = [
  { sessionId: "a", displayTitle: "Fix the checkout page", cwd: "/src/web", updatedAt: 10 },
  { sessionId: "b", displayTitle: "Port the sidebar", cwd: "/src/app", updatedAt: 30 },
  { sessionId: "c", displayTitle: "Closed one", updatedAt: 40, status: "closed" },
  ...Array.from({ length: 10 }, (_, index): AcpmuxSessionEntry => ({
    sessionId: `o${index}`,
    displayTitle: `Older ${index}`,
    updatedAt: index,
  })),
];

test("lists open chats newest first, at most nine, filtered by title", () => {
  expect(searchChats(sessions, "").map((s) => s.sessionId)).toEqual([
    "b",
    "a",
    "o9",
    "o8",
    "o7",
    "o6",
    "o5",
    "o4",
    "o3",
  ]);
  expect(searchChats(sessions, "SIDEBAR").map((s) => s.sessionId)).toEqual(["b"]);
  expect(searchChats(sessions, "closed")).toEqual([]);
});

test("typing filters, arrows move, Enter opens, Escape closes", async () => {
  const picked: string[] = [];
  let closed = 0;
  let created = 0;
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      createElement(SearchChats, {
        sessions,
        onSelect: (id: string) => picked.push(id),
        onNewChat: () => created++,
        onClose: () => closed++,
      }),
    ),
  );
  const input = document.querySelector<HTMLInputElement>(".acpmux-search-input")!;
  const key = (init: KeyboardEventInit) =>
    act(async () => void input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, ...init })));
  // React decides when react-dom loads whether the page has input events; a test file that
  // loads it before any DOM exists leaves it without them, so call the change handler directly
  // (as composer.test.tsx does).
  const type = (value: string) =>
    act(async () => {
      input.value = value;
      const props = (input as unknown as Record<string, { onChange(event: { target: HTMLInputElement }): void }>)[
        Object.keys(input).find((key) => key.startsWith("__reactProps$"))!
      ]!;
      props.onChange({ target: input });
    });
  expect(document.querySelectorAll(".acpmux-search-row")).toHaveLength(10);
  await key({ key: "ArrowDown" });
  await key({ key: "Enter" });
  expect(picked).toEqual(["a"]);
  await key({ key: "2", ctrlKey: true });
  expect(picked).toEqual(["a", "a"]);
  await type("new");
  expect([...document.querySelectorAll(".acpmux-search-label")].map((n) => n.textContent)).toEqual(["New chat"]);
  await key({ key: "Enter" });
  expect(created).toBe(1);
  await type("zzz");
  expect(document.querySelector(".acpmux-search-results")!.textContent).toContain("No results");
  await key({ key: "Escape" });
  expect(closed).toBe(1);
  await act(async () => root.unmount());
});
