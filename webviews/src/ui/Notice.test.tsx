// The notice system's contract (leo-workspace design/notifications.md): an error's Retry leads and is
// the one filled button, the × comes last in the tab order, Escape inside closes, the checkmark is a
// real checkbox; the queue replaces by id, keeps three, and a toast's time stops while the stack is
// hovered and starts again in full after.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Notice, noticeButtons, noticeRole } from "./Notice";
import { createNoticeQueue, NoticeStack } from "./NoticeStack";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "PointerEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const noop = () => undefined;
const labels = (doc: Document) =>
  [...doc.querySelectorAll("button")].map((b) => b.getAttribute("aria-label") ?? b.textContent);

test("an error's Retry leads and is the one filled button; the × comes last", () => {
  const doc = render(
    <Notice
      kind="error"
      message="Lost the connection."
      retry={{ label: "Retry", onRetry: noop }}
      actions={[{ id: "details", label: "Details", primary: true, onSelect: noop }]}
      onDismiss={noop}
      dismissLabel="Dismiss"
    />,
  );
  expect(labels(doc)).toEqual(["Retry", "Details", "Dismiss"]);
  expect(doc.querySelector('[data-notice-action="retry"]')?.getAttribute("data-variant")).toBe("solid");
  expect(doc.querySelector('[data-notice-action="details"]')?.getAttribute("data-variant")).toBe("ghost");
  expect(doc.querySelector(".ui-notice")?.getAttribute("role")).toBe("alert");
});

test("an ask fills its first answer when none is marked; roles follow the kind", () => {
  const buttons = noticeButtons("ask", [
    { id: "start", label: "Start", onSelect: noop },
    { id: "notNow", label: "Not now", onSelect: noop },
  ]);
  expect(buttons.map((b) => b.filled)).toEqual([true, false]);
  expect(noticeButtons("toast", [{ id: "undo", label: "Undo", onSelect: noop }])[0]?.filled).toBe(false);
  expect([noticeRole("toast"), noticeRole("warning"), noticeRole("ask"), noticeRole("error")]).toEqual([
    "status",
    "status",
    "group",
    "alert",
  ]);
});

test("Escape inside a dismissible notice closes it", () => {
  let closed = 0;
  const doc = render(
    <Notice kind="warning" message="Disk is nearly full." onDismiss={() => closed++} dismissLabel="Dismiss" />,
  );
  const button = doc.querySelector("button")!;
  act(() => {
    button.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(closed).toBe(1);
});

test("the checkmark is a checkbox that reports its new value", () => {
  const seen: boolean[] = [];
  const doc = render(
    <Notice
      kind="ask"
      message="Start claude on Cloud?"
      check={{ label: "Ask me first", checked: false, onCheckedChange: (next) => seen.push(next) }}
    />,
  );
  const box = doc.querySelector('[role="checkbox"]')!;
  expect(box.getAttribute("aria-checked")).toBe("false");
  act(() => {
    box.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  });
  expect(seen).toEqual([true]);
});

test("the queue replaces by id, keeps the newest three and says why each left", () => {
  const queue = createNoticeQueue();
  const reasons: string[] = [];
  const close = (name: string) => (reason: string) => reasons.push(`${name}:${reason}`);
  queue.show({ id: "a", message: "a", onClose: close("a") });
  queue.show({ id: "b", message: "b", onClose: close("b") });
  queue.show({ id: "a", message: "a2", onClose: close("a2") });
  expect(queue.snapshot().map((e) => e.spec.message)).toEqual(["a2", "b"]);
  queue.show({ id: "c", message: "c" });
  queue.show({ id: "d", message: "d" });
  expect(queue.snapshot().map((e) => e.spec.id)).toEqual(["b", "c", "d"]);
  queue.close("c", "action");
  expect(reasons).toEqual(["a:replaced", "a2:replaced"]);
  expect(queue.snapshot().map((e) => e.spec.id)).toEqual(["b", "d"]);
});

test("a queue keeps at least the newest toast, whatever its limit", () => {
  const queue = createNoticeQueue(0);
  const closed: string[] = [];
  for (const id of ["a", "b"]) queue.show({ id, message: id, onClose: (reason) => closed.push(`${id}:${reason}`) });
  expect(queue.snapshot().map((entry) => entry.spec.id)).toEqual(["b"]);
  expect(closed).toEqual(["a:replaced"]);
});

test("an onClose that changes the queue sees it already changed", () => {
  // Replaced: closing a toast ahead of it must not leave the old toast in place of the new one.
  const replaced = createNoticeQueue();
  replaced.show({ id: "b", message: "b" });
  replaced.show({ id: "a", message: "a", onClose: () => replaced.close("b") });
  replaced.show({ id: "a", message: "a2" });
  expect(replaced.snapshot().map((entry) => entry.spec.message)).toEqual(["a2"]);
  // Pushed out: showing a toast from the evicted one's onClose must not evict it again.
  const evicted = createNoticeQueue(2);
  evicted.show({ id: "a", message: "a", onClose: () => evicted.show({ id: "x", message: "x" }) });
  evicted.show({ id: "b", message: "b" });
  evicted.show({ id: "c", message: "c" });
  expect(evicted.snapshot().map((entry) => entry.spec.id)).toEqual(["c", "x"]);
});

test("a toast times out, but not while the stack is hovered, and gets its full time after", () => {
  let clock = 0;
  const armed: { fire(): void; ms: number; live: boolean }[] = [];
  const arm = (fire: () => void, ms: number) => {
    const timer = { fire, ms, live: true };
    armed.push(timer);
    return () => {
      timer.live = false;
    };
  };
  const live = () => armed.filter((timer) => timer.live);
  const queue = createNoticeQueue();
  queue.show({ id: "t", message: "Copied.", duration: 4000 });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" now={() => clock} arm={arm} />);
  expect(live().map((timer) => timer.ms)).toEqual([4000]);
  const stack = doc.querySelector(".ui-notice-stack")!;
  // React listens for pointerover/out to make pointerenter/leave.
  act(() => {
    stack.dispatchEvent(new dom!.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: doc.body }));
  });
  expect(live()).toHaveLength(0);
  clock = 3000;
  act(() => {
    stack.dispatchEvent(new dom!.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: doc.body }));
  });
  expect(live().map((timer) => timer.ms)).toEqual([4000]);
  act(() => live()[0]!.fire());
  expect(queue.snapshot()).toHaveLength(0);
  expect(live()).toHaveLength(0);
});
