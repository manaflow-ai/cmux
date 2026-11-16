// l10n-allow-file: report words for the synthetic probe, never shown in the app.
//
// Renders every state of states.tsx in jsdom as App.tsx draws it, clicks each of its controls on a fresh render
// and reads where the click went, then counts: errors that say what to do next in the pane, errors that only
// point out of it, dead ends; waits that say what they wait on and about how long. scripts/cloud-ergonomics.ts
// prints it for cmuxterm-hq's `cloud-ergonomics-linux` synthetic probe; cloudErgonomics.test.tsx runs it too.
import { act, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Thinking } from "../conversation/Thinking";
import { THINKING_VERBS } from "../conversation/thinkingVerbs";
import {
  classifyError,
  controlsIn,
  controlWay,
  etaIn,
  externalHref,
  outOfAppWords,
  visibleText,
  waitReason,
  waitWords,
  type ControlWay,
  type Effect,
  type ErrorClass,
} from "./classify";
import { cloudErgonomicsStates, UNCOVERED, type ErgoState } from "./states";

export const SCHEMA = "cloud-ergonomics/v1";

export type ControlReading = { label: string; way: ControlWay; what: string[] };
export type StateReading = {
  id: string;
  type: "error" | "wait";
  surface: ErgoState["surface"];
  /// The words the person reads (raw details, hidden text and their own message left out).
  text: string;
  /// The state's element did not render: the catalog no longer matches the pane.
  missing?: true;
  // An error's reading.
  class?: ErrorClass;
  controls?: ControlReading[];
  /// The pane went on by itself on render (a rejected Cloud credential's automatic setup).
  automatic?: string[];
  outOfAppWords?: string;
  // A wait's reading.
  reason?: string;
  eta?: string;
};

export type CloudErgonomicsReport = {
  schema: typeof SCHEMA;
  errors_total: number;
  errors_with_next_step: number;
  errors_out_of_app: number;
  errors_dead_end: number;
  errors_without_next_step: number;
  /// errors_with_next_step / errors_total, 0..1 (null with no errors).
  errors_next_step_share: number | null;
  waits_total: number;
  waits_with_reason: number;
  waits_with_reason_and_eta: number;
  waits_without_reason_eta: number;
  /// States whose element did not render: a measurement that would undercount.
  missing: string[];
  offenders: { id: string; type: "error" | "wait"; class: string; text: string }[];
  states: StateReading[];
  uncovered: typeof UNCOVERED;
};

const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "Event",
  "MouseEvent",
  "KeyboardEvent",
  "CustomEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;

type Mounted = { container: HTMLElement; effects: Effect[]; unmount(): Promise<void> };

/// Native calls that leave the pane: a terminal tab, a browser tab, Settings.
const LEAVES_PANE = new Set(["tab.open", "browser.openIn", "settings.open", "app.openSettings"]);

async function mount(element: (record: (effect: Effect) => void) => ReactElement): Promise<Mounted> {
  const effects: Effect[] = [];
  const record = (effect: Effect) => void effects.push(effect);
  const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const win = dom.window as unknown as Window & Record<string, unknown>;
  win.open = ((url?: string | URL) => {
    record({ kind: "out-of-app", what: `open ${String(url ?? "")}` });
    return null;
  }) as typeof win.open;
  // The native bridge (native.ts postNative): every call answers ok, and is read as the click's effect.
  Object.assign(win, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: unknown) => {
            const method = String((message as { method?: unknown }).method);
            record({ kind: LEAVES_PANE.has(method) ? "out-of-app" : "in-place", what: method });
            return Promise.resolve({ ok: true, value: {} });
          },
        },
      },
    },
  });
  win.addEventListener("cmux:open-cloud-environment", () =>
    record({ kind: "out-of-app", what: "open the Cloud environment editor" }),
  );
  const scope = globalThis as Record<string, unknown>;
  const saved = new Map<string, [boolean, unknown]>(GLOBALS.map((key) => [key, [key in scope, scope[key]]]));
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    Event: win.Event,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    CustomEvent: win.CustomEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = win.document.getElementById("root") as HTMLElement;
  let root: Root | undefined;
  await act(async () => {
    root = createRoot(container);
    root.render(element(record));
  });
  await settle();
  return {
    container,
    effects,
    unmount: async () => {
      await act(async () => root?.unmount());
      dom.window.close();
      for (const [key, [had, value]] of saved)
        if (had) scope[key] = value;
        else delete scope[key];
    },
  };
}

/// Lets the click's promises and effects run (a macrotask, never a fixed wait).
async function settle(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const regionsOf = (container: HTMLElement, state: ErgoState) => [...container.querySelectorAll(state.region)];
const labelOf = (node: Element) =>
  (node.getAttribute("aria-label") || visibleText(node) || node.getAttribute("title") || node.tagName).slice(0, 80);

async function readError(state: ErgoState): Promise<StateReading> {
  const first = await mount(state.render);
  const regions = regionsOf(first.container, state);
  const base = { id: state.id, type: state.type, surface: state.surface } as const;
  if (regions.length === 0) {
    await first.unmount();
    return { ...base, text: "", missing: true, class: "dead-end", controls: [] };
  }
  const text = regions
    .map((region) => visibleText(region))
    .join(" ")
    .trim();
  const automatic = first.effects.filter((effect) => effect.kind === "in-place").map((effect) => effect.what);
  const pointsOut = outOfAppWords(regions);
  const labels = controlsIn(regions).map(labelOf);
  await first.unmount();
  const controls: ControlReading[] = [];
  for (const [index, label] of labels.entries()) {
    // Each control on a render of its own, so one click never changes what the next one finds.
    const view = await mount(state.render);
    const node = controlsIn(regionsOf(view.container, state))[index];
    if (!node) {
      await view.unmount();
      continue;
    }
    const href = externalHref(node);
    if (href) {
      controls.push({ label, way: "out-of-app", what: [`open ${href}`] });
      await view.unmount();
      continue;
    }
    const before = view.container.innerHTML;
    const already = view.effects.length;
    await act(async () => {
      (node as HTMLElement).click();
    });
    await settle();
    const effects = view.effects.slice(already);
    controls.push({
      label,
      way: controlWay(effects, view.container.innerHTML !== before),
      what: effects.map((effect) => effect.what),
    });
    await view.unmount();
  }
  return {
    ...base,
    text,
    class: classifyError(
      controls.map((control) => control.way),
      automatic.length > 0,
      pointsOut !== undefined,
    ),
    controls,
    ...(automatic.length > 0 ? { automatic } : {}),
    ...(pointsOut !== undefined ? { outOfAppWords: pointsOut } : {}),
  };
}

/// The words a bare Thinking line can show: any of these alone is no reason.
async function genericWaitWords(): Promise<Set<string>> {
  const words = new Set(["thinking", ...THINKING_VERBS.map((verb) => verb.toLowerCase())]);
  const bare = await mount(() => <Thinking />);
  const shown = waitWords([bare.container]).toLowerCase();
  if (shown) words.add(shown);
  await bare.unmount();
  return words;
}

async function readWait(state: ErgoState, generic: ReadonlySet<string>): Promise<StateReading> {
  const view = await mount(state.render);
  const regions = regionsOf(view.container, state);
  const base = { id: state.id, type: state.type, surface: state.surface } as const;
  const reading: StateReading =
    regions.length === 0
      ? { ...base, text: "", missing: true }
      : (() => {
          const reason = waitReason(regions, generic);
          const eta = etaIn(regions);
          return {
            ...base,
            text: regions
              .map((region) => visibleText(region))
              .join(" ")
              .trim(),
            ...(reason ? { reason } : {}),
            ...(eta ? { eta } : {}),
          };
        })();
  await view.unmount();
  return reading;
}

export async function measureCloudErgonomics(
  states: ErgoState[] = cloudErgonomicsStates(),
): Promise<CloudErgonomicsReport> {
  const generic = await genericWaitWords();
  const readings: StateReading[] = [];
  for (const state of states)
    readings.push(state.type === "error" ? await readError(state) : await readWait(state, generic));
  const errors = readings.filter((reading) => reading.type === "error");
  const waits = readings.filter((reading) => reading.type === "wait");
  const count = (cls: ErrorClass) => errors.filter((reading) => reading.class === cls).length;
  const withNext = count("next-step");
  const offenders = [
    ...errors
      .filter((reading) => reading.class !== "next-step")
      .map((reading) => ({ id: reading.id, type: "error" as const, class: reading.class!, text: reading.text })),
    ...waits
      .filter((reading) => !reading.reason || !reading.eta)
      .map((reading) => ({
        id: reading.id,
        type: "wait" as const,
        class: !reading.reason && !reading.eta ? "no-reason-no-eta" : !reading.reason ? "no-reason" : "no-eta",
        text: reading.text,
      })),
  ];
  const withReasonAndEta = waits.filter((reading) => reading.reason && reading.eta).length;
  return {
    schema: SCHEMA,
    errors_total: errors.length,
    errors_with_next_step: withNext,
    errors_out_of_app: count("out-of-app"),
    errors_dead_end: count("dead-end"),
    errors_without_next_step: errors.length - withNext,
    errors_next_step_share: errors.length ? Math.round((withNext / errors.length) * 1000) / 1000 : null,
    waits_total: waits.length,
    waits_with_reason: waits.filter((reading) => reading.reason).length,
    waits_with_reason_and_eta: withReasonAndEta,
    waits_without_reason_eta: waits.length - withReasonAndEta,
    missing: readings.filter((reading) => reading.missing).map((reading) => reading.id),
    offenders,
    states: readings,
    uncovered: UNCOVERED,
  };
}
