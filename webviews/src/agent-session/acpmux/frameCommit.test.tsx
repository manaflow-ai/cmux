// l10n-allow-file: test fixtures.
// A snapshot the client hands the pane in a frame callback is on screen in that frame (frameCommit.ts, CMUX-571):
// the state it sets is committed before the callback returns, not in a scheduler task after the frame paints. With
// the person's input waiting it is not flushed ahead of it, and a turn's start or end is never flushed in the frame
// (direct.ts `drawFrame`: the send's motion and the turn end's fold time themselves from the frame after the swap).
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { commitInFrame, inputPending } from "./frameCommit";
import { AcpmuxDirectClient, type EventRecord } from "./direct";
import { settleReact } from "../../../test/support/domTeardown";

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
  scope.IS_REACT_ACT_ENVIRONMENT = true;
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
  AcpmuxDirectClient.scheduleFrame = undefined;
  AcpmuxDirectClient.commitInFrame = undefined;
});

/// The pane's snapshot as React state, and the setter the client's listener calls.
async function pane(): Promise<{ container: HTMLElement; set: (rows: number) => void }> {
  const container = installDom();
  let set: (rows: number) => void = () => {};
  function Pane() {
    const [rows, setRows] = useState(0);
    set = setRows;
    return <span>{rows} rows</span>;
  }
  root = createRoot(container);
  await act(async () => root!.render(<Pane />));
  expect(container.textContent).toBe("0 rows");
  // The client's emit reaches the pane outside act, as in the page.
  scope.IS_REACT_ACT_ENVIRONMENT = false;
  return { container, set: (rows) => set(rows) };
}

test("a snapshot set in the frame's callback is committed before that frame paints", async () => {
  const { container, set } = await pane();
  commitInFrame(
    () => set(1),
    () => false,
  );
  // The frame renders now: the record must already be in the DOM it paints.
  expect(container.textContent).toBe("1 rows");
});

test("with a key waiting, the snapshot is not flushed ahead of it and commits after", async () => {
  const { container, set } = await pane();
  commitInFrame(
    () => set(1),
    () => true,
  );
  expect(container.textContent).toBe("0 rows");
  await new Promise((done) => setTimeout(done, 50));
  expect(container.textContent).toBe("1 rows");
});

test("input pending is the engine's own answer, false where it has none", () => {
  expect(inputPending(undefined)).toBe(false);
  expect(inputPending({} as Navigator)).toBe(false);
  expect(inputPending({ scheduling: { isInputPending: () => true } } as unknown as Navigator)).toBe(true);
  expect(
    inputPending({
      scheduling: {
        isInputPending: () => {
          throw new Error("no");
        },
      },
    } as unknown as Navigator),
  ).toBe(false);
});

test("the client commits a running turn's records in the frame, never the turn's start or end", () => {
  const frames: (() => void)[] = [];
  const committed: number[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  AcpmuxDirectClient.commitInFrame = (draw) => {
    committed.push(seq);
    draw();
  };
  let seq = 0;
  const client = AcpmuxDirectClient.fed("frame-commit", () => undefined);
  const record = (kind: string, dir: "in" | "mux", msg: unknown): EventRecord => {
    seq += 1;
    return { seq, at: 1_000 + seq, dir, kind, msg } as EventRecord;
  };
  const chunk = (text: string) =>
    record("agent_message_chunk", "in", {
      method: "session/update",
      params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
    });
  const frame = () => {
    expect(frames.length).toBe(1);
    frames.shift()!();
  };
  try {
    client.feed([record("user_message", "mux", { text: "Earlier" }), record("turn_result", "mux", {})], "snapshot");
    // The turn starts: the send's motion reads the rows before the swap.
    client.feed([record("user_message", "mux", { text: "Run the checks" })], "live");
    frame();
    expect(committed).toEqual([]);
    // Inside the running turn: in the frame.
    client.feed([chunk("Running them now.")], "live");
    frame();
    expect(committed).toEqual([seq]);
    // The turn ends: the fold reads the rows before the swap.
    client.feed([record("turn_result", "mux", {})], "live");
    frame();
    expect(committed.length).toBe(1);
  } finally {
    client.dispose();
  }
});
