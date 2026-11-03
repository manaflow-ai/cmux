// A Stop pressed while the pane reconnects to acpmux is kept and sent once the pane is back
// (stopThroughReconnect.ts). Leo, 2026-10-29: "i literally can't stop you i clicked the stop button
// and it didnt do anything".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { promptRoot } from "./direct";
import { keptStopStep, useStopThroughReconnect, type KeptStop, type StopView } from "./stopThroughReconnect";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
});
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
});

const working: StopView = { sessionId: "s1", connection: "connected", isWorking: true, turnPrompt: "p1" };

test("a kept Stop waits through the lost connection and goes out once its turn runs again", () => {
  let kept: KeptStop = { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: false };
  const lost = keptStopStep(kept, { ...working, connection: "disconnected" });
  expect(lost.step).toBe("keep");
  kept = lost.kept;
  expect(keptStopStep(kept, { ...working, connection: "reconnecting" }).step).toBe("keep");
  expect(keptStopStep(kept, working).step).toBe("send");
  // Back with nothing running (acpmux's continuation of the turn still waits): nothing goes yet,
  // so a session-wide cancel never lands while the chat runs nothing; it goes once that turn runs.
  expect(keptStopStep(kept, { ...working, isWorking: false, turnPrompt: undefined }).step).toBe("keep");
});

test("a kept Stop never stops another turn", () => {
  const kept: KeptStop = { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: false };
  // A prompt that waited started while the pane was away (Codex review of #27804, P1).
  expect(keptStopStep(kept, { ...working, turnPrompt: "p2" }).step).toBe("drop");
  // One whose prompt the pane does not know is not taken for the stopped one either.
  expect(keptStopStep(kept, { ...working, turnPrompt: undefined }).step).toBe("drop");
  // Nor does a Stop pressed on a turn the pane could not name go to whatever runs later
  // (Codex re-review of #27804, P1).
  const unnamed: KeptStop = { sessionId: "s1", awaitsDisconnect: false };
  expect(keptStopStep(unnamed, { ...working, turnPrompt: undefined }).step).toBe("drop");
});

test("a snapshot emitted for an event reads as reachable (Codex re-review of #27804, P2)", () => {
  const kept: KeptStop = { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: false };
  // The client names each snapshot after what it emitted it for: an event's kind, history, ….
  for (const connection of ["turn_started", "agent_message_chunk", "history", "attached"])
    expect(keptStopStep(kept, { ...working, connection }).step).toBe("send");
  for (const connection of ["disconnected", "reconnecting", "connecting", "connecting: refused"])
    expect(keptStopStep(kept, { ...working, connection }).step).toBe("keep");
});

test("a Stop refused while the pane still read connected waits for the disconnect first", () => {
  const closing: KeptStop = { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: true };
  expect(keptStopStep(closing, working).step).toBe("keep");
  const lost = keptStopStep(closing, { ...working, connection: "disconnected" });
  expect(lost).toEqual({ step: "keep", kept: { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: false } });
  expect(keptStopStep(lost.kept, working).step).toBe("send");
  // It never lost the connection and the turn ended: nothing is left to stop.
  expect(keptStopStep(closing, { ...working, isWorking: false }).step).toBe("drop");
  // Nor does a next turn read Stopping… until some later disconnect (Codex review of #27804, P1).
  expect(keptStopStep(closing, { ...working, turnPrompt: "p2" }).step).toBe("drop");
});

test("a kept Stop is for its chat only", () => {
  const kept: KeptStop = { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: false };
  expect(keptStopStep(kept, { ...working, sessionId: "s2" }).step).toBe("drop");
  expect(keptStopStep(kept, { ...working, sessionId: undefined, connection: "disconnected" }).step).toBe("drop");
});

test("acpmux's continuation of a cut turn runs for that turn's prompt", () => {
  expect(promptRoot("p1~resume-1")).toBe("p1");
  expect(promptRoot("p1~resume-12")).toBe("p1");
  expect(promptRoot("p1")).toBe("p1");
});

test("the composer's Stop during a reconnect says it is stopping and stops the turn once acpmux is back", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  let online = false;
  const cancels: string[] = [];
  const cancel = () => {
    cancels.push(online ? "sent" : "refused");
    return online ? Promise.resolve() : Promise.reject(new Error("not connected"));
  };
  let shown: { stop: () => void; stopping: boolean } | undefined;
  function Probe({ view }: { view: StopView }) {
    shown = useStopThroughReconnect(view, cancel);
    return null;
  }
  const root = createRoot(dom.window.document.body.appendChild(dom.window.document.createElement("div")));
  const render = (view: StopView) => act(async () => root.render(<Probe view={view} />));
  // acpmux restarted on a new version mid-turn: the pane shows the turn still working.
  const reconnecting = { ...working, connection: "disconnected" };
  await render(reconnecting);
  expect(shown!.stopping).toBe(false);
  await act(async () => shown!.stop());
  expect(cancels).toEqual(["refused"]);
  expect(shown!.stopping).toBe(true);
  // Still away: nothing more is sent.
  await render({ ...reconnecting });
  expect(cancels).toEqual(["refused"]);
  // The pane connected again and acpmux resumed the turn: the Stop goes out, once.
  online = true;
  await render(working);
  expect(cancels).toEqual(["refused", "sent"]);
  expect(shown!.stopping).toBe(false);
  await render({ ...working });
  expect(cancels).toEqual(["refused", "sent"]);
  await act(async () => root.unmount());
});

test("a Stop acpmux took is not sent again", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const cancels: number[] = [];
  let shown: { stop: () => void; stopping: boolean } | undefined;
  function Probe({ view }: { view: StopView }) {
    shown = useStopThroughReconnect(view, () => {
      cancels.push(1);
      return Promise.resolve();
    });
    return null;
  }
  const root = createRoot(dom.window.document.body.appendChild(dom.window.document.createElement("div")));
  await act(async () => root.render(<Probe view={working} />));
  await act(async () => shown!.stop());
  await act(async () => root.render(<Probe view={{ ...working, connection: "disconnected" }} />));
  await act(async () => root.render(<Probe view={{ ...working }} />));
  expect(cancels).toHaveLength(1);
  expect(shown!.stopping).toBe(false);
  await act(async () => root.unmount());
});

test("a kept Stop does not stop the queued prompt that started while the pane was away", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  let online = false;
  const cancels: string[] = [];
  let shown: { stop: () => void; stopping: boolean } | undefined;
  function Probe({ view }: { view: StopView }) {
    shown = useStopThroughReconnect(view, () => {
      cancels.push(online ? "sent" : "refused");
      return online ? Promise.resolve() : Promise.reject(new Error("not connected"));
    });
    return null;
  }
  const root = createRoot(dom.window.document.body.appendChild(dom.window.document.createElement("div")));
  const render = (view: StopView) => act(async () => root.render(<Probe view={view} />));
  await render({ ...working, connection: "disconnected" });
  await act(async () => shown!.stop());
  expect(shown!.stopping).toBe(true);
  // Back, and the stopped turn ended meanwhile; the next queued prompt (p2) runs now.
  online = true;
  await render({ ...working, turnPrompt: "p2" });
  expect(cancels).toEqual(["refused"]);
  expect(shown!.stopping).toBe(false);
  // Its continuation never comes back to life through that Stop either.
  await render({ ...working, isWorking: false, turnPrompt: undefined });
  await render(working);
  expect(cancels).toEqual(["refused"]);
  await act(async () => root.unmount());
});
