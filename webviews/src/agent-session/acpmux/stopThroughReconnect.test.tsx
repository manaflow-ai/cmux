// A Stop pressed while the pane reconnects to acpmux is kept and sent once the pane is back
// (stopThroughReconnect.ts). Leo, 2026-10-29: "i literally can't stop you i clicked the stop button
// and it didnt do anything".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { keptStopStep, useStopThroughReconnect, type StopView } from "./stopThroughReconnect";

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

const working: StopView = { sessionId: "s1", connection: "connected", isWorking: true };

test("a kept Stop waits through the lost connection and goes out once it is back", () => {
  let kept = { sessionId: "s1", awaitsDisconnect: false };
  const lost = keptStopStep(kept, { ...working, connection: "disconnected" });
  expect(lost.step).toBe("keep");
  kept = lost.kept;
  expect(keptStopStep(kept, { ...working, connection: "reconnecting" }).step).toBe("keep");
  expect(keptStopStep(kept, working).step).toBe("send");
  // acpmux came back with the turn not running yet (its retry waits): the Stop still goes, and
  // acpmux's Stop withdraws the waiting retry.
  expect(keptStopStep(kept, { ...working, isWorking: false }).step).toBe("send");
});

test("a Stop refused while the pane still read connected waits for the disconnect first", () => {
  const closing = { sessionId: "s1", awaitsDisconnect: true };
  expect(keptStopStep(closing, working).step).toBe("keep");
  const lost = keptStopStep(closing, { ...working, connection: "disconnected" });
  expect(lost).toEqual({ step: "keep", kept: { sessionId: "s1", awaitsDisconnect: false } });
  expect(keptStopStep(lost.kept, working).step).toBe("send");
  // It never lost the connection and the turn ended: nothing is left to stop.
  expect(keptStopStep(closing, { ...working, isWorking: false }).step).toBe("drop");
});

test("a kept Stop is for its chat only", () => {
  const kept = { sessionId: "s1", awaitsDisconnect: false };
  expect(keptStopStep(kept, { ...working, sessionId: "s2" }).step).toBe("drop");
  expect(keptStopStep(kept, { ...working, sessionId: undefined, connection: "disconnected" }).step).toBe("drop");
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
