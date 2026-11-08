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

test("a toast with no id never replaces one whose caller picked a generated-looking id", () => {
  const queue = createNoticeQueue();
  queue.show({ id: "toast-1", message: "mine" });
  const id = queue.show({ message: "new" });
  expect(id).not.toBe("toast-1");
  expect(queue.snapshot().map((entry) => entry.spec.message)).toEqual(["mine", "new"]);
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

test("the same toast shown again is one toast with a count, moved to the newest place", () => {
  const queue = createNoticeQueue();
  const closed: string[] = [];
  const first = queue.show({ message: "Can't find dev's chat", onClose: (reason) => closed.push(reason) });
  queue.show({ message: "Copied." });
  const again = queue.show({ message: "Can't find dev's chat" });
  expect(again).toBe(first);
  expect(queue.snapshot().map((entry) => [entry.spec.message, entry.count])).toEqual([
    ["Copied.", 1],
    ["Can't find dev's chat", 2],
  ]);
  // Not the same: another kind, or a toast whose text is not plain.
  queue.show({ kind: "error", message: "Copied." });
  expect(queue.snapshot().map((entry) => entry.count)).toEqual([1, 2, 1]);
  expect(closed).toEqual([]);
  // A caller's id shown again with the same text counts too; with new text it replaces.
  const ids = createNoticeQueue();
  ids.show({ id: "copy", message: "Copied." });
  ids.show({ id: "copy", message: "Copied." });
  expect(ids.snapshot().map((entry) => entry.count)).toEqual([2]);
  ids.show({ id: "copy", message: "Copied the link." });
  expect(ids.snapshot().map((entry) => [entry.spec.message, entry.count])).toEqual([["Copied the link.", 1]]);
});

test("a count shows after the toast's text", () => {
  const queue = createNoticeQueue();
  queue.show({ message: "Copied." });
  queue.show({ message: "Copied." });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" />);
  expect(doc.querySelector(".ui-notice-count")?.textContent).toBe("×2");
});

test("the stacked deck puts the newest in front and spreads while hovered", () => {
  const queue = createNoticeQueue();
  for (const message of ["one", "two", "three"]) queue.show({ message, duration: 0 });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" />);
  const cards = () => [...doc.querySelectorAll<HTMLElement>(".ui-notice-deck-card")];
  // In screen order: a bottom deck grows upward, so the front (newest) toast is last in the DOM.
  expect(cards().map((card) => card.textContent)).toEqual(["one", "two", "three"]);
  expect(cards()[2]!.hasAttribute("data-front")).toBe(true);
  const deck = doc.querySelector('.ui-notice-anchor[data-anchor="bottom"] > .ui-notice-deck')!;
  expect(deck.hasAttribute("data-expanded")).toBe(false);
  // Gathered: each older card a step back and smaller.
  expect(cards().map((card) => card.style.getPropertyValue("--ui-notice-deck-scale"))).toEqual(["0.9", "0.95", "1"]);
  act(() => {
    cards()[2]!.dispatchEvent(new dom!.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: doc.body }));
  });
  expect(deck.hasAttribute("data-expanded")).toBe(true);
  expect(cards().map((card) => card.style.getPropertyValue("--ui-notice-deck-scale"))).toEqual(["1", "1", "1"]);
  act(() => {
    cards()[2]!.dispatchEvent(new dom!.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: doc.body }));
  });
  expect(deck.hasAttribute("data-expanded")).toBe(false);
});

test("a gathered deck's older cards are inert and hidden from assistive tech until it spreads (review F2)", () => {
  const queue = createNoticeQueue();
  for (const message of ["one", "two", "three"]) queue.show({ message, duration: 0 });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" />);
  const cards = () => [...doc.querySelectorAll<HTMLElement>(".ui-notice-deck-card")];
  const concealed = () =>
    cards().map((card) => card.hasAttribute("inert") && card.getAttribute("aria-hidden") === "true");
  // Gathered: only the front card can be reached; focusing it spreads the deck.
  expect(concealed()).toEqual([true, true, false]);
  act(() => {
    cards()[2]!.dispatchEvent(new dom!.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: doc.body }));
  });
  expect(concealed()).toEqual([false, false, false]);
});

test("a new toast enters the deck's front; a closed one leaves (at once with no motion)", () => {
  const queue = createNoticeQueue();
  queue.show({ id: "a", message: "a", duration: 0 });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" />);
  act(() => void queue.show({ id: "b", message: "b", duration: 0 }));
  const cards = () => [...doc.querySelectorAll<HTMLElement>(".ui-notice-deck-card")];
  expect(cards().map((card) => [card.textContent, card.dataset.phase])).toEqual([
    ["a", "shown"],
    ["b", "shown"],
  ]);
  act(() => queue.close("b"));
  // A test document runs no transition, so the leaving card goes in the same commit.
  expect(cards().map((card) => card.textContent)).toEqual(["a"]);
});

test("in the deck, a toast's time stops while hovered, and a persistent toast's action runs and closes it", () => {
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
  const ran: string[] = [];
  const reasons: string[] = [];
  queue.show({
    id: "keep",
    message: "Archived 3 chats.",
    duration: 0,
    actions: [{ id: "undo", label: "Undo", onSelect: () => ran.push("undo") }],
    onClose: (reason) => reasons.push(reason),
  });
  queue.show({ id: "t", message: "Copied.", duration: 4000 });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" now={() => clock} arm={arm} />);
  // Only the timed toast arms a timer; the persistent one never does.
  expect(live().map((timer) => timer.ms)).toEqual([4000]);
  const stack = doc.querySelector(".ui-notice-stack")!;
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
  expect(queue.snapshot().map((entry) => entry.spec.id)).toEqual(["keep"]);
  expect(live()).toHaveLength(0);
  const undo = doc.querySelector<HTMLButtonElement>('[data-notice-action="undo"]')!;
  act(() => undo.click());
  expect(ran).toEqual(["undo"]);
  expect(reasons).toEqual(["action"]);
  expect(queue.snapshot()).toHaveLength(0);
});

test("a held toast never times out, and one dragged past the edge is closed", () => {
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
  const reasons: string[] = [];
  queue.show({ id: "t", message: "Copied.", duration: 4000, onClose: (reason) => reasons.push(reason) });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" drag="spring" arm={arm} />);
  expect(live().map((timer) => timer.ms)).toEqual([4000]);
  const card = doc.querySelector<HTMLElement>(".ui-notice-deck-card")!;
  const pointer = (type: string, x: number, y: number) =>
    act(() => {
      card.dispatchEvent(
        new dom!.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }),
      );
    });
  pointer("pointerdown", 100, 100);
  pointer("pointermove", 140, 90);
  // Held: it follows the pointer and its time stops.
  expect(card.hasAttribute("data-dragging")).toBe(true);
  expect(card.style.getPropertyValue("--ui-notice-drag-x")).toBe("40px");
  expect(live()).toHaveLength(0);
  // Let go far past the surface's edge: it goes, closed.
  pointer("pointermove", 2000, 90);
  pointer("pointerup", 2000, 90);
  expect(reasons).toEqual(["closed"]);
  expect(queue.snapshot()).toHaveLength(0);
});
