// The Agent Activity frame viewer (Lucas 2026-10-27: "the activity for the agent doesn't show all the
// screenshots that it takes, and you can't really navigate through it"). Every screenshot the helper
// kept shows in order; Previous / Next and Left / Right (Home / End) step through them with the step
// that made each one and "4 of 12"; a frame clicked in the timeline or grid opens the viewer over
// the page; and the viewer loads only the shown frame and its neighbours.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import type { ActivityEvent, ActivityFrame, ActivityState } from "../src/agent-activity/model";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "KeyboardEvent",
  "IntersectionObserver",
  "HTMLButtonElement",
  "DocumentFragment",
  "SVGElement",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "PointerEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

/** Thumbnails out of view never load: an observer that reports nothing in view. */
class NothingInView {
  observe() {}
  disconnect() {}
}

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  }));
  const w = window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    window,
    IS_REACT_ACT_ENVIRONMENT: true,
    IntersectionObserver: NothingInView,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const model = await import("../src/agent-activity/model");
const { ActivityView } = await import("../src/agent-activity/view");

const T0 = Date.UTC(2026, 9, 27, 9, 0, 0);

/** An app launch with no pixels, then `count` steps; every third one a key press without a frame. */
function steps(count: number): ActivityEvent[] {
  const tools = ["get_window_state", "click", "press_key"];
  const list: ActivityEvent[] = [{ seq: 0, time: T0, kind: "act", tool: "launch_app", ok: true }];
  for (let index = 1; index <= count; index += 1) {
    const tool = tools[(index - 1) % tools.length]!;
    list.push({
      seq: index,
      time: T0 + index * 1_000,
      kind: "act",
      tool,
      ok: true,
      afterFrame: tool === "press_key" ? undefined : { blob: `b${index}.jpg`, width: 180, height: 319 },
    });
  }
  return list;
}

function fixture(extra: Partial<ActivityState> = {}): ActivityState {
  const base = model.initialActivityState();
  const session = (id: string, label: string) => ({
    id,
    machine: "local",
    machineName: "This Mac",
    label,
    agentKind: "claude",
    agentName: "Claude Code",
    attribution: "credential",
    colorHex: "#30A46C",
    targetApps: [],
    status: "active" as const,
    startedAt: T0,
    lastActionAt: T0 + (id === "a" ? 2 : 1),
    acts: 0,
    observes: 0,
    errors: 0,
    foregroundOnly: false,
  });
  return {
    ...base,
    sessionsByMachine: { local: [session("a", "Calculator"), session("b", "Notes")] },
    machineNames: { local: "This Mac" },
    connections: { local: "connected" },
    // a: 12 steps, 8 with a screenshot; b: 3 steps, 2 with a screenshot.
    eventsBySession: {
      a: steps(12),
      b: steps(3).map((e) => ({ ...e, afterFrame: e.afterFrame && { ...e.afterFrame, blob: `n${e.seq}.jpg` } })),
    },
    selectedSessionID: "a",
    ...extra,
  };
}

type Load = { blob: string; size: string; session: string };

async function render(initial: ActivityState) {
  const loads: Load[] = [];
  const loadFrame = async (frame: ActivityFrame, size: "thumb" | "full", session: string) => {
    loads.push({ blob: frame.blob, size, session });
    return `data:image/png;base64,${size}-${frame.blob}`;
  };
  let current = initial;
  function Page() {
    const [state, setState] = useState(initial);
    current = state;
    return (
      <ActivityView
        state={state}
        dispatch={(action) => setState((s) => model.reduceActivity(s, action))}
        loadFrame={loadFrame}
      />
    );
  }
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () => root!.render(<Page />));
  return { loads, state: () => current };
}

const position = () => document.querySelector(".viewer-position")?.textContent;
const stepText = () => document.querySelector(".viewer-step b")?.textContent;
const shown = () => document.querySelector<HTMLImageElement>(".viewer-stage img")?.getAttribute("src");
const press = async (key: string, target: EventTarget = window) =>
  act(async () => {
    target.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true }));
  });
const click = async (element: Element | null | undefined) =>
  act(async () => {
    (element as HTMLElement).click();
  });

describe("frames", () => {
  test("every event that kept a screenshot is a frame, in order", () => {
    const state = fixture();
    expect(model.frameEvents(model.selectedEvents(state)).map((e) => e.seq)).toEqual([1, 2, 4, 5, 7, 8, 10, 11]);
    expect(model.frameIndex(state)).toBe(7);
    expect(model.positionText(model.frameIndex(state), 8, state.strings)).toBe("8 of 8");
  });

  test("stepping moves by frames, skips steps without one, and stops at either end", () => {
    let state = fixture();
    state = model.stepFrame(state, -1);
    expect(model.currentFrameEvent(state)?.seq).toBe(10);
    state = model.stepFrame(state, -1);
    expect(model.currentFrameEvent(state)?.seq).toBe(8);
    state = model.stepFrame(state, -Infinity);
    expect(model.currentFrameEvent(state)?.seq).toBe(1);
    expect(model.stepFrame(state, -1)).toBe(state);
    state = model.stepFrame(state, Infinity);
    expect(model.frameIndex(state)).toBe(7);
  });

  test("a frame is named by the step that made it", () => {
    const { strings } = model.initialActivityState();
    const label = (tool?: string, kind = "act") => model.stepLabel({ seq: 0, time: 0, kind, tool, ok: true }, strings);
    expect(label("click")).toBe("Click");
    expect(label("double_click")).toBe("Click");
    expect(label("type_text")).toBe("Type");
    expect(label("press_key")).toBe("Press Keys");
    expect(label("hotkey")).toBe("Press Keys");
    expect(label("launch_app")).toBe("Open App");
    expect(label("get_window_state")).toBe("Read Window");
    expect(label("list_windows")).toBe("List Windows");
    expect(label("scroll")).toBe("Scroll");
    expect(label("set_value")).toBe("Type");
    expect(label("perform_secondary_action")).toBe("Perform secondary action");
    expect(label(undefined, "observe")).toBe("Observe");
  });

  test("the loaded window is the shown frame and its neighbours, a repeated screenshot once", () => {
    const frames: ActivityEvent[] = ["x", "x", "y", "z", "w"].map((blob, seq) => ({
      seq,
      time: 0,
      kind: "act",
      ok: true,
      afterFrame: { blob, width: 1, height: 1 },
    }));
    expect(model.frameWindow(frames, 0).map((f) => f.blob)).toEqual(["x"]);
    expect(model.frameWindow(frames, 2).map((f) => f.blob)).toEqual(["x", "y", "z"]);
    expect(model.frameWindow(frames, 4).map((f) => f.blob)).toEqual(["z", "w"]);
  });
});

describe("the viewer in the split", () => {
  test("shows the newest screenshot with its step, time and position", async () => {
    await render(fixture());
    expect(position()).toBe("8 of 8");
    expect(stepText()).toBe("Click");
    expect(shown()).toBe("data:image/png;base64,full-b11.jpg");
    expect(document.querySelectorAll(".filmstrip .film")).toHaveLength(8);
    expect(document.querySelector(".filmstrip [aria-current]")?.getAttribute("aria-label")).toStartWith("Click, ");
  });

  test("Previous and Next step through every screenshot and stop at the ends", async () => {
    const page = await render(fixture());
    const next = document.querySelector<HTMLButtonElement>('.viewer-bar button[aria-label="Next"]')!;
    const previous = document.querySelector<HTMLButtonElement>('.viewer-bar button[aria-label="Previous"]')!;
    expect(next.disabled).toBe(true);
    await click(previous);
    expect(position()).toBe("7 of 8");
    expect(stepText()).toBe("Read Window");
    expect(page.state().scrubSeq).toBe(10);
    await click(next);
    expect(position()).toBe("8 of 8");
  });

  test("Left, Right, Home and End step frames; keys typed in the filter do not", async () => {
    await render(fixture());
    await press("ArrowLeft");
    await press("ArrowLeft");
    expect(position()).toBe("6 of 8");
    await press("ArrowRight");
    expect(position()).toBe("7 of 8");
    await press("Home");
    expect(position()).toBe("1 of 8");
    expect(document.querySelector<HTMLButtonElement>('.viewer-bar button[aria-label="Previous"]')!.disabled).toBe(true);
    await press("End");
    expect(position()).toBe("8 of 8");
    await press("ArrowLeft", document.querySelector("nav input")!);
    expect(position()).toBe("8 of 8");
    const chord = new window.KeyboardEvent("keydown", { key: "ArrowLeft", metaKey: true, bubbles: true });
    await act(async () => window.dispatchEvent(chord));
    expect(position()).toBe("8 of 8");
  });

  test("a filmstrip frame or a step with a screenshot opens it", async () => {
    await render(fixture());
    await click(document.querySelectorAll(".filmstrip .film")[2]);
    expect(position()).toBe("3 of 8");
    expect(shown()).toBe("data:image/png;base64,full-b4.jpg");
    // Newest first: seq 12 (a key press, no screenshot) is a plain row, seq 11 a button.
    const rows = [...document.querySelectorAll(".events .event")];
    expect(rows[0]!.tagName).toBe("DIV");
    await click(rows.find((row) => row.tagName === "BUTTON"));
    expect(position()).toBe("8 of 8");
  });

  test("only the shown frame and its neighbours load; thumbnails out of view never do", async () => {
    const page = await render(fixture());
    expect(page.loads.filter((l) => l.size === "thumb")).toHaveLength(0);
    expect(new Set(page.loads.map((l) => l.blob))).toEqual(new Set(["b10.jpg", "b11.jpg"]));
    expect(page.loads.every((l) => l.session === "a")).toBe(true);
    await press("Home");
    expect(new Set(page.loads.map((l) => l.blob))).toEqual(new Set(["b10.jpg", "b11.jpg", "b1.jpg", "b2.jpg"]));
    // One step on asks only for the new neighbour; a frame already loaded is not asked for again.
    await press("ArrowRight");
    expect(page.loads.map((l) => l.blob)).toEqual(["b10.jpg", "b11.jpg", "b1.jpg", "b2.jpg", "b4.jpg"]);
    expect(document.querySelectorAll(".viewer-stage img")).toHaveLength(1);
  });

  test("a session with no screenshots says so", async () => {
    const state = fixture();
    state.eventsBySession.a = state.eventsBySession.a!.map(({ afterFrame: _, ...event }) => event);
    await render(state);
    expect(document.querySelector(".viewer-empty")?.textContent).toBe("No screenshots yet");
    expect(position()).toBeUndefined();
    expect(document.querySelector(".viewer-bar")).toBeNull();
    expect(document.querySelector(".filmstrip")).toBeNull();
  });
});

describe("the viewer over the timeline and grid", () => {
  test("a frame clicked in the timeline opens that session at that frame", async () => {
    const page = await render(fixture({ layout: "timeline" }));
    const lanes = document.querySelectorAll(".lane");
    // Lane order: newest activity first (a, then b); b has two screenshots.
    expect(lanes[1]!.querySelectorAll(".film")).toHaveLength(2);
    await click(lanes[1]!.querySelectorAll(".film")[0]);
    expect(page.state().selectedSessionID).toBe("b");
    expect(page.state().viewing).toBe(true);
    expect(document.querySelector(".activity-viewer-dialog")).not.toBeNull();
    expect(position()).toBe("1 of 2");
    await press("ArrowRight");
    expect(position()).toBe("2 of 2");
    await click(document.querySelector('.activity-viewer-dialog button[aria-label="Close"]'));
    expect(page.state().viewing).toBe(false);
  });

  test("a grid tile opens its newest screenshot", async () => {
    await render(fixture({ layout: "grid" }));
    await click(document.querySelectorAll(".tile")[0]);
    expect(document.querySelector(".activity-viewer-dialog")).not.toBeNull();
    expect(position()).toBe("8 of 8");
  });
});
