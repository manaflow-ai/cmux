// l10n-allow-file: test fixture machine names, not shipped UI.
//
// The composer status dot (ComposerStatusDot.tsx) in a DOM: it shows an item only once it is due, on
// one timer; a peek that is pinned keeps its one card element; Escape, a press outside and a click on
// the dot close a pin, and after the click a hover does not peek again until the pointer has left the
// dot; the dot's aria; an unknown words key draws nothing; and a remote chat from an older acpmux
// keeps the machine row. The glass card is a stand-in here (its seam, composerStatusCard.tsx): Base
// UI's positioner needs layout jsdom has not.
import { afterAll, afterEach, beforeAll, expect, jest, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode, type Ref } from "react";
import type { Root } from "react-dom/client";
import type { StatusItem } from "./composerStatusModel";
import { teardownDom } from "../../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

const seam = await import("./composerStatusCard");
// mock.module replaces a module for the rest of the bun process: the real one goes back after this file.
const realSeam = { ...seam };
void mock.module("./composerStatusCard", () => ({
  ...realSeam,
  StatusCard: ({
    id,
    open,
    pinned,
    label,
    popupRef,
    children,
  }: {
    id: string;
    open: boolean;
    pinned: boolean;
    label: string;
    popupRef: Ref<HTMLDivElement>;
    children: ReactNode;
  }) =>
    open ? (
      <div id={id} ref={popupRef} aria-label={label} data-state={pinned ? "pinned" : "peek"} data-card>
        {children}
      </div>
    ) : null,
}));

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div><button id=outside></button>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    Event: window.Event,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  jest.useRealTimers();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  void mock.module("./composerStatusCard", () => realSeam);
  // computerUseState.ts, reached through the dot's imports, installs this hook at load.
  delete scope.cmuxAcpmuxComputerUseState;
  await teardownDom(saved, { window: dom.window, scope });
});

async function render(node: ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}

async function dot(props: Partial<import("./ComposerStatusDot").ComposerStatusDotProps> = {}) {
  const { ComposerStatusDot } = await import("./ComposerStatusDot");
  await render(<ComposerStatusDot items={[]} arm="off" {...props} />);
}

const button = () => host.querySelector<HTMLButtonElement>(".acpmux-composer-status-dot")!;
const card = () => document.querySelector<HTMLElement>("[data-card]");
const fire = (target: Element, type: string, init: MouseEventInit = {}) =>
  act(async () => void target.dispatchEvent(new window.MouseEvent(type, { bubbles: true, ...init })));
const click = (target: Element) => fire(target, "click", { detail: 1 });
const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

const offline: StatusItem = {
  kind: "machineLink",
  level: "attention",
  words: "status.machineLink.offline",
  subject: "walk-remote",
  since: 1,
};
const stuck: StatusItem = { kind: "stuck", level: "problem", words: "status.stuck.spawnFailed", subject: "Codex" };

test("an item shows only once it is due, on one timer that stops when nothing waits", async () => {
  jest.useFakeTimers();
  const realSet = globalThis.setTimeout;
  const delays: number[] = [];
  globalThis.setTimeout = ((run: () => void, ms?: number) => {
    if ((ms ?? 0) > 0) delays.push(ms!);
    return realSet(run, ms);
  }) as typeof setTimeout;
  try {
    const start = Date.now();
    await dot({
      items: [
        { ...offline, showAt: start + 5_000 },
        { ...stuck, showAt: start + 9_000 },
      ],
    });
    expect(button().hasAttribute("data-shown")).toBe(false);
    await wait(5_000);
    expect(button().hasAttribute("data-shown")).toBe(true);
    expect(button().dataset.tone).toBe("attention");
    await wait(4_000);
    expect(button().dataset.tone).toBe("problem");
    const armed = delays.length;
    await wait(60_000);
    expect(delays.length).toBe(armed);
  } finally {
    globalThis.setTimeout = realSet;
  }
});

test("the dot is a button that names its worst item and controls its dialog", async () => {
  await dot({ items: [offline, stuck] });
  const element = button();
  expect(element.tagName).toBe("BUTTON");
  expect(element.getAttribute("aria-haspopup")).toBe("dialog");
  expect(element.getAttribute("aria-expanded")).toBe("false");
  expect(element.getAttribute("aria-label")).toBe("Codex didn't start");
  await click(element);
  expect(element.getAttribute("aria-expanded")).toBe("true");
  expect(element.getAttribute("aria-controls")).toBe(card()!.id);
});

test("with nothing to say, a remote chat names the dot Session details and a local one hides it", async () => {
  await dot({ connectedTo: "walk-remote" });
  expect(button().getAttribute("aria-label")).toBe("Session details");
  expect(button().dataset.tone).toBe("connected");
  await dot({});
  expect(button().hasAttribute("data-shown")).toBe(false);
  expect(button().tabIndex).toBe(-1);
});

test("pinning a peek keeps its one card element, and only the key hint appears", async () => {
  await dot({ items: [offline], initial: "peek" });
  const peeked = card();
  expect(peeked?.dataset.state).toBe("peek");
  expect(peeked!.querySelector(".acpmux-status-hint")?.hasAttribute("data-shown")).toBe(false);
  await click(button());
  expect(card()).toBe(peeked);
  expect(card()?.dataset.state).toBe("pinned");
  expect(peeked!.querySelector(".acpmux-status-hint")?.hasAttribute("data-shown")).toBe(true);
});

test("Escape and a press outside close a pin", async () => {
  await dot({ items: [offline], initial: "pinned" });
  expect(card()).not.toBeNull();
  await act(
    async () => void document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
  );
  expect(card()).toBeNull();
  await click(button());
  expect(card()?.dataset.state).toBe("pinned");
  await fire(document.getElementById("outside")!, "pointerdown");
  expect(card()).toBeNull();
});

test("after a click closes the pin, a hover peeks again only once the pointer has left the dot", async () => {
  jest.useFakeTimers();
  await dot({ items: [offline], initial: "pinned" });
  await click(button());
  expect(card()).toBeNull();
  await fire(button(), "pointerover", { relatedTarget: document.body });
  await wait(2_000);
  expect(card()).toBeNull();
  await fire(button(), "pointerout", { relatedTarget: document.body });
  await fire(button(), "pointerover", { relatedTarget: document.body });
  await wait(2_000);
  expect(card()?.dataset.state).toBe("peek");
});

test("an unknown words key draws nothing, never the key", async () => {
  await dot({ items: [{ ...stuck, words: "status.stuck.someday" }], connectedTo: "walk-remote", initial: "pinned" });
  expect(button().dataset.tone).toBe("connected");
  expect(card()?.textContent).not.toContain("status.");
});

test("a remote chat from an older acpmux keeps the machine row; a newer one gets the dot", async () => {
  const { ComposerStatusFoot } = await import("./ComposerStatusDot");
  const link = { machine: "walk-remote", link: "offline" as const };
  await render(<ComposerStatusFoot snapshot={{ summary: { peer: "walk-remote" } }} link={link} heldForHost={false} />);
  expect(host.querySelector(".acpmux-machine-link")).not.toBeNull();
  expect(host.querySelector(".acpmux-composer-status-dot")).toBeNull();
  await render(
    <ComposerStatusFoot
      snapshot={{ summary: { peer: "walk-remote", composerStatus: { items: [offline], facts: [] } } }}
      link={link}
      heldForHost={false}
    />,
  );
  expect(host.querySelector(".acpmux-machine-link")).toBeNull();
  expect(button().getAttribute("aria-label")).toBe("walk-remote is offline");
});

test("a held send is the dot's to say", async () => {
  const { ComposerStatusFoot } = await import("./ComposerStatusDot");
  await render(<ComposerStatusFoot snapshot={{ summary: {} }} link={null} heldForHost />);
  expect(button().getAttribute("aria-label")).toBe("Sending when ready");
});

test("the strip arm draws the static facts as a line and the live ones as counters; off draws neither", async () => {
  const facts = [
    { kind: "machine" as const, text: "walk-remote", live: false },
    { kind: "folder" as const, text: "/Users/leo/Projects/cmux", live: false },
    { kind: "subagents" as const, count: 2, live: true },
  ];
  await dot({ facts, arm: "strip", now: 1 });
  const strip = host.querySelector(".acpmux-composer-status-strip");
  expect(strip?.textContent).toBe("walk-remote · Projects/cmux");
  expect(host.querySelector(".acpmux-composer-status-count[data-shown]")).not.toBeNull();
  await dot({ facts, arm: "off", now: 1 });
  expect(host.querySelector(".acpmux-composer-status-strip")).toBeNull();
  expect(host.querySelector(".acpmux-composer-status-count")).toBeNull();
});

test("the machine name at rest draws only behind its switch, only for the fact acpmux marks, and a click pins", async () => {
  const facts = [
    { kind: "machine" as const, text: "walk-remote", live: false, atRest: true },
    { kind: "folder" as const, text: "/Users/leo/Projects/cmux", live: false },
  ];
  const name = () => host.querySelector<HTMLButtonElement>(".acpmux-composer-status-machine");
  await dot({ facts, machineAtRest: "off", connectedTo: "walk-remote", now: 1 });
  expect(name()).toBeNull();
  await dot({ facts, machineAtRest: "on", connectedTo: "walk-remote", now: 1 });
  expect(name()?.textContent).toBe("walk-remote");
  expect(button().hasAttribute("data-shown")).toBe(true);
  await click(name()!);
  expect(card()?.getAttribute("data-state")).toBe("pinned");
  // A machine fact acpmux did not mark draws nothing, and the strip arm writes the name in its line.
  await dot({ facts: [{ kind: "machine", text: "walk-remote", live: false }], machineAtRest: "on", now: 2 });
  expect(name()).toBeNull();
  await dot({ facts, machineAtRest: "on", arm: "strip", now: 3 });
  expect(name()).toBeNull();
});

// RFD 0128 (rows into the dot): a queue a failed turn paused is the dot's to say, with the turn's
// error and Resume; the queue's own note stays out once the dot says it, and stays for an acpmux
// that sends no such item.
test("a paused queue is the dot's to say, naming the error, and the queue note defers to it", async () => {
  const { ComposerStatusFoot, dotSaysQueuePaused } = await import("./ComposerStatusDot");
  const paused: StatusItem = {
    kind: "queuePaused",
    level: "attention",
    words: "status.queuePaused.paused",
    action: "resumeQueue",
  } as StatusItem;
  const snapshot = { summary: { queuePaused: true, composerStatus: { items: [paused], facts: [] } } };
  expect(dotSaysQueuePaused(snapshot)).toBe(true);
  expect(dotSaysQueuePaused({ summary: { queuePaused: true } })).toBe(false);
  expect(
    dotSaysQueuePaused({
      summary: { composerStatus: { items: [{ ...paused, words: "status.queuePaused.someday" }], facts: [] } },
    }),
  ).toBe(false);
  await render(
    <ComposerStatusFoot snapshot={snapshot} link={null} heldForHost={false} pauseReason="429 rate limited" />,
  );
  expect(button().getAttribute("aria-label")).toBe("Paused after an error: 429 rate limited");
  await render(<ComposerStatusFoot snapshot={snapshot} link={null} heldForHost={false} />);
  expect(button().getAttribute("aria-label")).toBe("Queue paused");
});
