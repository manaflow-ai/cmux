// l10n-allow-file: test fixture paths, commands and file text, not shipped UI.
// A collapsed run's summary line carries the lines its edits added and removed, as Claude Code
// desktop's does (Leo 2026-10-30: "i like claude code they put the number overarching too"):
// "Edited 2 files, ran a command +4 -1". A run without edits has no count. The totals are counted
// once per change to an edit, never when a command streams its output (EditCounts.tsx
// `useEditTotals`). Drawn through the real ToolRows path.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const command = (n: number, output = `line ${n}\n`, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${n}`,
  tool: { id: `cmd-${n}`, title: `echo ${n}`, kind: "execute", command: `echo ${n}`, status, output },
});
const edit = (id: string, path: string, oldText: string, newText: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Edit ${path}`,
  tool: { id, title: `Edit ${path}`, kind: "edit", status: "completed", diffs: [{ path, oldText, newText }] },
});

const row = (items: AcpmuxActivity[], version: number): AcpmuxRow => ({
  id: "edit-counts",
  version,
  at: 1,
  kind: "activity",
  foldRun: true,
  items,
});

async function draw(items: AcpmuxActivity[], version: number) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  root ??= createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(items, version)} sessionId="edit-counts" />));
}

/// The run's summary line: the first row of the transcript row, the one that folds the rest.
const summary = () => host.querySelector<HTMLElement>(".cv-tools > .cv-tool.is-toggle")!;

test("a run's summary line sums its edits: green added, red removed", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  await draw(
    [
      edit("edit-a", "/repo/a.ts", "one\ntwo\n", "one\n2\nthree\n"),
      command(1),
      edit("edit-b", "/repo/notes.md", "", "first\nsecond\n"),
    ],
    1,
  );
  const line = summary();
  expect(line.getAttribute("aria-expanded")).toBe("false");
  expect(line.querySelector(".cv-tool__summary")?.textContent).toBe("Edited 2 files, ran a command");
  // a.ts: +2 -1; notes.md: +2.
  expect(line.querySelector(".cv-tool__counts .cv-edit-diff__add")?.textContent).toBe("+4");
  expect(line.querySelector(".cv-tool__counts .cv-edit-diff__del")?.textContent).toBe("-1");
  // The totals sit outside the part that cuts with an ellipsis.
  expect(line.querySelector(".cv-tool__summary .cv-tool__counts")).toBeNull();
  expect(line.querySelector(".cv-tool__text.has-counts")).not.toBeNull();
});

test("added lines only: no red count", async () => {
  await draw([edit("edit-c", "/repo/new.md", "", "a\nb\nc\n"), command(2)], 2);
  const line = summary();
  expect(line.querySelector(".cv-edit-diff__add")?.textContent).toBe("+3");
  expect(line.querySelector(".cv-edit-diff__del")).toBeNull();
});

test("a run with no edits draws no count", async () => {
  await draw([command(3), command(4)], 3);
  const line = summary();
  expect(line.querySelector(".cv-tool__summary")?.textContent).toBe("Ran 2 commands");
  expect(line.querySelector(".cv-tool__counts")).toBeNull();
  expect(line.querySelector(".has-counts")).toBeNull();
});

test("streaming a command's output never counts the edits again", async () => {
  const { editTotalsProbe } = await import("../src/agent-session/acpmux/conversation/EditCounts");
  const items: AcpmuxActivity[] = [
    edit("edit-d", "/repo/d.ts", "x\n", "y\n"),
    ...Array.from({ length: 10 }, (_, n) => command(10 + n)),
    command(20, "", "in_progress"),
  ];
  await draw(items, 10);
  let counts = 0;
  editTotalsProbe.count = () => counts++;
  let output = "";
  for (let chunk = 0; chunk < 5; chunk++) {
    output += `chunk ${chunk}\n`;
    items[items.length - 1] = command(20, output, "in_progress");
    await draw([...items], 11 + chunk);
  }
  expect(counts).toBe(0);
  // A changed edit (a new snapshot of that call) counts once.
  items[0] = edit("edit-d", "/repo/d.ts", "x\n", "y\nz\n");
  await draw([...items], 20);
  editTotalsProbe.count = undefined;
  expect(counts).toBe(1);
  expect(summary().querySelector(".cv-edit-diff__add")?.textContent).toBe("+2");
});

test("a folded run and an edits group inside it, both ending on one edit, keep their own counts", async () => {
  const { editTotalsProbe } = await import("../src/agent-session/acpmux/conversation/EditCounts");
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  const items: AcpmuxActivity[] = [
    edit("edit-f", "/repo/f.ts", "a\n", "b\n"),
    command(40),
    edit("edit-g", "/repo/g.ts", "", "c\nd\n"),
    edit("edit-h", "/repo/h.ts", "", "e\n"),
    command(41, "", "in_progress"),
  ];
  await draw(items, 30);
  // Open the run, so its inner "Edited g.ts" group draws beside the run's own line.
  await act(async () => summary().click());
  await draw([...items], 31);
  // The run's line (f, g, h) and its "Edited 2 files" group (g, h) both end on h.
  expect(host.querySelectorAll(".cv-tool__counts").length).toBeGreaterThanOrEqual(2);
  let counts = 0;
  editTotalsProbe.count = () => counts++;
  let output = "";
  for (let chunk = 0; chunk < 4; chunk++) {
    output += `chunk ${chunk}\n`;
    items[items.length - 1] = command(41, output, "in_progress");
    await draw([...items], 32 + chunk);
  }
  editTotalsProbe.count = undefined;
  expect(counts).toBe(0);
  expect(summary().querySelector(".cv-edit-diff__add")?.textContent).toBe("+4");
});

test("a run that grows keeps one count, not every earlier prefix", async () => {
  const { editTotalsEntries } = await import("../src/agent-session/acpmux/conversation/EditCounts");
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  const items: AcpmuxActivity[] = [edit("grow-0", "/repo/grow-0.ts", "", "x\n"), command(50)];
  for (let n = 1; n <= 40; n++) {
    items.push(edit(`grow-${n}`, `/repo/grow-${n}.ts`, "", "x\n"));
    await draw([...items], 100 + n);
  }
  expect(summary().querySelector(".cv-edit-diff__add")?.textContent).toBe("+41");
  expect(editTotalsEntries(items[0]!.tool!)).toBeLessThanOrEqual(4);
});

test("editTotals: no diffs, no totals; a Write over unknown contents adds nothing", async () => {
  const { editTotals } = await import("../src/agent-session/acpmux/conversation/EditCounts");
  expect(editTotals([command(30).tool!])).toBeUndefined();
  expect(editTotals([edit("edit-e", "/repo/e.ts", "a\n", "b\n").tool!])).toEqual({ additions: 1, deletions: 1 });
});
