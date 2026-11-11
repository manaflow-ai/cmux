// The pane's stuck and contradictory states, each reproduced by the event order that left it on
// screen and shown cleared (Leo, 2026-11-11: "This is bullshit state. We cannot have bullshit
// state."):
// - a mark a click sets and an owner must clear (an answered ask, a Retry's "Retrying…") lets go
//   past its deadline when the owner never clears it (answerHold.ts);
// - a notice about the live turn (the stuck banner, the automatic retry's line) reads one turn
//   phase, so it never shows beside "Reconnecting…" or under a turn that ended (turnPhase.ts);
// - Restart acpmux never holds the pane on "Restarting…" when the app never answers (hostRetry.ts).
import { afterEach, expect, jest, test } from "bun:test";
import { act, useEffect, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ANSWER_HOLD_MS, RETRY_HOLD_MS, useAnswerHold, useAnswerHoldSet } from "./answerHold";
import { AcpmuxRestartGate, RESTART_DEADLINE_MS } from "./hostRetry";
import { liveAutoResume, stuckNotice, turnPhase } from "./turnPhase";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  jest.useRealTimers();
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

async function mount(container: HTMLElement, node: React.ReactNode) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(node);
  });
}

// --- Answered asks and Retry: a mark its owner never clears ----------------------------------------

type Hold = { set(value: string | undefined): void; released: string[] };
const hold: { current?: Hold } = {};
const keepHold = (next: Hold) => void (hold.current = next);
function HoldProbe({ ms, onHold }: { ms: number; onHold(hold: Hold): void }) {
  const [released] = useState<string[]>(() => []);
  const [value, set] = useAnswerHold<string>(ms, (gone) => released.push(gone));
  useEffect(() => onHold({ set, released }), [onHold, set, released]);
  return <span>{value ?? "none"}</span>;
}

test("an answered ask whose owner never takes it away takes an answer again", async () => {
  // Order: the person answers (the card dims), the agent exits before the ask is cleared.
  jest.useFakeTimers();
  hold.current = undefined;
  const container = installDom();
  await mount(container, <HoldProbe ms={ANSWER_HOLD_MS} onHold={keepHold} />);
  await act(async () => hold.current!.set("ask-1"));
  expect(container.textContent).toBe("ask-1");
  await wait(ANSWER_HOLD_MS - 1);
  expect(container.textContent).toBe("ask-1");
  await wait(1);
  expect(container.textContent).toBe("none");
  // The card's same-frame guard (a ref) lets go with it.
  expect(hold.current!.released).toEqual(["ask-1"]);
});

test("a refusal lets go at once, and a newer answer starts its own deadline", async () => {
  jest.useFakeTimers();
  hold.current = undefined;
  const container = installDom();
  await mount(container, <HoldProbe ms={1_000} onHold={keepHold} />);
  await act(async () => hold.current!.set("ask-1"));
  await act(async () => hold.current!.set(undefined));
  expect(container.textContent).toBe("none");
  await act(async () => hold.current!.set("ask-1"));
  await wait(600);
  await act(async () => hold.current!.set("ask-2"));
  await wait(600);
  expect(container.textContent).toBe("ask-2");
  await wait(400);
  expect(container.textContent).toBe("none");
  expect(hold.current!.released).toEqual(["ask-2"]);
});

test("a Retry acpmux took whose attempt never shows stops saying Retrying…", async () => {
  // Order: Retry clicked, acpmux accepts, the link drops before the attempt's rows arrive.
  jest.useFakeTimers();
  hold.current = undefined;
  const container = installDom();
  await mount(container, <HoldProbe ms={RETRY_HOLD_MS} onHold={keepHold} />);
  await act(async () => hold.current!.set("went"));
  await wait(RETRY_HOLD_MS - 1);
  expect(container.textContent).toBe("went");
  await wait(1);
  expect(container.textContent).toBe("none");
});

type HoldSet = ReturnType<typeof useAnswerHoldSet>;
const holdSet: { current?: HoldSet } = {};
const keepHoldSet = (next: HoldSet) => void (holdSet.current = next);
function SetProbe({ items, onHold }: { items: string[]; onHold(ids: HoldSet): void }) {
  const ids = useAnswerHoldSet(1_000);
  useEffect(() => onHold(ids), [onHold, ids]);
  const shown = items.filter((id) => !ids.held.has(id));
  return <span>{`${shown.length}:${shown.join(",")}`}</span>;
}

test("a Needs you row answered but never taken off the list comes back, so its count matches the pill", async () => {
  // Order: an ask answered from the panel, acpmux never removes it (the chat ended).
  jest.useFakeTimers();
  const container = installDom();
  const items = ["a", "b"];
  await mount(container, <SetProbe items={items} onHold={keepHoldSet} />);
  await act(async () => holdSet.current!.add("a"));
  expect(container.textContent).toBe("1:b");
  await wait(500);
  await act(async () => holdSet.current!.add("b"));
  expect(container.textContent).toBe("0:");
  // `a`'s deadline is its own: `b`'s answer does not push it back.
  await wait(500);
  expect(container.textContent).toBe("1:a");
  await wait(500);
  expect(container.textContent).toBe("2:a,b");
  // A refusal shows its row again at once.
  await act(async () => holdSet.current!.add("a"));
  await act(async () => holdSet.current!.remove("a"));
  expect(container.textContent).toBe("2:a,b");
});

// --- Live-turn notices read one phase ----------------------------------------------------------------

const looping = { loopEpisode: { diagnosis: "The agent repeats the same tool call." } };

test("the stuck banner never shows beside Reconnecting…, nor after the turn ended", () => {
  // Order: a loop is detected, then the pane's link drops: the summary is frozen with the episode.
  expect(stuckNotice(turnPhase({ connection: "disconnected", isWorking: true }), looping, "silent")).toBeUndefined();
  expect(stuckNotice(turnPhase({ connection: "connecting…", isWorking: true }), looping, "silent")).toBeUndefined();
  // The turn ended (or a Stop is ending it): nothing is stuck.
  expect(stuckNotice(turnPhase({ connection: "turn_end", isWorking: false }), looping, "silent")).toBeUndefined();
  expect(
    stuckNotice(turnPhase({ connection: "stopping", isWorking: true, stopping: true }), looping, "silent"),
  ).toBeUndefined();
  // A turn that runs and that the pane hears says it.
  expect(stuckNotice(turnPhase({ connection: "agent_message_chunk", isWorking: true }), looping, "silent")).toBe(
    looping.loopEpisode.diagnosis,
  );
  expect(stuckNotice("working", { stalledSince: 5 }, "silent")).toBe("silent");
});

test("an automatic retry's line says nothing frozen and nothing about a turn that ended", () => {
  const retry = { retry: { attempt: 2, of: 3, nextAt: 10 } };
  const resumed = { attempt: 2 };
  // Its wait for the next attempt: only while the pane hears the daemon that waits.
  expect(liveAutoResume("offline", retry)).toBeUndefined();
  expect(liveAutoResume("idle", retry)).toBe(retry);
  // "Automatically resumed (attempt 2)": while that attempt runs, never after it ended.
  expect(liveAutoResume("working", resumed)).toBe(resumed);
  expect(liveAutoResume("idle", resumed)).toBeUndefined();
  expect(liveAutoResume("offline", resumed)).toBeUndefined();
  expect(liveAutoResume("working", undefined)).toBeUndefined();
});

test("the phase is offline while the link is down, whatever the frozen snapshot says", () => {
  expect(turnPhase({ connection: "disconnected", isWorking: true, stopping: true })).toBe("offline");
  expect(turnPhase({ connection: "connected", isWorking: false })).toBe("idle");
  expect(turnPhase({ connection: "connected", isWorking: true })).toBe("working");
  expect(turnPhase({ connection: "connected", isWorking: true, stopping: true })).toBe("stopping");
});

// --- Restart acpmux the app never answers -------------------------------------------------------------

test("Restart acpmux the app never answers lets the pane ask again past its deadline", async () => {
  jest.useFakeTimers();
  const gate = new AcpmuxRestartGate();
  const log: string[] = [];
  const restart = gate.run(() => new Promise<void>(() => undefined), {
    cancelRetries: () => log.push("cancel"),
    changed: (running) => log.push(running ? "restarting" : "restarted"),
    connected: () => false,
    ask: () => log.push("handshake"),
  });
  expect(gate.mayAsk()).toBe(false);
  jest.advanceTimersByTime(RESTART_DEADLINE_MS - 1);
  await Promise.resolve();
  expect(gate.mayAsk()).toBe(false);
  jest.advanceTimersByTime(1);
  await restart;
  expect(gate.mayAsk()).toBe(true);
  expect(log).toEqual(["cancel", "restarting", "restarted", "handshake"]);
});
