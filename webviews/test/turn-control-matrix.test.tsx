// l10n-allow-file: test fixtures.
// The turn-state x control matrix (plans/cmux-next/turn-lifecycle.md) drawn for real: for every state
// the page's table names, this draws the real composer from a snapshot in that state and the turn's own
// prompt bubble from the same rows, then checks that the send slot (empty and with a draft), one Esc and
// the prompt's Edit are exactly what the row says. A control in a state its row does not list fails, and
// so does a state the page adds without a snapshot here, or one here the page dropped.
//
// Leo, 2026-11-22: "we need to be able to map out the lifecycle and what should reasonably be possible,
// when."
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { noChat, summary, user, assistant } from "../src/gallery/fixtures/acpmux";
import { interruptedResumeTarget } from "../src/agent-session/acpmux/conversation/resumeInterrupted";
import { runsNext } from "../src/agent-session/acpmux/composer/turnHandover";
import { linkUp } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

// The page's table, between its markers.
type Row = {
  state: string;
  empty: string;
  draft: string;
  esc: string;
  edit: string;
};
const page = readFileSync(path.resolve(import.meta.dir, "../../plans/cmux-next/turn-lifecycle.md"), "utf8");
const block = page.split("<!-- turn-controls:begin -->")[1]!.split("<!-- turn-controls:end -->")[0]!;
const matrix: Row[] = block
  .split("\n")
  .filter((line) => line.startsWith("|"))
  .slice(2)
  .map((line) => {
    const [state, empty, draft, esc, edit] = line
      .split("|")
      .slice(1, -1)
      .map((cell) => cell.trim());
    return {
      state: state!,
      empty: empty!,
      draft: draft!,
      esc: esc!,
      edit: edit!,
    };
  });

// Rows: an earlier answered turn (so an edit has a turn to fork through), then the turn's own prompt.
const OWN = "own-prompt";
const before: AcpmuxRow[] = [
  user("Set up the repo", 5, { id: "first" }),
  assistant("Done.", 4.9),
  summary(4.8, { status: "completed", seq: 3 }),
];
const own = user("Review the changes", 1, { id: OWN });
const reading: AcpmuxRow[] = [...before, own, assistant("Looking…", 0.9)];
const ended = (status: "completed" | "interrupted") => [
  ...reading,
  summary(0.8, {
    status,
    durationMs: 5_000,
    seq: 7,
    resumable: status === "interrupted",
  }),
];

let chats = 0;
function chat(fields: Partial<AcpmuxSnapshot>, rows: AcpmuxRow[], goal?: "active"): AcpmuxSnapshot {
  const sessionId = `turn-matrix-${++chats}`;
  return noChat([], {
    sessionId,
    summary: {
      sessionId,
      harness: "claude",
      family: "claude",
      cwd: "/repo",
      turnCount: 2,
      steering: true,
      ...(goal && { goal: { objective: "Finish", status: goal } }),
    },
    rows,
    ...fields,
  });
}
const queued = [{ id: "q1", prompt: "Next" }];

// Each state of the page as a snapshot (or, for handing over, the snapshot before it and the one that
// makes it). A state in one list and not the other fails the coverage test.
const STATES: Record<string, { snapshot: AcpmuxSnapshot; before?: AcpmuxSnapshot }> = {
  idle: { snapshot: chat({}, ended("completed")) },
  stopped: { snapshot: chat({}, ended("interrupted")) },
  "stopped, goal runs": { snapshot: chat({}, ended("interrupted"), "active") },
  starting: {
    snapshot: chat({ switching: { harness: "codex", name: "Codex", phase: "starting" } }, [
      ...before,
      user("Go", 0.1, { queued: "q1" }),
    ]),
  },
  working: { snapshot: chat({ isWorking: true, queue: queued }, reading) },
  stopping: { snapshot: chat({ isWorking: true, stopping: true }, reading) },
  "handing over": {
    before: chat({ isWorking: true, queue: queued }, reading),
    snapshot: chat({ queue: queued }, ended("completed")),
  },
  "offline, was working": {
    snapshot: chat({ isWorking: true, connection: "disconnected" }, reading),
  },
  "offline, was stopped": {
    snapshot: chat({ connection: "disconnected" }, ended("interrupted")),
  },
};

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
let handle: ComposerHandle;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  for (const [key, value] of Object.entries({
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    InputEvent: window.InputEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  host = window.document.getElementById("root")!;
});
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});
afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

// The pane offers Resume as App.tsx does (`interruptedResumeTarget`); the composer gates it again itself.
function resumeOffer(snapshot: AcpmuxSnapshot) {
  const target = interruptedResumeTarget({
    sessionId: snapshot.sessionId,
    selectedSessionId: snapshot.sessionId,
    drawnSessionId: snapshot.sessionId,
    canResume:
      !snapshot.isWorking &&
      !runsNext(snapshot.queue, false) &&
      snapshot.summary?.goal?.status !== "active" &&
      snapshot.summary?.goal?.status !== "running",
    rows: snapshot.rows,
    family: snapshot.summary?.family,
  });
  return target ? async () => true : undefined;
}

async function drawComposer(snapshot: AcpmuxSnapshot) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={() => null}
        handle={(value) => {
          if (value) handle = value;
        }}
        onResume={resumeOffer(snapshot)}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[]}
      />,
    ),
  );
}

const SLOT = ["Send", "Stop", "Stopping…", "Press Esc again to stop", "Resume"];
const slot = () =>
  [...host.querySelectorAll("button")]
    .map((button) => button.getAttribute("aria-label") ?? "")
    .filter((label) => SLOT.includes(label));
// The empty column ignores Send: Codex's look draws it at rest, Claude's does not.
const emptySlot = () => {
  const drawn = slot().filter((label) => label !== "Send");
  return drawn.length ? drawn.join(", ") : "none";
};

async function ownPromptEdit(snapshot: AcpmuxSnapshot): Promise<string> {
  const row = snapshot.rows.find((each) => each.id === OWN);
  if (!row) return "-";
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  const { trackEditableTurns, trackPromptTurns } = await import("../src/agent-session/acpmux/conversation/editPrompt");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const bubble = dom.window.document.createElement("div");
  host.append(bubble);
  const bubbleRoot = createRoot(bubble);
  await act(async () =>
    bubbleRoot.render(
      <TurnActionsContext.Provider
        value={{
          edit: {
            seqs: trackEditableTurns(snapshot.rows, true).seqs,
            send: async () => true,
          },
          fork: () => {},
          forkAny: true,
          promptTurns: trackPromptTurns(snapshot.rows).seqs,
        }}
      >
        <UserBubble row={row} text={row.text ?? ""} />
      </TurnActionsContext.Provider>,
    ),
  );
  const offers = [...bubble.querySelectorAll("button")].some(
    (button) => button.getAttribute("aria-label") === translate("message.edit"),
  );
  await act(async () => bubbleRoot.unmount());
  bubble.remove();
  return offers ? "yes" : "no";
}

test("the page's table and this test name the same states", () => {
  expect(matrix.length).toBeGreaterThan(0);
  expect(matrix.map((row) => row.state).sort()).toEqual(Object.keys(STATES).sort());
});

for (const row of matrix) {
  test(`${row.state}: the composer and the turn's prompt offer what the table says`, async () => {
    const state = STATES[row.state];
    if (!state) throw new Error(`no snapshot for "${row.state}"`);
    if (state.before) await drawComposer(state.before);
    await drawComposer(state.snapshot);
    expect(linkUp(state.snapshot.connection)).toBe(!row.state.startsWith("offline"));
    const empty = emptySlot();
    const field = host.querySelector<HTMLElement>('[role="combobox"]')!;
    await act(async () =>
      field.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: "Escape",
          bubbles: true,
          cancelable: true,
        }),
      ),
    );
    const esc = slot().includes("Press Esc again to stop") ? "arms" : "none";
    await act(async () => handle.restore("Next", []));
    const draft = slot().join(", ") || "none";
    await act(async () => handle.take());
    const edit = await ownPromptEdit(state.snapshot);
    expect({ state: row.state, empty, draft, esc, edit }).toEqual(row);
  });
}
