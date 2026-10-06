import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSessionEntry } from "./sessionList";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
// WebKit has AnimationEvent; without it React listens for the prefixed webkitAnimationEnd.
(dom.window as unknown as Record<string, unknown>).AnimationEvent ??= dom.window.Event;
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
const { SearchChats, searchChats, nextSearchState } = await import("./SearchChats");

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

test("an archived chat is found only by its title, and says it is archived", async () => {
  const archived: AcpmuxSessionEntry = { sessionId: "z", displayTitle: "Old spike", updatedAt: 99, archived: true };
  expect(searchChats([...sessions, archived], "").map((s) => s.sessionId)).not.toContain("z");
  expect(searchChats([...sessions, archived], "spike").map((s) => s.sessionId)).toEqual(["z"]);
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(createElement(SearchChats, { sessions: [archived], onSelect() {}, onNewChat() {}, onClose() {} })),
  );
  const input = document.querySelector<HTMLInputElement>(".acpmux-search-input")!;
  await act(async () => {
    input.value = "spike";
    const props = (input as unknown as Record<string, { onChange(event: { target: HTMLInputElement }): void }>)[
      Object.keys(input).find((key) => key.startsWith("__reactProps$"))!
    ]!;
    props.onChange({ target: input });
  });
  expect(document.querySelector(".acpmux-search-row .acpmux-search-meta")?.textContent).toBe("Archived");
  await act(async () => root.unmount());
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

test("a closing sheet lets clicks through and reports the end of its own exit animation once", async () => {
  let exited = 0;
  const root = createRoot(document.getElementById("root")!);
  const render = (closing: boolean) =>
    act(async () =>
      root.render(
        createElement(SearchChats, {
          sessions,
          closing,
          onSelect: () => {},
          onNewChat: () => {},
          onClose: () => {},
          onExited: () => exited++,
        }),
      ),
    );
  await render(false);
  const layer = document.querySelector<HTMLElement>(".acpmux-search-layer")!;
  const sheet = document.querySelector<HTMLElement>(".acpmux-search")!;
  const end = (target: Element) =>
    act(async () => void target.dispatchEvent(new dom.window.Event("animationend", { bubbles: true })));
  // The open animation ending is not an exit.
  await end(sheet);
  expect(exited).toBe(0);
  expect(layer.classList.contains("is-closing")).toBe(false);
  await render(true);
  expect(layer.classList.contains("is-closing")).toBe(true);
  expect(layer.getAttribute("aria-hidden")).toBe("true");
  // A row's own animation bubbling up does not end the sheet's exit.
  await end(document.querySelector(".acpmux-search-row")!);
  expect(exited).toBe(0);
  await end(sheet);
  expect(exited).toBe(1);
  await act(async () => root.unmount());
});

test("open and close move through the exit state only while motion is on", () => {
  // Cmd-K toggles; a close during the exit reopens at once from what is on screen.
  expect(nextSearchState("closed", "toggle", true)).toBe("open");
  expect(nextSearchState("open", "toggle", true)).toBe("closing");
  expect(nextSearchState("closing", "toggle", true)).toBe("open");
  expect(nextSearchState("open", "close", true)).toBe("closing");
  expect(nextSearchState("closing", "close", true)).toBe("closing");
  expect(nextSearchState("closed", "close", true)).toBe("closed");
  expect(nextSearchState("closing", "exited", true)).toBe("closed");
  expect(nextSearchState("open", "exited", true)).toBe("open");
  // Reduce Motion (no exit animation runs, so no animationend arrives): close at once.
  expect(nextSearchState("open", "toggle", false)).toBe("closed");
  expect(nextSearchState("open", "close", false)).toBe("closed");
});
