// Every state of a chat's turn against the controls the pane offers in it (Leo, 2026-11-22: "we need
// to be able to map out the lifecycle and what should reasonably be possible, when"). The table is
// TURN_LIFECYCLE (src/agent-session/acpmux/turnLifecycle.fixture.ts), the gallery's
// agent-pane.turn-lifecycle shows the same states. For each state this draws the real Composer,
// reads Stop, the send control with a draft typed, Esc's double press and the queue's delete, and
// reads the turn prompt's Edit from the tracker the App feeds the bubbles (`trackEditableTurns`);
// one test per state, so a missing Stop or an Edit on a prompt the agent has read names its state.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { translate } from "../src/agent-session/acpmux/i18n";
import { trackEditableTurns } from "../src/agent-session/acpmux/conversation/editPrompt";
import {
  TURN_LIFECYCLE,
  TURN_PROMPT_ID,
  type SendCell,
  type StopCell,
  type TurnLifecycleRow,
} from "../src/agent-session/acpmux/turnLifecycle.fixture";
import { teardownDom } from "./support/domTeardown";

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
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
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
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom.window.localStorage.clear();
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

type Probe = { handle: ComposerHandle | null; stops: number };

async function render(snapshot: AcpmuxSnapshot, probe: Probe) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => void (probe.stops += 1)}
        onProject={() => {}}
        onNewChat={() => {}}
        onQueueRemove={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={(value) => void (probe.handle = value)}
      />,
    ),
  );
}

const STOP_LABELS: Record<string, StopCell> = {
  [translate("composer.stop")]: "stop",
  [translate("composer.escapeAgainToStop")]: "stop",
  [translate("composer.stopping")]: "stopping",
};

function stopCell(): StopCell {
  const stop = host.querySelector<HTMLButtonElement>(".acpmux-cancel");
  if (!stop) return "none";
  return STOP_LABELS[stop.getAttribute("aria-label") ?? ""] ?? "stop";
}

// The send control's tooltip says what it does (Composer.tsx): Send, ↵ steer, or queue.
const SEND_TITLES: Record<string, SendCell> = {
  [translate("composer.sendTooltip")]: "send",
  [translate("composer.steerTooltip")]: "steer",
  [translate("composer.steerQueueTooltip")]: "steer",
  [translate("composer.queueTooltip")]: "queue",
  [translate("composer.queueSteerTooltip")]: "queue",
};

function sendCell(): SendCell {
  const send = host.querySelector<HTMLButtonElement>(".acpmux-send:not(.acpmux-cancel)");
  if (!send || send.disabled) return "none";
  return SEND_TITLES[send.title] ?? (`unknown: ${send.title}` as SendCell);
}

async function escapeTwice() {
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  for (let press = 0; press < 2; press++)
    await act(async () => {
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });
}

/// What the pane offers in `row`'s state, read cell by cell as the table names them.
async function observe(row: TurnLifecycleRow): Promise<TurnLifecycleRow["expect"]> {
  const probe: Probe = { handle: null, stops: 0 };
  if (row.from) await render(row.from, probe);
  await render(row.snapshot, probe);
  const stop = stopCell();
  const queueDelete = host.querySelector('.acpmux-queued-action[data-action="delete"]') !== null;
  await escapeTwice();
  const escStops = probe.stops > 0;
  await act(async () => probe.handle!.restore("Use the cache", []));
  const send = sendCell();
  const stopWithDraft = host.querySelector(".acpmux-cancel") !== null;
  const edit = trackEditableTurns(row.snapshot.rows, row.snapshot.summary?.harness).seqs.has(TURN_PROMPT_ID);
  return { stop, send, stopWithDraft, escStops, edit, queueDelete };
}

for (const row of TURN_LIFECYCLE)
  test(`${row.state}: ${row.what}`, async () => {
    expect(await observe(row)).toEqual(row.expect);
  });

test("the table names each state once and covers the turn from idle to handover", () => {
  const states = TURN_LIFECYCLE.map((row) => row.state);
  expect(new Set(states).size).toBe(states.length);
  // A running turn without Stop, or a read prompt with Edit, is the gap this table exists to catch:
  // every state where a turn runs keeps a way to stop it and offers no Edit on its prompt.
  for (const row of TURN_LIFECYCLE.filter((each) => each.snapshot.isWorking)) {
    expect({ state: row.state, stop: row.expect.stop !== "none" }).toEqual({ state: row.state, stop: true });
    expect({ state: row.state, edit: row.expect.edit }).toEqual({ state: row.state, edit: false });
  }
});
