// l10n-allow-file: test fixture recipients, not shipped UI.
// A row's content (VirtualTranscript `RowContent`) is drawn again only when what it draws from
// changes, so a frame moved by a scroll draws none of it again (Leo, 2026-11-06: "Still seeing the
// flicker re-render"). It must still draw a change its row's version does not cover: the activity
// line under a running turn keeps one version while the send in flight changes recipient
// (turns.ts `sendingTo`), and a stale "Sending to ..." is worse than a redraw.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { act, memo, useState } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LIVE_THINKING, THINKING } from "../src/agent-session/acpmux/conversation/turns";
import type { RowProps } from "../src/agent-session/acpmux/rows/rowProps";
import { RowContent } from "../src/agent-session/acpmux/VirtualTranscript";
import { sameRowFrame } from "../src/agent-session/acpmux/virtualTranscriptModel";
import { MessageRow } from "../src/agent-session/acpmux/rows/MessageRow";
import { teardownDom } from "./support/domTeardown";
import { LiveUpdatesContext } from "../src/ui/liveUpdates";
import { AgentNamesContext, AgentOpenContext } from "../src/agent-session/acpmux/conversation/agentNames";
import { AgentTonesContext } from "../src/agent-session/acpmux/subagents/agentTones";
import { MessageCard } from "../src/agent-session/acpmux/conversation/MessageCard";
import { agentMessage } from "../src/agent-session/acpmux/conversation/agentMessages";
import { RowFrame } from "../src/agent-session/acpmux/transcript/RowFrame";
import { pageClocks, usePageNow } from "../src/ui/pageClock";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "IS_REACT_ACT_ENVIRONMENT",
  "requestAnimationFrame",
  "cancelAnimationFrame",
];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const line = (to: string): AcpmuxRow => ({
  id: LIVE_THINKING,
  version: 42,
  at: 1_000,
  kind: THINKING,
  below: true,
  text: "Sending message",
  doingSendTo: to,
});

const drawn: string[] = [];
function Recipient({ row }: RowProps) {
  drawn.push(String(row.doingSendTo));
  return <span>{row.doingSendTo}</span>;
}

test("a live line whose recipient changes under the same version draws the new recipient", async () => {
  const root = createRoot(document.getElementById("root")!);
  const props = { Component: Recipient, onToggleActivity: () => {}, expanded: false };
  await act(async () => root.render(<RowContent {...props} row={line("tests")} />));
  await act(async () => root.render(<RowContent {...props} row={line("reviewer")} />));
  expect(document.body.textContent).toBe("reviewer");
  // The same row object again (a frame moved by a scroll) draws nothing.
  const same = line("reviewer");
  await act(async () => root.render(<RowContent {...props} row={same} />));
  const before = drawn.length;
  await act(async () => root.render(<RowContent {...props} row={same} />));
  expect(drawn.length).toBe(before);
  await act(async () => root.unmount());
});

test("the live line's frame redraws when its recipient changes under the same version", () => {
  expect(sameRowFrame({ row: line("tests") }, { row: line("reviewer") })).toBe(false);
  expect(sameRowFrame({ row: line("tests") }, { row: line("tests") })).toBe(true);
});

test("offscreen row bodies retain state without reconciling status changes and reveal the latest row", async () => {
  const root = createRoot(document.getElementById("root")!);
  const props = { Component: Recipient, onToggleActivity: () => {}, expanded: false };
  const render = (active: boolean, to: string) =>
    root.render(
      <LiveUpdatesContext.Provider value={active}>
        <RowContent {...props} row={line(to)} />
      </LiveUpdatesContext.Provider>,
    );
  try {
    await act(async () => render(true, "visible"));
    await act(async () => render(false, "hidden"));
    const before = drawn.length;
    for (let tick = 0; tick < 20; tick++) await act(async () => render(false, `update-${tick}`));
    expect(drawn.length).toBe(before);
    expect(document.body.textContent).toBe("visible");
    await act(async () => render(true, "latest"));
    expect(document.body.textContent).toBe("latest");
    expect(drawn.length).toBe(before + 1);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the row frame pauses unseen, scrolled-out and shelved clocks and keeps disclosure state on reveal", async () => {
  const root = createRoot(document.getElementById("root")!);
  let now = 1_000;
  const clock = () => now;
  let bodies = 0;
  let intersection: IntersectionObserverCallback;
  const targets = new Set<Element>();
  Object.defineProperty(dom.window, "IntersectionObserver", {
    configurable: true,
    value: class {
      constructor(callback: IntersectionObserverCallback) {
        intersection = callback;
      }
      observe(node: Element) {
        targets.add(node);
      }
      unobserve(node: Element) {
        targets.delete(node);
      }
      disconnect() {
        targets.clear();
      }
    },
  });
  const visible = (shown: boolean) => {
    const target = document.querySelector("article")!;
    const bounds = target.getBoundingClientRect();
    intersection(
      [
        {
          target,
          isIntersecting: shown,
          intersectionRatio: shown ? 1 : 0,
          boundingClientRect: bounds,
          intersectionRect: bounds,
          rootBounds: null,
          time: 0,
        },
      ],
      {} as IntersectionObserver,
    );
  };
  function Clock() {
    return <time>{usePageNow(true, clock)}</time>;
  }
  function Body({ row }: RowProps) {
    bodies++;
    const [open, setOpen] = useState(false);
    return (
      <>
        <button onClick={() => setOpen(!open)}>{open ? "open" : "closed"}</button>
        <span data-recipient>{row.doingSendTo}</span>
        <Clock />
      </>
    );
  }
  const noop = () => {};
  const props = {
    kind: THINKING,
    joinsPrevious: false,
    joinsNext: false,
    opensTurn: false,
    beforeFooter: false,
    beforeIndicator: false,
    replyActions: false,
    status: undefined,
    lastFooter: false,
    finalFooter: false,
    continuationFooter: false,
    lastTurn: false,
    index: 0,
    setSizeRef: { current: "1" },
    top: 0,
    rowWidth: 800,
    expanded: false,
    observer: undefined,
    queueDrawn: () => noop,
    sendThinking: false,
    enter: false,
    onEntered: noop,
    loadFade: false,
    onLoadFaded: noop,
    older: undefined,
    onOlderShown: noop,
    active: false,
    selected: false,
    tabStop: false,
    onFocus: noop,
    onRowKeyDown: noop,
    contentType: Body,
    onToggleActivity: noop,
    gapBelow: 0,
    offscreen: true,
    placedHeight: 60,
  };
  const render = (to: string, shelved = 0) => {
    const row = line(to);
    root.render(
      <RowFrame {...props} row={row} shelved={shelved}>
        <RowContent Component={Body} row={row} expanded={false} onToggleActivity={noop} />
      </RowFrame>,
    );
  };
  try {
    await act(async () => render("unseen"));
    expect(pageClocks().subscribers).toBe(0);
    await act(async () => render("before-reveal"));
    expect(bodies).toBe(1);
    now = 2_000;
    await act(async () => {
      const event = new dom.window.Event("contentvisibilityautostatechange");
      Object.defineProperty(event, "skipped", { value: false });
      document.querySelector("article")!.dispatchEvent(event);
      visible(true);
    });
    expect(pageClocks().subscribers).toBe(1);
    expect(document.querySelector("[data-recipient]")?.textContent).toBe("before-reveal");
    expect(document.querySelector("time")?.textContent).toBe("2000");
    await act(async () => document.querySelector("button")!.click());
    await act(async () => visible(false));
    expect(pageClocks().subscribers).toBe(0);
    const offscreenBodies = bodies;
    for (let tick = 0; tick < 20; tick++) await act(async () => render(`offscreen-${tick}`));
    expect(bodies).toBe(offscreenBodies);
    await act(async () => visible(true));
    expect(document.querySelector("[data-recipient]")?.textContent).toBe("offscreen-19");
    expect(pageClocks().subscribers).toBe(1);
    await act(async () => render("shelved", 60));
    expect(pageClocks().subscribers).toBe(0);
    const before = bodies;
    for (let tick = 0; tick < 20; tick++) await act(async () => render(`hidden-${tick}`, 60));
    expect(bodies).toBe(before);
    now = 30_000;
    await act(async () => render("latest"));
    expect(pageClocks().subscribers).toBe(1);
    expect(document.querySelector("[data-recipient]")?.textContent).toBe("latest");
    expect(document.querySelector("button")?.textContent).toBe("open");
    expect(document.querySelector("time")?.textContent).toBe("30000");
  } finally {
    await act(async () => root.unmount());
  }
  expect(pageClocks().subscribers).toBe(0);
  expect(targets.size).toBe(0);
  delete (dom.window as unknown as Record<string, unknown>).IntersectionObserver;
});

test("a recreated reply passes both memo boundaries even when its row id and version repeat", async () => {
  const root = createRoot(document.getElementById("root")!);
  const props = { Component: MessageRow, onToggleActivity: () => {}, expanded: false };
  // The real frame comparator and content/message renderers: the inner reveal key cannot reset
  // its retained body if either memo boundary mistakes another message for the previous one.
  const Frame = memo(({ row }: { row: AcpmuxRow }) => <RowContent {...props} row={row} />, sameRowFrame);
  const old: AcpmuxRow = {
    id: "assistant-1",
    version: 1,
    at: 1_000,
    kind: "assistant",
    text: "The previous session had a much longer answer that must not survive recreation.",
  };
  const next = { ...old, at: 2_000, text: "The new answer." };
  try {
    await act(async () => root.render(<Frame row={old} />));
    expect(document.querySelector(".cv-md")?.textContent).toBe(old.text);
    await act(async () => root.render(<Frame row={next} />));
    expect(document.querySelector(".cv-md")?.textContent).toBe(next.text);
    expect(document.querySelectorAll(".cv-fresh")).toHaveLength(0);
    // A cloned, unchanged snapshot still reuses its row frame.
    expect(sameRowFrame({ row: next }, { row: { ...next } })).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

test("retained message cards ignore structural agent contexts and reveal the latest name and click target", async () => {
  const root = createRoot(document.getElementById("root")!);
  const opened: string[] = [];
  let messageReads = 0;
  const tool = {
    id: "idle-message",
    title: "SendMessage",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify({ to: "a39e817af38ddf5e7", message: "Result ready" }),
    output: JSON.stringify({ queued: true }),
  } as const;
  const message = agentMessage(tool)!;
  const recipient = message.to;
  Object.defineProperty(message, "to", {
    get: () => {
      messageReads++;
      return recipient;
    },
  });
  function Card() {
    return <MessageCard item={{ kind: "tool", text: tool.title, tool }} message={message} />;
  }
  let plainReads = 0;
  function Plain() {
    plainReads++;
    return <p>Unrelated transcript text</p>;
  }
  const plain = line("plain");
  const row = line("message");
  const noop = () => {};
  const render = (active: boolean, name: string) =>
    root.render(
      <LiveUpdatesContext.Provider value={active}>
        <AgentNamesContext.Provider value={new Map([["a39e817af38ddf5e7", name]])}>
          <AgentOpenContext.Provider
            value={{ views: new Map([["a39e817af38ddf5e7", name]]), open: (id) => opened.push(id) }}
          >
            <AgentTonesContext.Provider value={new Map([["a39e817af38ddf5e7", name.length]])}>
              <RowContent Component={Card} row={row} expanded={false} onToggleActivity={noop} />
              <RowContent Component={Plain} row={plain} expanded={false} onToggleActivity={noop} />
            </AgentTonesContext.Provider>
          </AgentOpenContext.Provider>
        </AgentNamesContext.Provider>
      </LiveUpdatesContext.Provider>,
    );
  try {
    await act(async () => render(true, "First"));
    const plainBefore = plainReads;
    for (let tick = 0; tick < 20; tick++) await act(async () => render(true, `Visible ${tick}`));
    expect(plainReads).toBe(plainBefore);
    expect(document.querySelector(".cv-agentmsg__name")?.textContent).toBe("Visible 19");
    await act(async () => render(true, "Original"));
    await act(async () => render(false, "Hidden"));
    const before = messageReads;
    expect(before).toBeGreaterThan(0);
    for (let tick = 0; tick < 20; tick++) await act(async () => render(false, `Update ${tick}`));
    expect(messageReads).toBe(before);
    expect(document.querySelector(".cv-agentmsg__name")?.textContent).toBe("Original");
    await act(async () => render(true, "Current"));
    expect(document.querySelector(".cv-agentmsg__name")?.textContent).toBe("Current");
    await act(async () => document.querySelector<HTMLButtonElement>("button.cv-agentmsg__name")!.click());
    expect(opened).toEqual(["Current"]);
  } finally {
    await act(async () => root.unmount());
  }
});
