// l10n-allow-file: test fixture titles, not shipped UI.
// A row's open state, read from the stores its lines open from (rowOpenState.ts): the transcript
// places a row at a height drawn in one open state only while the row is in that state
// (rowOpenState.ts `drawnOpenStateHolds`), and the estimate reads the same choices (model.ts
// `runLineChoice`), so a run the reader closed is never placed at its open height (Leo, 2026-11-17:
// "why is there this big gap when i have shit expanded").
import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { layoutConversation, type AcpmuxRow, type RowHeights } from "../model";
import { setMessageOpened } from "./incomingOpened";
import { drawnOpenStateHolds, rowOpenState } from "./rowOpenState";
import { DisclosureSession, resetTranscriptDisclosure, useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { runDisclosureKey } from "./turnRowsModel";

const SESSION = "row-open-state";
const scope = globalThis as Record<string, unknown>;
let dom: JSDOM | undefined;
let root: Root | undefined;
let set: ((open: boolean) => void) | undefined;

/// Sets the reader's choice on line `key`, as a line's own click does (useTranscriptDisclosure).
async function choose(key: string, open: boolean): Promise<void> {
  if (!dom) {
    dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
    Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  }
  function Line({ name }: { name: string }) {
    const [, setOpen] = useTranscriptDisclosure(name);
    set = setOpen;
    return null;
  }
  root ??= createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root!.render(
      <DisclosureSession.Provider value={SESSION}>
        <Line name={key} />
      </DisclosureSession.Provider>,
    ),
  );
  await act(async () => set!(open));
}

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  resetTranscriptDisclosure();
});

const run = (id: string, runOpen = false): AcpmuxRow => ({
  id,
  kind: "activity",
  version: 1,
  at: 0,
  foldRun: true,
  ...(runOpen ? { runOpen: true as const } : {}),
  // Three kinds of call, three groups: a run that folds under one summary line (toolGroups.ts).
  items: (["read", "execute", "search"] as const).map((kind, step) => ({
    kind: "tool",
    text: `Run step ${step}`,
    tool: { id: `${id}-c${step}`, title: `Run step ${step}`, kind, status: "completed", command: "true" },
  })),
});
const runKey = (row: AcpmuxRow) => runDisclosureKey({ items: row.items!, from: 0 }, row.id);
/// The row's estimate as the transcript lays it out, with one remembered-heights map across the
/// calls: a height estimated in another open state is not reused (model.ts `RowHeights.open`).
const known: RowHeights = new WeakMap();
const estimate = (row: AcpmuxRow) =>
  layoutConversation([row], 760, new Map(), undefined, known, undefined, SESSION).heights[0]!;

test("a choice on a run's line, a call in it or a message changes the row's open state", async () => {
  const row = run("r1");
  const closed = rowOpenState(SESSION, row);
  await choose(runKey(row), true);
  const opened = rowOpenState(SESSION, row);
  expect(opened).not.toBe(closed);
  await choose(runKey(row), false);
  expect(rowOpenState(SESSION, row)).not.toBe(opened);
  // Another row's choice is not this row's.
  const before = rowOpenState(SESSION, row);
  await choose(runKey(run("r2")), true);
  expect(rowOpenState(SESSION, row)).toBe(before);
  // A message the reader opened in a "Received N messages" row.
  const member: AcpmuxRow = { id: "m1", kind: "user", version: 1, at: 0, text: "hi" };
  const batch: AcpmuxRow = {
    id: "b1",
    kind: "laneNoticeBatch",
    version: 1,
    at: 0,
    laneNoticeBatch: { kind: "inbox", rows: [member], verdicts: {}, threads: [] },
  } as AcpmuxRow;
  const shut = rowOpenState(SESSION, batch);
  setMessageOpened(SESSION, "m1", true);
  expect(rowOpenState(SESSION, batch)).not.toBe(shut);
  setMessageOpened(SESSION, "m1", false);
  expect(rowOpenState(SESSION, batch)).toBe(shut);
});

test("a height drawn in another open state places no row out of the mounted range", async () => {
  const row = run("r3");
  await choose(runKey(row), true);
  const drawnOpen = { open: rowOpenState(SESSION, row) };
  expect(drawnOpenStateHolds(drawnOpen, SESSION, row, false)).toBe(true);
  await choose(runKey(row), false);
  expect(drawnOpenStateHolds(drawnOpen, SESSION, row, false)).toBe(false);
  // A mounted row keeps it: its observer and the motion's end measure it in the state it is drawn in.
  expect(drawnOpenStateHolds(drawnOpen, SESSION, row, true)).toBe(true);
});

test("the estimate draws a run line as the reader left it, not as it starts", async () => {
  const steered = run("r4", true);
  const startsOpen = estimate(steered);
  await choose(runKey(steered), false);
  const closed = estimate(steered);
  expect(closed).toBeLessThan(startsOpen);
  const plain = run("r5");
  const shut = estimate(plain);
  await choose(runKey(plain), true);
  expect(estimate(plain)).toBeGreaterThan(shut);
});

// The page globals `choose` set go with the file (test/support/leakDetector.ts).
afterAll(() => {
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) delete scope[key];
  dom?.window.close();
  dom = undefined;
});
