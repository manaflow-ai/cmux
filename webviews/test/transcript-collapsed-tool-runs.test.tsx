// l10n-allow-file: test fixtures, not shipped UI.
// A run of tool calls between two messages collapses into one quiet summary line that names its
// kinds of work in the order they came, edits too, under the glyph of its main kind of work, as the
// Codex app draws it (Leo 2026-10-22: "this is pretty good ui: … the collapsing i mean"). Opened, it
// lists the rows it holds as they draw on their own. The call in flight stays out of it, on the
// live line; a failed call is counted on it; an edit waiting for its permission keeps its run open.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { layoutConversation } from "../src/agent-session/acpmux/model";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { mainToolRunCategory } from "../src/agent-session/acpmux/conversation/toolRunSummary";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { configureToolRunLook } from "../src/agent-session/acpmux/toolRunLook";
import { isEditRow } from "../src/agent-session/acpmux/turnChanges/sessionRows";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
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
  configureToolRunLook(undefined);
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const call = (id: string, kind: string, extra: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: id,
  tool: { id, title: id, kind, status: "completed", ...extra },
});
const edit = (path: string, extra: Record<string, unknown> = {}) =>
  call(`Edit ${path}`, "edit", {
    diffs: [{ path, oldText: "a\n", newText: "b\n" }],
    locations: [{ path }],
    ...extra,
  });
const read = (path: string) => call(`Read ${path}`, "read", { locations: [{ path }] });
const command = (line: string, extra: Record<string, unknown> = {}) =>
  call(line, "execute", { command: line, ...extra });

let clock = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (clock += 1_000),
  ...extra,
});
const said = (id: string) => row(id, "assistant", { text: `${id} `.repeat(40) });

/// A running turn: a message, a run that edited, read and ran, a second message, then the run the
/// agent works in now, its last command still running.
const live = (work: AcpmuxActivity[]) => [
  row("u", "user", { text: "Add retries" }),
  said("plan"),
  row("work", "activity", { items: work }),
  said("between"),
  row("now", "activity", { items: [command("git status"), command("bun test", { status: "in_progress" })] }),
];
const shaped = (work: AcpmuxActivity[]) => turnView(live(work), new Set(), { working: true, liveRuns: true });
// Tags to spaces, then one space per gap: a row's verb sits in its own element (ToolVerb.tsx).
const words = (entry: AcpmuxRow) =>
  renderToStaticMarkup(<ToolRows row={entry} />)
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ");
const toggles = (entry: AcpmuxRow) =>
  (renderToStaticMarkup(<ToolRows row={entry} />).match(/aria-expanded/g) ?? []).length;

const mixed = [
  edit("src/client.ts"),
  read("src/client.ts"),
  command("bun test net"),
  edit("src/retry.ts"),
  read("src/retry.ts"),
];

test("a run between two messages is one line naming its work in the order it came, edits too", () => {
  const work = shaped(mixed).find((entry) => entry.id === "work")!;
  expect(work.foldRun).toBe(true);
  expect(toggles(work)).toBe(1);
  expect(words(work)).toContain("Edited 2 files, read 2 files, ran a command");
  // Closed: none of its calls draws under the line.
  expect(words(work)).not.toContain("bun test net");
});

test("the app routes a folded mixed run to tool rows and estimates one summary line", () => {
  const work = shaped(mixed).find((entry) => entry.id === "work")!;
  expect(work.foldRun).toBe(true);
  expect(isEditRow(work)).toBe(false);
  expect(layoutConversation([work], 760).heights[0]).toBe(28);
});

test("the line's glyph is the run's main kind of work", () => {
  expect(mainToolRunCategory(mixed)).toBe("edited");
  expect(mainToolRunCategory([command("ls"), read("a.ts"), read("b.ts")])).toBe("read");
  expect(mainToolRunCategory([command("ls"), read("a.ts"), command("pwd")])).toBe("ran");
  // A tie goes to the kind the run did first.
  expect(mainToolRunCategory([command("ls"), read("a.ts")])).toBe("ran");
});

test("opened, the line shows the rows it holds as they draw on their own", async () => {
  const { createRoot } = await import("react-dom/client");
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  const work = shaped(mixed).find((entry) => entry.id === "work")!;
  const root: Root = createRoot(host);
  await act(async () => root.render(<ToolRows row={work} sessionId="collapsed" />));
  const line = host.querySelector<HTMLButtonElement>(".cv-tools > .cv-tool.is-toggle")!;
  expect(line.getAttribute("aria-expanded")).toBe("false");
  await act(async () => line.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  expect(line.getAttribute("aria-expanded")).toBe("true");
  // The same rows the run draws when it is not collapsed (Debug toggle codexToolRuns off).
  const open = host.querySelector(".cv-tool-run")!.textContent;
  const flat = words({ ...work, foldRun: false }).replace(/\s+/g, "");
  expect(open?.replace(/\s+/g, "")).toBe(flat);
  act(() => root.unmount());
});

test("the run the agent works in keeps its call in flight out, on the live line", () => {
  const rows = shaped(mixed);
  const now = rows.find((entry) => entry.id === "now")!;
  expect(words(now)).not.toContain("bun test");
  expect(rows.find((entry) => entry.doing)?.doing).toContain("bun test");
});

test("a call still running in an earlier run turns the line's glyph", () => {
  const background = command("bun run dev", { status: "in_progress", background: true });
  const work = shaped([...mixed, background]).find((entry) => entry.id === "work")!;
  expect(renderToStaticMarkup(<ToolRows row={work} />)).toContain("cv-spinner");
});

test("a failed call is counted on the collapsed line", () => {
  const work = shaped([...mixed, command("bun run lint", { exitCode: 1 })]).find((entry) => entry.id === "work")!;
  expect(toggles(work)).toBe(1);
  expect(words(work)).toContain("1 failed");
});

test("a run with an edit waiting for its permission is not collapsed", () => {
  const work = shaped([read("src/a.ts"), command("ls"), edit("src/a.ts", { status: "pending" })]).find(
    (entry) => entry.id === "work",
  )!;
  expect(work.foldRun).toBe(false);
  expect(words(work)).toContain("ls");
});

test("a delete or a move waiting for its permission stays in sight, live and in an ended turn", () => {
  for (const kind of ["delete", "move"]) {
    const pending = call(`${kind} old.ts`, kind, { status: "pending", locations: [{ path: "old.ts" }] });
    const items = [read("src/a.ts"), command("ls"), pending, command("pwd")];
    // Live: its run is not collapsed.
    const live = shaped(items).find((entry) => entry.id === "work")!;
    expect(live.foldRun).toBe(false);
    // Ended, its Worked for opened: the run folds around it, and it keeps its own row.
    const ended = turnView(
      [
        row("u2", "user", { text: "Tidy up" }),
        row("work2", "activity", { items }),
        said("done"),
        row("s2", "turnSummary", { status: "completed", toolCount: 4 }),
      ],
      new Set(["worked-u2"]),
      { liveRuns: true },
    ).find((entry) => entry.kind === "activity" && entry.id.startsWith("work2"))!;
    expect(ended.foldRun).toBe(true);
    expect(words(ended)).toContain(`${kind} old.ts`);
    expect(toggles(ended)).toBeGreaterThanOrEqual(1);
  }
});

test("an edit waiting for its permission keeps its row in an ended turn's folded run", () => {
  const items = [read("src/a.ts"), command("ls"), edit("src/a.ts", { status: "pending" }), command("pwd")];
  const ended = turnView(
    [
      row("u3", "user", { text: "Edit it" }),
      row("work3", "activity", { items }),
      said("asked"),
      row("s3", "turnSummary", { status: "completed", toolCount: 3 }),
    ],
    new Set(["worked-u3"]),
    { liveRuns: true },
  ).find((entry) => entry.kind === "activity" && entry.foldRun === true)!;
  // The opened Worked for's folded run itself, not the edited-files card after it: the edit keeps
  // its own row between the summary lines.
  expect(ended.id).toBe("work3:fold");
  expect(words(ended)).toContain("Read a file, ran a command");
  expect(words(ended)).toContain("Edit src/a.ts");
});

test("an edit waiting for its permission next to finished edits keeps its row", () => {
  const items = [
    read("src/a.ts"),
    command("ls"),
    edit("src/b.ts"),
    edit("src/a.ts", { status: "pending" }),
    edit("src/c.ts"),
  ];
  const live = shaped(items).find((entry) => entry.id === "work")!;
  expect(isEditRow(live)).toBe(false);
  expect(words(live)).toContain("Edit src/a.ts");
  const ended = turnView(
    [
      row("u4", "user", { text: "Edit them" }),
      row("work4", "activity", { items }),
      said("asked"),
      row("s4", "turnSummary", { status: "completed", toolCount: 5 }),
    ],
    new Set(["worked-u4"]),
    { liveRuns: true },
  ).find((entry) => entry.kind === "activity" && entry.foldRun === true)!;
  expect(words(ended)).toContain("Edit src/a.ts");
  // The finished edits on each side fold with the work around them.
  expect(words(ended)).not.toContain("Edit src/b.ts");
  expect(words(ended)).not.toContain("Edit src/c.ts");
});

test("the gallery's quieter versions dim the line", () => {
  const work = shaped([read("a.ts"), command("ls"), command("pwd")]).find((entry) => entry.id === "work")!;
  const line = () =>
    renderToStaticMarkup(<ToolRows row={work} />).match(/<button[^>]*class="cv-tool is-toggle[^"]*"/)![0];
  expect(line()).toContain("is-strong");
  configureToolRunLook("quiet-pencil");
  expect(line()).not.toContain("is-strong");
  configureToolRunLook("kind");
  expect(line()).toContain("is-strong");
});
