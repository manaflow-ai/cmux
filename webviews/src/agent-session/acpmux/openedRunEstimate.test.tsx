// l10n-allow-file: test fixture commands and paths, not shipped UI.
// A folded run's line or group the reader opened is estimated open (model.ts `foldedRunSteps`), at the
// height the transcript draws it: its line, the 4px gap the fold holds, and its steps, kept to the
// 224px scroll box of the default arm (RunScroll.tsx). The estimate places the row whenever its drawn
// height is gone (another width, its "Worked for" or message run closed and opened again, history
// paged out and back). Before, it was the closed line (22px) whatever the reader opened: the rows
// under an opened "Read 2 files and ran a command" (drawn 92px) were placed 70px too high and moved
// down when it mounted, and an opened run of 30 commands (drawn 250px) 228px too high (Leo,
// 2026-11-17: "the shifts every time I'm scrolling"). The heights expected are the ones Chrome drew
// for these runs at 1100x800 (bench gap probe, gallery entries).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { layoutConversation, type AcpmuxActivity, type AcpmuxRow } from "./model";
import { TRANSCRIPT_LINE_ROW as LINE } from "./transcriptGrid";
import { TranscriptDisclosureProvider } from "./conversation/transcriptDisclosure";
import {
  resetTranscriptDisclosure,
  useTranscriptDisclosure,
  type DisclosureSetter,
} from "./conversation/transcriptDisclosureModel";
import { groupDisclosureKey, runDisclosureKey } from "./conversation/turnRowsModel";
import { runStretches, toolGroups } from "./conversation/toolGroups";
import { settleReact } from "../../../test/support/domTeardown";
import { setExperimentSwitches } from "../../experiments/switches";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  setExperimentSwitches({});
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
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

/// The reader's click on line `key`, through the store ToolRows reads (`useTranscriptDisclosure`).
async function setLine(sessionId: string, key: string, open: boolean) {
  dom ??= new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const name of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(name)) saved.set(name, scope[name]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  let set: DisclosureSetter | undefined;
  function Line() {
    [, set] = useTranscriptDisclosure(key);
    return null;
  }
  await act(async () => {
    root ??= createRoot(dom!.window.document.getElementById("root")!);
    root.render(
      <TranscriptDisclosureProvider sessionId={sessionId}>
        <Line />
      </TranscriptDisclosureProvider>,
    );
  });
  await act(async () => set!(open));
}

const command = (id: string, line: string): AcpmuxActivity => ({
  kind: "tool",
  text: line,
  tool: { id, title: line, kind: "execute", status: "completed", command: line, output: "ok\n", exitCode: 0 },
});
const read = (id: string, path: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Read ${path}`,
  tool: { id, title: `Read ${path}`, kind: "read", status: "completed", locations: [{ path }] },
});
/// A finished run in an opened "Worked for", as turns.ts shapes it: folded, its line closed.
const run = (id: string, items: AcpmuxActivity[]): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind: "activity", settled: true, foldRun: true, items }) as AcpmuxRow;
const estimate = (row: AcpmuxRow, sessionId: string) =>
  layoutConversation([row], 800, undefined, undefined, undefined, undefined, sessionId).heights[0];
const keyOf = (row: AcpmuxRow) => {
  const stretch = runStretches(row, toolGroups(row.items!))[0]!;
  return stretch.fold ? runDisclosureKey(stretch, row.id) : groupDisclosureKey(stretch.groups[0]!, 0, row.id)!;
};

test("a folded run line the reader opened is estimated at its open height, and closed again at its line", async () => {
  const row = run("mixed", [read("r1", "a.ts"), read("r2", "b.ts"), command("c1", "bun test")]);
  expect(estimate(row, "opened-run")).toBe(LINE);
  await setLine("opened-run", keyOf(row), true);
  // "Read 2 files and ran a command" opened: its line, the fold's 4px and three one-line steps (TRANSCRIPT_LINE_ROW).
  expect(estimate(row, "opened-run")).toBe(LINE + 4 + 3 * LINE);
  await setLine("opened-run", keyOf(row), false);
  expect(estimate(row, "opened-run")).toBe(LINE);
  // Another chat's choice is not this one's.
  expect(estimate(row, "another-chat")).toBe(LINE);
});

test("an opened group is estimated at its line over its steps, kept to the 224px scroll box", async () => {
  const commands = (id: string, n: number) =>
    run(
      id,
      Array.from({ length: n }, (_, at) => command(`${id}-${at}`, `echo ${at}`)),
    );
  const six = commands("six", 6);
  const thirty = commands("thirty", 30);
  await setLine("opened-group", keyOf(six), true);
  await setLine("opened-group", keyOf(thirty), true);
  // "Ran 6 commands" opened: drawn LINE + 4 + 6 lines. "Ran 30 commands" opened: drawn LINE + 4 + 224, its steps scrolling
  // in the box, never LINE + 4 + 30 lines.
  expect(estimate(six, "opened-group")).toBe(LINE + 4 + 6 * LINE);
  expect(estimate(thirty, "opened-group")).toBe(LINE + 4 + 224);
});

test("an opened edits group is estimated at its files' diff cards, not its closed line", async () => {
  const edit = (id: string, file: string, oldText: string, newText: string): AcpmuxActivity => ({
    kind: "tool",
    text: `Edit ${file}`,
    tool: {
      id,
      title: `Edit ${file}`,
      kind: "edit",
      status: "completed",
      locations: [{ path: file }],
      diffs: [{ path: file, oldText, newText }],
    },
  });
  const row = run("edits", [
    edit("e1", "/src/retry.ts", "export const a = 1;\n", "export const a = 2;\nexport const b = 3;\n"),
    edit("e2", "/src/policy.ts", "export const c = 1;\n", "export const c = 2;\n"),
  ]);
  expect(estimate(row, "opened-edits")).toBe(LINE);
  await setLine("opened-edits", keyOf(row), true);
  // Settings > Advanced > Experiments > Expanded Edits Estimate off (the default): the old estimate, its line.
  expect(estimate(row, "opened-edits")).toBe(LINE);
  setExperimentSwitches({ expandedEditsEstimate: true });
  // "Edited 2 files" opened: its line, the fold's 4px, and per file its card's 4px and 8px margins, 32px
  // head and 18px rows (3, then 2) over the 6px scrollbar lane WebKit keeps (no CSS here: WebKit's).
  // Before, its closed line alone: the rows under it were placed 194px too high (drawn 216 in WebKit).
  expect(estimate(row, "opened-edits")).toBe(LINE + 4 + (4 + 32 + 3 * 18 + 6 + 8) + (4 + 32 + 2 * 18 + 6 + 8));
});
