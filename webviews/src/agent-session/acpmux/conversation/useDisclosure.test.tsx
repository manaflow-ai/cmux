// `useDisclosure(key)` (useDisclosure.ts; docs/design/transcript-motion-model.md, step 5 "One
// disclosure"): each toggle is one transition of the motion owner, anchored on the row it is drawn in,
// which declares its move to the layout watcher; outside a transcript it applies at once.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { cardOpen } from "../turnChanges/openStore";
import { resetPageSpaces, rowRevision } from "./disclosureStore";
import { messageOpened } from "./incomingOpened";
import { liveExpectations, resetLayoutWatch } from "./layoutWatch";
import { type MotionList, transition } from "./motionOwner";
import {
  DisclosureMotion,
  DisclosureRow,
  resetTranscriptDisclosure,
  type RunDisclosure,
} from "./transcriptDisclosureModel";
import { type Disclosure, type DisclosureKey, useDisclosure } from "./useDisclosure";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  resetPageSpaces();
  resetLayoutWatch();
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const drawn = new Map<string, Disclosure>();
function Line({ name, at }: { name: string; at: DisclosureKey }) {
  drawn.set(name, useDisclosure(at));
  return null;
}

async function mount(node: ReactNode) {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "localStorage", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  drawn.clear();
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(node);
  });
}

/// A transcript's owner: every run is one transition on a fake list, logged.
function owner() {
  const runs: string[] = [];
  const list: MotionList = { offsetOf: () => 0, scrollBy: () => {}, rowsAfter: () => ["after"], settle: () => {} };
  const pending: (() => void)[] = [];
  const run: RunDisclosure = (anchorRow, apply) => {
    runs.push(anchorRow);
    transition(
      list,
      { cause: "disclosure", anchorRow, ms: 100, apply },
      { set: (end) => pending.push(end), clear: () => {} },
    );
  };
  return { runs, run, end: () => pending.splice(0).forEach((end) => end()) };
}

test("a toggle in a transcript row is one disclosure transition the watcher expects", async () => {
  const { runs, run, end } = owner();
  await mount(
    <DisclosureMotion.Provider value={run}>
      <DisclosureRow.Provider value="row1">
        <Line name="line" at="row:call1" />
        <Line name="message" at={{ message: "row1\u0000m", sessionId: "chat" }} />
        <Line name="card" at={{ card: "row1" }} />
      </DisclosureRow.Provider>
    </DisclosureMotion.Provider>,
  );
  for (const [name, at] of [
    ["line", 1],
    ["message", 2],
    ["card", 3],
  ] as const) {
    expect(drawn.get(name)!.open).toBe(false);
    await act(async () => drawn.get(name)!.toggle());
    expect(drawn.get(name)!.open).toBe(true);
    expect(runs).toHaveLength(at);
    expect(runs.at(-1)).toBe("row1");
    // The one transition is what the watcher was told to expect, on the rows after the anchor.
    const live = liveExpectations();
    expect(live).toHaveLength(1);
    expect(live[0]).toMatchObject({ reason: "disclosure", anchorRow: "row1" });
    end();
  }
  expect(messageOpened("chat", "row1\u0000m")).toBe(true);
  expect(cardOpen("row1")).toBe(true);
  // Each change is credited to the row, which the list's state signature reads.
  expect(rowRevision("chat", "row1")).toBeGreaterThan(0);
  // Setting what it already is runs nothing.
  await act(async () => drawn.get("card")!.set(true));
  expect(runs).toHaveLength(3);
});

test("outside a transcript a toggle applies at once, with no transition", async () => {
  await mount(<Line name="card" at={{ card: "lone" }} />);
  await act(async () => drawn.get("card")!.toggle());
  expect(drawn.get("card")!.open).toBe(true);
  expect(liveExpectations()).toHaveLength(0);
});
