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

  test("only the shown frame and its neighbours load, the shown one first; thumbnails out of view never do", async () => {
    const page = await render(fixture());
    const full = () => page.loads.filter((l) => l.size === "full").map((l) => l.blob);
    // The filmstrip's thumbnails are out of view: the only thumbnail read is the stage's stand-in
    // for the shown frame, before its full image came.
    expect(page.loads.filter((l) => l.size === "thumb").map((l) => l.blob)).toEqual(["b11.jpg"]);
    expect(full()).toEqual(["b11.jpg", "b10.jpg"]);
    expect(page.loads.every((l) => l.session === "a")).toBe(true);
    await press("Home");
    expect(full()).toEqual(["b11.jpg", "b10.jpg", "b1.jpg", "b2.jpg"]);
    // One step on asks only for the new neighbour; a frame already loaded is not asked for again.
    await press("ArrowRight");
    expect(full()).toEqual(["b11.jpg", "b10.jpg", "b1.jpg", "b2.jpg", "b4.jpg"]);
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

// Leo 2026-10-29, on the computer use view: "why can't I click and drag? And why can't I full screen
// this picture? ... it loads a little bit slowly, and it... it's kind of blank". The frame fills the
// stage at its own shape, its thumbnail stands in until the full frame is there (never a blank
// stage), it zooms and pans, Full Screen shows it over the page, and a live session says Live.
describe("zoom, full screen, the stand-in and Live", () => {
  /** A loader whose full frames wait until `release`, as a slow host read does. */
  async function renderSlow(initial: ActivityState) {
    const loads: Load[] = [];
    const waiting: (() => void)[] = [];
    const loadFrame = (frame: ActivityFrame, size: "thumb" | "full", session: string) => {
      loads.push({ blob: frame.blob, size, session });
      const src = `data:image/png;base64,${size}-${frame.blob}`;
      return size === "thumb" ? Promise.resolve(src) : new Promise<string>((resolve) => waiting.push(() => resolve(src)));
    };
    function Page() {
      const [state, setState] = useState(initial);
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
    return {
      loads,
      release: () =>
        act(async () => {
          for (const resolve of waiting.splice(0)) resolve();
        }),
    };
  }

  test("before its full image comes, the frame's thumbnail shows at the frame's shape, never a blank stage", async () => {
    const page = await renderSlow(fixture());
    expect(document.querySelector(".viewer-loading")).toBeNull();
    const standIn = document.querySelector<HTMLImageElement>(".viewer-stage img.viewer-thumb");
    expect(standIn?.getAttribute("src")).toBe("data:image/png;base64,thumb-b11.jpg");
    const box = document.querySelector<HTMLElement>(".viewer-frame")!;
    expect(box.hasAttribute("data-fitted")).toBe(true);
    expect(box.style.getPropertyValue("--frame-ratio")).toBe(String(180 / 319));
    await page.release();
    expect(shown()).toBe("data:image/png;base64,full-b11.jpg");
    expect(document.querySelector(".viewer-thumb")).toBeNull();
  });

  test("+ and - zoom the frame, 0 fits it again, and the zoom stays while stepping", async () => {
    await render(fixture());
    const transform = () => document.querySelector<HTMLElement>(".viewer-frame")!.style.transform;
    expect(transform()).toBe("translate(0px, 0px) scale(1)");
    await press("+");
    expect(transform()).toBe("translate(0px, 0px) scale(2)");
    expect(document.querySelector(".viewer-stage")!.classList.contains("is-zoomed")).toBe(true);
    await press("ArrowLeft");
    expect(position()).toBe("7 of 8");
    expect(transform()).toBe("translate(0px, 0px) scale(2)");
    await press("-");
    expect(transform()).toBe("translate(0px, 0px) scale(1)");
    await press("=");
    await press("0");
    expect(transform()).toBe("translate(0px, 0px) scale(1)");
  });

  test("a drag pans a zoomed frame; a fitted one does not move", async () => {
    await render(fixture());
    const stage = document.querySelector<HTMLElement>(".viewer-stage")!;
    (stage as unknown as { setPointerCapture(): void }).setPointerCapture = () => undefined;
    const pointer = (type: string, x: number, y: number) =>
      act(async () => {
        stage.dispatchEvent(
          new window.MouseEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0 }) as unknown as Event,
        );
      });
    const drag = async () => {
      await pointer("pointerdown", 10, 10);
      await pointer("pointermove", 40, 25);
      await pointer("pointerup", 40, 25);
    };
    const transform = () => document.querySelector<HTMLElement>(".viewer-frame")!.style.transform;
    await drag();
    expect(transform()).toBe("translate(0px, 0px) scale(1)");
    await press("+");
    await drag();
    expect(transform()).toBe("translate(30px, 15px) scale(2)");
  });

  test("a Command-scroll zooms in about the pointer", async () => {
    await render(fixture());
    const stage = document.querySelector<HTMLElement>(".viewer-stage")!;
    await act(async () => {
      const wheel = new window.WheelEvent("wheel", { deltaY: -100, metaKey: true, cancelable: true, bubbles: true });
      stage.dispatchEvent(wheel);
      expect(wheel.defaultPrevented).toBe(true);
    });
    expect(document.querySelector<HTMLElement>(".viewer-frame")!.style.transform).toMatch(/scale\(2\.7/);
  });

  test("Full Screen shows the frame over the page, and Close goes back to the split", async () => {
    const page = await render(fixture());
    await press("ArrowLeft");
    await click(document.querySelector('.viewer-bar button[aria-label="Full Screen"]'));
    expect(page.state().viewing).toBe(true);
    const dialog = document.querySelector(".activity-viewer-dialog");
    expect(dialog).not.toBeNull();
    expect(dialog!.querySelector(".viewer-position")?.textContent).toBe("7 of 8");
    // Keys step the frame once, in the dialog only (the split's viewer under it keeps still).
    await press("ArrowLeft");
    expect(page.state().scrubSeq).toBe(8);
    expect(dialog!.querySelector(".viewer-position")?.textContent).toBe("6 of 8");
    await click(dialog!.querySelector('button[aria-label="Close"]'));
    expect(page.state().viewing).toBe(false);
    expect(document.querySelector(".activity-viewer-dialog")).toBeNull();
  });

  test("a live session says Live while it follows the newest frame; stepped back, Live goes back to it", async () => {
    const page = await render(fixture());
    expect(document.querySelector("span.viewer-live")?.textContent).toBe("Live");
    await press("ArrowLeft");
    const back = document.querySelector<HTMLButtonElement>("button.viewer-live");
    expect(back?.textContent).toBe("Live");
    await click(back);
    expect(page.state().scrubSeq).toBeUndefined();
    expect(position()).toBe("8 of 8");
  });

  test("an ended session shows no Live", async () => {
    const state = fixture();
    state.sessionsByMachine.local = state.sessionsByMachine.local!.map((s) => ({
      ...s,
      status: { ended: "Ended" },
    }));
    await render(state);
    expect(document.querySelector(".viewer-live")).toBeNull();
  });

  test("a host snapshot without the Full Screen string keeps the page's own", () => {
    const { fullScreen: _, ...hostStrings } = model.initialActivityState().strings;
    const state = model.reduceActivity(model.initialActivityState(), {
      type: "snapshot",
      state: { strings: { ...hostStrings, close: "Fermer" } },
    });
    expect(state.strings.close).toBe("Fermer");
    expect(state.strings.fullScreen).toBe("Full Screen");
  });
});
