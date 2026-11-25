// The chat's place controls and move card (place/): they draw what `pane.tabState`'s `place` says and
// call the app; every decision (when a move starts, what it carries, whether Cancel is offered) is the
// app's. Leo, 2026-11-23: "buttons for cloud/auto/evacuate aka move/teleport is necessary."
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../../ui/UiProvider";
import { settleReact } from "../../../../test/support/domTeardown";
import { translate } from "../i18n";
import { resetHeaderStateForTests, setHeaderState, headerState } from "../header/headerState";
import { EvacuateControl } from "./EvacuateControl";
import { MoveProgress } from "./MoveProgress";
import { PlaceControl } from "./PlaceControl";
import { EVACUATES, MOVES, PLACES, at, evacuateAt } from "./fixtures";
import {
  elapsedNow,
  bringBackCount,
  evacuateCounts,
  evacuateElapsed,
  evacuateOf,
  failedSessions,
  landedOnFailure,
  moveActions,
  orderedCarries,
  placeOf,
  runsAtName,
  seconds,
  stepKey,
  triggerKey,
} from "./placeModel";
import { evacuateActions, placeActions } from "./usePlace";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
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

beforeEach(() => resetHeaderStateForTests());
afterEach(async () => {
  resetHeaderStateForTests();
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  delete (scope as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

const noop = () => undefined;
async function draw(node: React.ReactNode): Promise<HTMLElement> {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<UiProvider container={container}>{node}</UiProvider>));
  return container;
}
const text = (container: HTMLElement) => container.textContent ?? "";

test("place is read from the app's wire shape, and a value that is not one is none", () => {
  expect(placeOf(undefined)).toBeUndefined();
  expect(placeOf({ mode: "sideways" })).toBeUndefined();
  expect(placeOf({ mode: "auto", at: "cloud", cloudName: "swift-otter" })).toEqual({
    mode: "auto",
    at: "cloud",
    cloudName: "swift-otter",
  });
  const wire = {
    mode: "cloud",
    at: "local",
    move: {
      session: "s",
      direction: "toCloud",
      trigger: { auto: "lowBattery" },
      from: "This Mac",
      to: "otter",
      state: "moving",
      step: "carry",
      stepIndex: 4,
      stepCount: 8,
      startedMs: 100,
      elapsedMs: 50,
      budgetMs: 10000,
      overBudget: false,
      canCancel: false,
      finishing: true,
      runsAt: "local",
      carries: [{ kind: "turn", how: "interrupted" }, { kind: "changes", how: "carried", count: 3 }, { kind: "?" }],
      interruptsTurn: true,
      canRetry: false,
      steps: [],
    },
  };
  const move = placeOf(wire)?.move;
  expect(move?.trigger).toEqual({ auto: "lowBattery" });
  expect(move?.carries.map((carry) => carry.kind)).toEqual(["turn", "changes"]);
  expect(move?.finishing).toBe(true);
  expect(placeOf({ ...wire, move: { ...wire.move, step: "nope" } })?.move).toBeUndefined();
  expect(evacuateOf({ running: 1, done: 2, failed: 0, total: 3 })).toMatchObject({
    running: 1,
    done: 2,
    failed: 0,
    total: 3,
  });
});

test("place carries Rust's blocked reason and slot holders, and drops ones it does not know", () => {
  expect(placeOf({ mode: "auto", at: "local", blocked: { why: "signed-out" } })?.blocked).toEqual({
    why: "signed-out",
  });
  expect(placeOf({ mode: "auto", at: "local", blocked: { why: "sideways" } })?.blocked).toBeUndefined();
  expect(
    placeOf({ mode: "auto", at: "local", holders: [{ session: "h", title: "Held" }, { title: "no session" }, null] })
      ?.holders,
  ).toEqual([{ session: "h", title: "Held" }]);
  expect(placeOf({ mode: "auto", at: "local", holders: [] })?.holders).toBeUndefined();
});

test("the header state keeps the place until a push names it again", () => {
  setHeaderState({ place: { mode: "auto", at: "local" } });
  expect(headerState().place?.mode).toBe("auto");
  setHeaderState({ pinned: true });
  expect(headerState().place?.mode).toBe("auto");
  setHeaderState({ place: null });
  expect(headerState().place).toBeUndefined();
});

test("the clock ticks from the start while moving and stops at the app's time when it ended", () => {
  expect(elapsedNow(MOVES.moving, MOVES.moving.startedMs + 6000)).toBe(6000);
  expect(elapsedNow(MOVES.moving, MOVES.moving.startedMs)).toBe(4200);
  expect(elapsedNow(MOVES.failed, MOVES.failed.startedMs + 99_000)).toBe(6800);
  expect(seconds(4200)).toBe("4.2");
  expect(seconds(13_400)).toBe("13");
});

test("actions follow the app's flags, never the state alone", () => {
  expect(moveActions(MOVES.moving)).toEqual({ cancel: true, retry: false, finishing: false });
  expect(moveActions(MOVES.finishing)).toEqual({ cancel: false, retry: false, finishing: true });
  expect(moveActions(MOVES.failed)).toEqual({ cancel: false, retry: true, finishing: false });
  expect(moveActions({ ...MOVES.failed, canRetry: false }).retry).toBe(false);
  expect(moveActions(MOVES.live)).toEqual({ cancel: false, retry: false, finishing: false });
});

test("a turn that will be interrupted is listed first, and where it still runs is the old place", () => {
  expect(orderedCarries({ ...MOVES.interrupts, carries: [...MOVES.interrupts.carries].reverse() })[0]?.kind).toBe(
    "turn",
  );
  expect(runsAtName(MOVES.failed)).toBe("This Mac");
  expect(runsAtName({ ...MOVES.failed, direction: "toLocal", from: "swift-otter", to: "This Mac" })).toBe("This Mac");
  expect(runsAtName({ ...MOVES.failed, runsAt: "cloud" })).toBe("swift-otter");
  expect(landedOnFailure(MOVES.failed)).toBe(false);
  expect(landedOnFailure({ ...MOVES.failed, runsAt: "cloud" })).toBe(true);
  expect(stepKey("machine", "toLocal")).toBe("place.step.machineLocal");
  expect(triggerKey({ auto: "away" })).toBe("place.trigger.away");
  expect(triggerKey("person")).toBeUndefined();
});

test("a running move names its step, i of 8, the clock against 10 s, and what moves with it", async () => {
  const container = await draw(
    <MoveProgress move={MOVES.moving} now={at(MOVES.moving)} onCancel={noop} onRetry={noop} />,
  );
  const words = text(container);
  expect(words).toContain("Copying your folder");
  expect(words).toContain("Step 3 of 8");
  expect(words).toContain("4.2 s of 10 s");
  expect(words).toContain("Uncommitted changes: 3");
  expect(words).toContain("Running turn continues on swift-otter");
  expect(words).toContain("Cancel");
  expect(words).not.toContain("interrupted");
  const bar = container.querySelector('[role="progressbar"]')!;
  expect(bar.getAttribute("aria-valuenow")).toBe("3");
  expect(bar.getAttribute("aria-valuetext")).toBe("Step 3 of 8: Copying your folder");
});

test("an interrupted turn is said in the first step, before the freeze", async () => {
  const container = await draw(
    <MoveProgress move={MOVES.interrupts} now={at(MOVES.interrupts)} onCancel={noop} onRetry={noop} />,
  );
  expect(text(container)).toContain("Running turn will be interrupted");
  expect(container.querySelector('[data-warn="true"]')).not.toBeNull();
  expect(text(container)).toContain("Checking the move");
});

test("over budget says it is taking longer and what it waits on; finishing drops Cancel", async () => {
  const over = await draw(
    <MoveProgress move={MOVES.overBudget} now={at(MOVES.overBudget)} onCancel={noop} onRetry={noop} />,
  );
  expect(text(over)).toContain("Taking longer than 10 s. Waiting on: Starting its Cloud VM");
  await act(async () => root!.unmount());
  root = undefined;
  const finishing = await draw(
    <MoveProgress move={MOVES.finishing} now={at(MOVES.finishing)} onCancel={noop} onRetry={noop} />,
  );
  expect(text(finishing)).toContain("Finishing…");
  expect(text(finishing)).not.toContain("Cancel");
});

test("a failure says why, where the chat still runs, and offers Retry; Cancel and Retry call the app", async () => {
  const calls: string[] = [];
  const container = await draw(
    <MoveProgress
      move={MOVES.failed}
      now={at(MOVES.failed)}
      onCancel={() => calls.push("cancel")}
      onRetry={() => calls.push("retry")}
    />,
  );
  const words = text(container);
  expect(words).toContain("Could not move this chat");
  expect(words).toContain("ran out of disk space");
  expect(words).toContain("Still running on This Mac");
  await act(async () => container.querySelector<HTMLElement>('[data-testid="move-retry"]')!.click());
  expect(calls).toEqual(["retry"]);
  await act(async () => root!.unmount());
  root = undefined;
  const running = await draw(
    <MoveProgress move={MOVES.moving} now={at(MOVES.moving)} onCancel={() => calls.push("cancel")} onRetry={noop} />,
  );
  await act(async () => running.querySelector<HTMLElement>('[data-testid="move-cancel"]')!.click());
  expect(calls).toEqual(["retry", "cancel"]);
});

test("a finished move shows and then goes", async () => {
  jest.useFakeTimers();
  const container = await draw(
    <MoveProgress move={MOVES.live} look="line" linger={20} onCancel={noop} onRetry={noop} />,
  );
  expect(text(container)).toContain("Now running on swift-otter");
  await act(async () => void jest.advanceTimersByTime(19));
  expect(container.querySelector(".acpmux-move")).not.toBeNull();
  await act(async () => void jest.advanceTimersByTime(1));
  expect(container.querySelector(".acpmux-move")).toBeNull();
  jest.useRealTimers();
});

test("every look draws the move and its state", async () => {
  for (const look of ["card", "line", "steps"] as const) {
    const container = await draw(
      <MoveProgress move={MOVES.moving} look={look} now={at(MOVES.moving)} onCancel={noop} onRetry={noop} />,
    );
    expect(container.querySelector(`[data-look="${look}"]`)).not.toBeNull();
    expect(text(container)).toContain("4.2 s of 10 s");
    await act(async () => root!.unmount());
    root = undefined;
  }
});

test("the control offers Local, Cloud and Auto, marks the choice, and a pick calls onMode", async () => {
  const picks: string[] = [];
  const container = await draw(
    <PlaceControl place={PLACES.autoLocal} look="segmented" onMode={(mode) => picks.push(mode)} />,
  );
  const radios = [...container.querySelectorAll<HTMLElement>('[role="radio"]')];
  expect(radios.map((radio) => radio.textContent)).toEqual(["Local", "Cloud", "Auto"]);
  expect(radios.map((radio) => radio.getAttribute("aria-checked"))).toEqual(["false", "false", "true"]);
  expect(text(container)).toContain(translate("placeAuto.rule"));
  await act(async () => container.querySelector<HTMLElement>('[data-testid="place-cloud"]')!.click());
  expect(picks).toEqual(["cloud"]);
});

test("the rule of Auto is one line and says what moves it", () => {
  const rule = translate("placeAuto.rule");
  expect(rule).not.toContain("\n");
  for (const word of ["sleeps", "power", "memory", "disk", "10 min", "15 min", "idle"]) expect(rule).toContain(word);
});

test("the chip's face says the choice, where Auto runs, and a move's destination", async () => {
  const faces = new Map<(typeof PLACES)[keyof typeof PLACES], string>([
    [PLACES.local, "Local"],
    [PLACES.cloud, "Cloud"],
    [PLACES.autoLocal, "Auto · This Mac"],
    [PLACES.autoCloud, "Auto · Cloud"],
    [PLACES.moving, "Moving to swift-otter"],
  ]);
  for (const [place, face] of faces) {
    const container = await draw(<PlaceControl place={place} look="menu" onMode={noop} />);
    expect(container.querySelector('button[data-menu="Place"]')?.textContent).toBe(face);
    await act(async () => root!.unmount());
    root = undefined;
  }
});

test("the calls are the app's actions, bound to the session", async () => {
  const calls: unknown[] = [];
  installDom();
  (dom!.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions = {
    "action.run": (params: unknown) => {
      calls.push(params);
      return Promise.resolve();
    },
  };
  const place = placeActions("s-1");
  place.setMode("cloud");
  place.cancel();
  place.retry();
  const list = evacuateActions();
  list.evacuate();
  list.evacuate(["a", "b"]);
  list.cancelEvacuate();
  list.bringBack();
  list.bringBack(["a"]);
  list.setMode("c", "auto");
  expect(calls).toEqual([
    { id: "chatPlace.set", mode: "cloud", session: "s-1" },
    { id: "chatMove.cancel", session: "s-1" },
    { id: "chatMove.retry", session: "s-1" },
    { id: "cloudEvacuate" },
    { id: "cloudEvacuate", sessions: ["a", "b"] },
    { id: "cloudEvacuate.cancel" },
    { id: "cloudBringBackAll" },
    { id: "cloudBringBackAll", sessions: ["a"] },
    { id: "chatPlace.set", mode: "auto", sessions: ["c"] },
  ]);
});

test("a failed or cancelled move lists no carries; a running one does", async () => {
  for (const move of [MOVES.failed, { ...MOVES.failed, state: "cancelled" as const }]) {
    const container = await draw(<MoveProgress move={move} now={at(move)} onCancel={noop} onRetry={noop} />);
    expect(text(container)).toContain("Still running on This Mac");
    expect(text(container)).not.toContain("Running turn continues");
    expect(container.querySelector(".acpmux-move-carries")).toBeNull();
    await act(async () => root!.unmount());
    root = undefined;
  }
  const steps = await draw(
    <MoveProgress move={MOVES.failed} look="steps" now={at(MOVES.failed)} onCancel={noop} onRetry={noop} />,
  );
  expect(steps.querySelector(".acpmux-move-carries")).toBeNull();
});

test("the menu's Auto rule wraps and the rows' Cloud row says what it does", async () => {
  const rows = await draw(<PlaceControl place={PLACES.local} look="rows" onMode={noop} />);
  const cloud = rows.querySelector('[data-testid="place-cloud"]')!;
  expect(cloud.textContent).toBe("CloudIts own Cloud VM");
  await act(async () => root!.unmount());
  root = undefined;
  const named = await draw(<PlaceControl place={PLACES.cloud} look="rows" onMode={noop} />);
  expect(named.querySelector('[data-testid="place-cloud"]')!.textContent).toBe("Cloudswift-otter");
});

test("evacuate is read leniently: per-chat entries, the clock, and counts from the chats", () => {
  const state = evacuateOf({
    running: 9,
    done: 9,
    failed: 9,
    total: 9,
    startedMs: 5,
    elapsedMs: 7,
    chats: [
      { session: "a", title: "A", state: "moving", step: "sync" },
      { session: "b", title: "B", state: "queued" },
      { session: "c", title: "C", state: "failed", reason: "No VM" },
      { session: "d", title: "D", state: "live", step: "nope" },
      { session: "e", state: "weird" },
      null,
    ],
  });
  expect(state?.chats?.map((chat) => chat.state)).toEqual(["moving", "queued", "failed", "live"]);
  expect(state?.chats?.[3]?.step).toBeUndefined();
  expect(state?.chats?.[2]?.reason).toBe("No VM");
  expect(state && evacuateCounts(state)).toEqual({ running: 2, done: 1, failed: 1, total: 4 });
  expect(state && failedSessions(state)).toEqual(["c"]);
  expect(evacuateOf({ running: 1, done: 0, failed: 0, total: 2, chats: "x" })?.chats).toBeUndefined();
  expect(evacuateElapsed(EVACUATES.running, EVACUATES.running.startedMs + 20_000)).toBe(20_000);
  expect(evacuateElapsed(EVACUATES.finished, EVACUATES.finished.startedMs + 99_000)).toBe(31_400);
});

test("idle, Evacuate is a visible button that moves every chat", async () => {
  const calls: unknown[] = [];
  const container = await draw(
    <EvacuateControl onEvacuate={(sessions) => calls.push(sessions)} onCancel={() => calls.push("cancel")} />,
  );
  const button = container.querySelector<HTMLElement>('[data-testid="evacuate-button"]')!;
  expect(button.textContent).toBe("Evacuate to Cloud");
  await act(async () => button.click());
  expect(calls).toEqual([undefined]);
  expect(container.querySelector(".acpmux-evac")).toBeNull();
});

test("a running Evacuate draws every chat with its step or state, the clock, and Cancel", async () => {
  const calls: string[] = [];
  const container = await draw(
    <EvacuateControl
      state={EVACUATES.running}
      now={evacuateAt(EVACUATES.running)}
      onEvacuate={() => calls.push("evacuate")}
      onCancel={() => calls.push("cancel")}
    />,
  );
  const words = text(container);
  expect(words).toContain("Moving 3 of 5 to Cloud");
  expect(words).toContain("13 s");
  const rows = [...container.querySelectorAll<HTMLElement>(".acpmux-evac-rows li")];
  expect(rows).toHaveLength(5);
  expect(rows.map((row) => row.getAttribute("data-state"))).toEqual(["live", "moving", "moving", "queued", "failed"]);
  expect(rows[1]!.textContent).toContain("5/8");
  expect(rows[2]!.textContent).toContain("3/8");
  expect(rows[3]!.textContent).toContain("Waiting");
  expect(rows[4]!.textContent).toContain("VM limit is reached.");
  expect(container.querySelector('[data-testid="evacuate-button"]')).toBeNull();
  expect(container.querySelector('[data-testid="evacuate-retry"]')).toBeNull();
  await act(async () => container.querySelector<HTMLElement>('[data-testid="evacuate-cancel"]')!.click());
  expect(calls).toEqual(["cancel"]);
});

test("a finished Evacuate with a failure offers Retry for just the failed chats", async () => {
  const calls: unknown[] = [];
  const container = await draw(
    <EvacuateControl
      state={EVACUATES.finished}
      onEvacuate={(sessions) => calls.push(sessions)}
      onCancel={() => calls.push("cancel")}
    />,
  );
  expect(text(container)).toContain("Moved 4 of 5 to Cloud, 1 failed");
  expect(container.querySelector('[data-testid="evacuate-cancel"]')).toBeNull();
  await act(async () => container.querySelector<HTMLElement>('[data-testid="evacuate-retry"]')!.click());
  expect(calls).toEqual([["e-5"]]);
});

test("every Evacuate look draws; the bar has one segment per chat and the chip is one pill", async () => {
  for (const look of ["bar", "panel", "chip"] as const) {
    const container = await draw(
      <EvacuateControl
        state={EVACUATES.running}
        look={look}
        now={evacuateAt(EVACUATES.running)}
        onEvacuate={noop}
        onCancel={noop}
      />,
    );
    expect(text(container)).toContain("Moving 3 of 5 to Cloud");
    expect(container.querySelectorAll(".acpmux-move-bar > span").length).toBe(look === "bar" ? 5 : 0);
    expect(container.querySelectorAll(".acpmux-evac-rows li").length).toBe(look === "panel" ? 5 : 0);
    expect(container.querySelector(".acpmux-evac-chip") !== null).toBe(look === "chip");
    await act(async () => root!.unmount());
    root = undefined;
  }
});

test("Evacuate with counts only still draws the summary and a bar", async () => {
  const state = { running: 2, done: 1, failed: 0, total: 4 };
  const container = await draw(<EvacuateControl state={state} look="bar" onEvacuate={noop} onCancel={noop} />);
  expect(text(container)).toContain("Moving 2 of 4 to Cloud");
  expect(
    [...container.querySelectorAll(".acpmux-move-bar > span")].map((segment) => segment.getAttribute("data-state")),
  ).toEqual(["live", "moving", "moving", "queued"]);
});

test("bring back is read from the app: its direction and the count it can bring home", () => {
  expect(evacuateOf({ running: 0, done: 0, failed: 0, total: 0, canBringBack: 3 })?.canBringBack).toBe(3);
  expect(evacuateOf({ running: 0, done: 0, failed: 0, total: 0, canBringBack: 0 })?.canBringBack).toBe(0);
  // An Evacuate to Cloud that finished, its chats since brought back one by one: the app's 0 wins over the run's count.
  expect(bringBackCount(evacuateOf({ running: 0, done: 2, failed: 0, total: 2, canBringBack: 0 }))).toBe(0);
  expect(bringBackCount(evacuateOf({ running: 0, done: 2, failed: 0, total: 2 }))).toBe(2);
  expect(evacuateOf({ running: 0, done: 0, failed: 0, total: 0, direction: "toLocal" })?.direction).toBe("toLocal");
  expect(evacuateOf({ running: 0, done: 0, failed: 0, total: 0, direction: "sideways" })?.direction).toBeUndefined();
  expect(bringBackCount(EVACUATES.bringBackIdle)).toBe(3);
  expect(bringBackCount(EVACUATES.finished)).toBe(4);
  expect(bringBackCount(EVACUATES.bringBackFinished)).toBe(0);
  expect(bringBackCount(undefined)).toBe(0);
});

test("with chats in Cloud the header offers Bring Back to This Mac, one action for all", async () => {
  const calls: unknown[] = [];
  const container = await draw(
    <EvacuateControl
      part="head"
      state={EVACUATES.bringBackIdle}
      onEvacuate={() => calls.push("evacuate")}
      onBringBack={(sessions) => calls.push(sessions ?? "all")}
      onCancel={noop}
    />,
  );
  expect(container.querySelector('[data-testid="evacuate-button"]')).not.toBeNull();
  await act(async () => container.querySelector<HTMLElement>('[data-testid="evacuate-bring-back"]')!.click());
  expect(calls).toEqual(["all"]);
  await act(async () => root!.unmount());
  root = undefined;
  const none = await draw(<EvacuateControl part="head" onEvacuate={noop} onBringBack={noop} onCancel={noop} />);
  expect(none.querySelector('[data-testid="evacuate-bring-back"]')).toBeNull();
});

test("the finished Evacuate panel carries Bring Back, and the header does not repeat it", async () => {
  const calls: unknown[] = [];
  const container = await draw(
    <EvacuateControl
      state={EVACUATES.finished}
      onEvacuate={noop}
      onBringBack={(sessions) => calls.push(sessions ?? "all")}
      onCancel={noop}
    />,
  );
  expect(container.querySelectorAll('[data-testid="evacuate-bring-back"]').length).toBe(1);
  expect(container.querySelector('.acpmux-evac [data-testid="evacuate-bring-back"]')).not.toBeNull();
  await act(async () => container.querySelector<HTMLElement>('[data-testid="evacuate-bring-back"]')!.click());
  expect(calls).toEqual(["all"]);
});

test("a running Bring Back uses the same panel: the title, the rows, and no Bring Back button", async () => {
  const container = await draw(
    <EvacuateControl
      state={EVACUATES.bringBackRunning}
      now={evacuateAt(EVACUATES.bringBackRunning)}
      onEvacuate={noop}
      onBringBack={noop}
      onCancel={noop}
    />,
  );
  expect(text(container)).toContain("Bringing 3 of 5 back to This Mac");
  const rows = [...container.querySelectorAll<HTMLElement>(".acpmux-evac-rows li")];
  expect(rows[0]!.textContent).toContain("On This Mac");
  expect(rows[1]!.textContent).toContain("Copying your folder");
  expect(rows[2]!.textContent).toContain("7/8");
  expect(container.querySelector('[data-testid="evacuate-bring-back"]')).toBeNull();
  expect(container.querySelector('[data-testid="evacuate-button"]')).toBeNull();
});

test("a finished Bring Back says what came home, and Retry runs Bring Back for the failed chats", async () => {
  const calls: unknown[] = [];
  const container = await draw(
    <EvacuateControl
      state={EVACUATES.bringBackFinished}
      onEvacuate={() => calls.push("evacuate")}
      onBringBack={(sessions) => calls.push(sessions)}
      onCancel={noop}
    />,
  );
  expect(text(container)).toContain("Brought 4 of 5 back to This Mac, 1 failed");
  await act(async () => container.querySelector<HTMLElement>('[data-testid="evacuate-retry"]')!.click());
  expect(calls).toEqual([["e-5"]]);
});

test("Bring Back draws in every look", async () => {
  for (const look of ["bar", "chip"] as const) {
    const container = await draw(
      <EvacuateControl
        state={EVACUATES.bringBackRunning}
        look={look}
        now={evacuateAt(EVACUATES.bringBackRunning)}
        onEvacuate={noop}
        onCancel={noop}
      />,
    );
    expect(text(container)).toContain("Bringing 3 of 5 back to This Mac");
    await act(async () => root!.unmount());
    root = undefined;
  }
});

test("the app's startedMs is its monotonic clock and is ignored: the clock ticks from arrival", () => {
  jest.useFakeTimers();
  jest.setSystemTime(new Date(Date.UTC(2026, 10, 23, 9, 0, 0)));
  const arrived = Date.now();
  for (const startedMs of [0, 123_456, 9_999_999_999_999, -5]) {
    const move = placeOf({
      mode: "cloud",
      at: "local",
      move: { state: "moving", step: "sync", startedMs, elapsedMs: 4200 },
    })?.move;
    expect(move && elapsedNow(move, arrived)).toBe(4200);
    expect(move && elapsedNow(move, arrived + 3000)).toBe(7200);
    const state = evacuateOf({
      running: 1,
      done: 0,
      failed: 0,
      total: 2,
      startedMs,
      elapsedMs: 12_000,
      chats: [{ session: "a", title: "A", state: "moving" }],
    });
    expect(state && evacuateElapsed(state, arrived)).toBe(12_000);
    expect(state && evacuateElapsed(state, arrived + 2000)).toBe(14_000);
  }
  jest.useRealTimers();
});

test("a pick and a Retry send the queue and draft the page holds then", async () => {
  const calls: unknown[] = [];
  installDom();
  (dom!.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions = {
    "action.run": (params: unknown) => {
      calls.push(params);
      return Promise.resolve();
    },
  };
  let held = { queued: 2, hasDraft: true };
  const place = placeActions("s-1", undefined, () => held);
  place.setMode("cloud");
  held = { queued: 0, hasDraft: false };
  place.retry();
  place.cancel();
  expect(calls).toEqual([
    { id: "chatPlace.set", mode: "cloud", queued: 2, hasDraft: true, session: "s-1" },
    { id: "chatMove.retry", queued: 0, hasDraft: false, session: "s-1" },
    { id: "chatMove.cancel", session: "s-1" },
  ]);
});
