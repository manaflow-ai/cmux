// Toasts v2 (toastsV2.experiment.ts; Leo 2026-11-19, promise toasts with Undo): a promise toast is one
// card that turns from working into its result in place, with no timeout while it works and its
// normal time after; a v2 toast's Undo is the ink-filled button that runs and closes; the default
// arm draws exactly today's card.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Notice } from "./Notice";
import { createNoticeQueue, NoticeStack, TOAST_MS } from "./NoticeStack";
import { toastsV2 } from "./toastsV2.experiment";
import { validateExperiments } from "../experiments/experiment";
import { experimentById } from "../experiments/registry";
import { setExperimentSwitches } from "../experiments/switches";

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

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

/** A fake timer: what the stack armed, and whether it is still live. */
function timers() {
  const armed: { fire(): void; ms: number; live: boolean }[] = [];
  const arm = (fire: () => void, ms: number) => {
    const timer = { fire, ms, live: true };
    armed.push(timer);
    return () => {
      timer.live = false;
    };
  };
  return { arm, live: () => armed.filter((timer) => timer.live) };
}

const faces = {
  loading: { message: "Running tests…" },
  success: { message: "128 tests passed." },
  error: (reason: unknown) => ({ title: "Tests failed", message: String((reason as Error).message) }),
};

test("the experiment is registered, valid, and ships today's look", () => {
  expect(validateExperiments([toastsV2])).toEqual([]);
  expect(experimentById("toasts-v2")).toBe(toastsV2);
  expect(toastsV2.defaultArm).toBe("off");
  expect(Object.keys(toastsV2.arms).length).toBeGreaterThanOrEqual(4);
  expect(toastsV2.arms.tinted.description).toContain("never-red-slabs");
});

test("a promise toast is replaced in place: same id, same index, one card", async () => {
  const queue = createNoticeQueue();
  queue.show({ id: "a", message: "Copied." });
  const work = deferred();
  const id = queue.promise("tests", faces, work.promise);
  queue.show({ id: "b", message: "Moved." });
  expect(id).toBe("tests");
  expect(queue.snapshot().map((entry) => [entry.spec.id, entry.spec.state])).toEqual([
    ["a", undefined],
    ["tests", "working"],
    ["b", undefined],
  ]);
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="list" look="mark" />);
  const before = doc.getElementById("tests");
  await act(async () => {
    work.resolve();
    await work.promise;
  });
  expect(queue.snapshot().map((entry) => [entry.spec.id, entry.spec.state])).toEqual([
    ["a", undefined],
    ["tests", "success"],
    ["b", undefined],
  ]);
  expect(doc.querySelectorAll(".ui-notice")).toHaveLength(3);
  expect(doc.querySelectorAll("#tests")).toHaveLength(1);
  // The same element, changed in place: React kept the card, so nothing popped in.
  expect(doc.getElementById("tests")).toBe(before);
  expect(before?.getAttribute("data-state")).toBe("success");
  expect(before?.textContent).toContain("128 tests passed.");
  expect(before?.querySelector(".ui-notice-mark")?.getAttribute("data-kind")).toBe("success");
});

test("working has no timeout; its result gets the normal time", async () => {
  const { arm, live } = timers();
  const queue = createNoticeQueue();
  const work = deferred();
  queue.promise(undefined, faces, work.promise);
  render(<NoticeStack queue={queue} dismissLabel="Dismiss" now={() => 0} arm={arm} />);
  expect(live()).toHaveLength(0);
  expect(document.querySelector(".ui-notice-spinner")).not.toBeNull();
  await act(async () => {
    work.resolve();
    await work.promise;
  });
  expect(live().map((timer) => timer.ms)).toEqual([TOAST_MS]);
  act(() => live()[0]!.fire());
  expect(queue.snapshot()).toHaveLength(0);
});

test("a failed promise turns into an error in the same card, read out as an alert", async () => {
  const queue = createNoticeQueue();
  const work = deferred();
  queue.promise("tests", faces, work.promise);
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="list" look="mark" />);
  await act(async () => {
    work.reject(new Error("3 of 128 failed."));
    await work.promise.catch(noop);
  });
  const card = doc.getElementById("tests")!;
  expect(queue.snapshot()).toHaveLength(1);
  expect(card.getAttribute("data-kind")).toBe("error");
  expect(card.getAttribute("data-state")).toBe("error");
  expect(card.getAttribute("role")).toBe("alert");
  expect(card.textContent).toContain("3 of 128 failed.");
});

test("a toast closed while working stays closed; a newer promise under the id wins", async () => {
  const queue = createNoticeQueue();
  const first = deferred();
  queue.promise("tests", faces, first.promise);
  queue.close("tests");
  first.resolve();
  await first.promise;
  expect(queue.snapshot()).toHaveLength(0);

  const older = deferred();
  const newer = deferred();
  queue.promise("run", faces, older.promise);
  queue.promise("run", { ...faces, loading: { message: "Running again…" } }, newer.promise);
  older.resolve();
  await older.promise;
  expect(queue.snapshot().map((entry) => [entry.spec.state, entry.spec.message])).toEqual([
    ["working", "Running again…"],
  ]);
  newer.resolve();
  await newer.promise;
  expect(queue.snapshot().map((entry) => entry.spec.state)).toEqual(["success"]);
});

test("a v2 toast's Undo is the ink-filled button; it runs and closes the toast", () => {
  const queue = createNoticeQueue();
  const ran: string[] = [];
  const closed: string[] = [];
  queue.show({
    message: "Closed “Build logs”",
    actions: [{ id: "undo", label: "Undo", onSelect: () => ran.push("undo") }],
    onClose: (reason) => closed.push(reason),
  });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" look="mark" />);
  const undo = doc.querySelector<HTMLButtonElement>('[data-notice-action="undo"]')!;
  expect(undo.hasAttribute("data-ink")).toBe(true);
  expect(undo.getAttribute("data-size")).toBe("sm");
  act(() => undo.click());
  expect(ran).toEqual(["undo"]);
  expect(closed).toEqual(["action"]);
  expect(queue.snapshot()).toHaveLength(0);
});

test("the default arm draws exactly today's card", () => {
  const props = {
    kind: "toast" as const,
    placement: "stack" as const,
    message: "Archived 3 chats.",
    actions: [{ id: "undo", label: "Undo", onSelect: noop }],
    onDismiss: noop,
    dismissLabel: "Dismiss",
  };
  const today = renderToStaticMarkup(<Notice {...props} />);
  expect(renderToStaticMarkup(<Notice {...props} look="off" />)).toBe(today);
  expect(today).not.toContain("data-look");
  expect(today).not.toContain("data-ink");
  expect(today).not.toContain("data-state");
  // The stack with no arm set reads the default, and draws the same card.
  const queue = createNoticeQueue();
  queue.show({ id: "t", message: "Archived 3 chats.", actions: props.actions });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" />);
  const card = doc.getElementById("t")!;
  expect(card.hasAttribute("data-look")).toBe(false);
  expect(card.querySelector("[data-ink]")).toBeNull();
  expect(card.querySelector('[data-notice-action="undo"]')?.getAttribute("data-variant")).toBe("ghost");
});

test("Settings > Advanced > Experiments > Toasts v2 turns on the recommended arm, and off restores today's look", () => {
  const queue = createNoticeQueue();
  queue.show({
    id: "closed",
    message: "Closed “Build logs”",
    actions: [{ id: "undo", label: "Undo", onSelect: () => {} }],
  });
  const doc = render(<NoticeStack queue={queue} dismissLabel="Dismiss" layout="list" />);
  expect(doc.getElementById("closed")?.getAttribute("data-look")).toBeNull();
  act(() => setExperimentSwitches({ toastsV2: true }));
  expect(doc.getElementById("closed")?.getAttribute("data-look")).toBe("mark");
  act(() => setExperimentSwitches({}));
  expect(doc.getElementById("closed")?.getAttribute("data-look")).toBeNull();
});
