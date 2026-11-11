// l10n-allow-file: regression fixture commands and paths, not shipped copy.
// A run line the reader opened stays open while calls join it, its words change, its row is shaped
// anew around an aside, and the turn ends; each run between the agent's asides counts its own calls,
// and the turn's "Worked for" line counts them all (Leo, 2026-11-07: "I opened up, expanded the tool
// calls, and then it closed on by itself ... do you think we should distinguish the absolute top
// level one versus the inner ones that are interrupted by your little asides in between?").
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { translatorFor } from "../i18n";
import { FindReveal } from "./chatFind";
import { ToolRows } from "./TurnRows";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { WorkingFor } from "./WorkingFor";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { turnFoldStyle } from "./turnFoldStyle";
import { workedLabel } from "./turns";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function mount(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "customElements",
    "MutationObserver",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // An edit's diff loads @pierre/diffs, whose web component registers itself once wherever there
    // is an HTMLElement: with no customElements beside it the import fails, for every later file too.
    customElements: dom.window.customElements,
    // The diff follows the pane's theme attribute (EditDiffHunks.tsx).
    MutationObserver: dom.window.MutationObserver,
    // jsdom has no layout observer; the diff still subscribes to one.
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // The diff card (Pierre's registered element) reads its DOM constructors (SVGElement,
  // CSSStyleSheet, ShadowRoot) from the globals when it draws, as permission-edit-diff.test.tsx
  // gives it them; each goes again in teardown.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      if (!saved.has(key)) saved.set(key, undefined);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function update(node: ReactNode): Promise<void> {
  await act(async () => root!.render(node));
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const command = (id: string, text: string): AcpmuxActivity => ({
  kind: "tool",
  text,
  tool: { id, title: "Shell", kind: "execute", status: "completed", command: text },
});
const read = (id: string, path: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Read ${path}`,
  tool: { id, title: `Read ${path}`, kind: "read", status: "completed" },
});
const edit = (id: string, path: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Edit ${path}`,
  tool: {
    id,
    title: `Edit ${path}`,
    kind: "edit",
    status: "completed",
    diffs: [{ path, oldText: "a\n", newText: "b\n" }],
  },
});
const aside = (text: string): AcpmuxActivity => ({ kind: "note", text });

/// A run as the live turn shapes it (turns.ts codexRuns): settled and folding into its lines.
const run = (id: string, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: items.length,
  at: 1,
  kind: "activity",
  settled: true,
  foldRun: true,
  items,
});

const lines = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLButtonElement>(".cv-tool.is-run")].map((button) => ({
    text: button.querySelector(".cv-tool__summary")?.textContent?.trim() ?? "",
    open: button.getAttribute("aria-expanded") === "true",
  }));

const lineNamed = (container: HTMLElement, words: RegExp) =>
  [...container.querySelectorAll<HTMLButtonElement>(".cv-tool.is-run")].find((button) =>
    words.test(button.querySelector(".cv-tool__summary")?.textContent ?? ""),
  );

async function open(container: HTMLElement, words: RegExp) {
  const button = lineNamed(container, words);
  expect(button).toBeDefined();
  expect(button!.getAttribute("aria-expanded")).toBe("false");
  await act(async () => button!.click());
  expect(button!.getAttribute("aria-expanded")).toBe("true");
}

test("an opened group stays open when calls join it and change its count and words", async () => {
  const container = await mount(
    <ToolRows row={run("r1", [command("c1", "git pull"), command("c2", "git status")])} sessionId="open-state" />,
  );
  await open(container, /^Ran 2 commands$/);
  // A read joins: the group's line becomes the run's line, its words and count both change.
  await update(
    <ToolRows
      row={run("r1", [command("c1", "git pull"), command("c2", "git status"), read("c3", "notes.md")])}
      sessionId="open-state"
    />,
  );
  await update(
    <ToolRows
      row={run("r1", [
        command("c1", "git pull"),
        command("c2", "git status"),
        read("c3", "notes.md"),
        command("c4", "git log -1"),
      ])}
      sessionId="open-state"
    />,
  );
  const now = lines(container);
  expect(now).toHaveLength(1);
  expect(now[0]!.text).not.toBe("Ran 2 commands");
  expect(now[0]!.open).toBe(true);
});

test("a run line the reader closed stays closed when the run splits back into its group", async () => {
  const two = [command("c1", "git pull"), command("c2", "git status")];
  const container = await mount(<ToolRows row={run("r1", two)} sessionId="closed" />);
  await open(container, /^Ran 2 commands$/);
  // A read joins: the run's line opens where the reader opened the group's.
  await update(<ToolRows row={run("r1", [...two, read("c3", "notes.md")])} sessionId="closed" />);
  const runLine = container.querySelector<HTMLButtonElement>(".cv-tool.is-run")!;
  expect(runLine.getAttribute("aria-expanded")).toBe("true");
  await act(async () => runLine.click());
  expect(runLine.getAttribute("aria-expanded")).toBe("false");
  // The read leaves the run again (a call that runs again leaves the latest run for the live line).
  await update(<ToolRows row={run("r1", two)} sessionId="closed" />);
  expect(lines(container)).toEqual([{ text: "Ran 2 commands", open: false }]);
});

test("closing one of a run's groups leaves its sibling as it was", async () => {
  const calls = [command("c1", "git pull"), command("c2", "git status"), read("c3", "a.md"), read("c4", "b.md")];
  const container = await mount(<ToolRows row={run("r1", calls)} sessionId="siblings" />);
  await open(container, /^Ran 2 commands and read 2 files$/);
  // A call that is still running leaves the run unfolded: its groups draw, open from the run's line.
  const live = { ...run("r1", calls), foldRun: false };
  await update(<ToolRows row={live} sessionId="siblings" />);
  const groups = () => lines(container);
  expect(groups().map((line) => line.open)).toEqual([true, true]);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-tool.is-run")!.click());
  expect(groups().map((line) => line.open)).toEqual([false, true]);
});

test("an opened run stays open when an aside joins its row to the one before", async () => {
  const before = run("r1", [command("a1", "git pull"), command("a2", "git status")]);
  const later = run("r2", [command("b1", "gh pr merge 1"), read("b2", "approvals.json")]);
  const container = await mount(
    <>
      <ToolRows row={before} sessionId="aside" />
      <ToolRows row={later} sessionId="aside" />
    </>,
  );
  await open(container, /ran a command/i);
  // The aside is short: the live turn joins the two rows into the first (turns.ts mergeShortNotes).
  await update(
    <>
      <ToolRows
        row={run("r1", [...before.items!, aside("Approval recorded. Now merging:"), ...later.items!])}
        sessionId="aside"
      />
    </>,
  );
  const now = lines(container);
  // Each run between the asides keeps its own line and count; the later one is still open.
  expect(now.map((line) => line.text)).toEqual(["Ran 2 commands", now[1]!.text]);
  expect(now[1]!.text).toMatch(/ran a command/i);
  expect(now[1]!.open).toBe(true);
  expect(now[0]!.open).toBe(false);
  expect(container.querySelector(".cv-tool-note")?.textContent).toBe("Approval recorded. Now merging:");
});

test("an opened run stays open when the turn ends and its row is shaped anew", async () => {
  const items = [edit("e1", "/src/app.ts"), command("c1", "bun test"), command("c2", "git status")];
  const container = await mount(<ToolRows row={run("r1", items)} sessionId="ended" />);
  await open(container, /^Edited/);
  // The ended turn's open fold draws a run that edited under a row id of its own (turns.ts FOLDED).
  await update(<ToolRows row={{ ...run("r1:fold", items), version: 99 }} sessionId="ended" />);
  expect(lines(container)[0]!.open).toBe(true);
});

test("asides split the runs' counts; the turn's Worked for line counts every call", async () => {
  const container = await mount(
    <ToolRows
      row={run("r1", [
        command("a1", "git pull"),
        command("a2", "git status"),
        command("a3", "git log -1"),
        aside("Now merging:"),
        command("b1", "gh pr merge 1"),
        command("b2", "grep -c 1 approvals.json"),
        aside("One more check:"),
        read("c1", "sync.plist"),
      ])}
      sessionId="counts"
    />,
  );
  const now = lines(container).map((line) => line.text);
  expect(now).toEqual(["Ran 3 commands", "Ran 2 commands"]);
  // Claude's and the other Worked-for families' outer line counts the whole turn; Codex's says the time alone.
  expect(turnFoldStyle("claude", () => false).countsCalls).toBe(true);
  expect(turnFoldStyle("codex").countsCalls).toBe(false);
  const t = translatorFor("en");
  const worked: AcpmuxRow = { id: "w", version: 1, at: 1, kind: "worked", durationMs: 137_000, workedCalls: 6 };
  expect(workedLabel(t, worked)).toBe("Worked for 2m 17s · 6 tool calls");
  expect(workedLabel(t, { ...worked, workedCalls: undefined })).toBe("Worked for 2m 17s");
});

/// The group lines a row draws (`data-tool-group`), by key, and whether each is open.
const groupLines = (container: HTMLElement) =>
  Object.fromEntries(
    [...container.querySelectorAll<HTMLButtonElement>("button[data-tool-group]")].map((button) => [
      button.dataset.toolGroup!,
      button.getAttribute("aria-expanded") === "true",
    ]),
  );

async function click(container: HTMLElement, selector: string) {
  const button = container.querySelector<HTMLButtonElement>(selector);
  expect(button).not.toBeNull();
  await act(async () => button!.click());
}

test("a run whose groups the reader closed one by one stays closed when the turn folds it", async () => {
  const calls = [command("c1", "git pull"), command("c2", "git status"), read("c3", "a.md"), read("c4", "b.md")];
  const container = await mount(<ToolRows row={run("r1", calls)} sessionId="one-by-one" />);
  await open(container, /^Ran 2 commands and read 2 files$/);
  // The running turn draws the run's groups, open from the run's line; the reader closes each.
  await update(<ToolRows row={{ ...run("r1", calls), foldRun: false }} sessionId="one-by-one" />);
  expect(groupLines(container)).toEqual({ "group:commands:c1": true, "group:reads:c3": true });
  await click(container, 'button[data-tool-group="group:commands:c1"]');
  await click(container, 'button[data-tool-group="group:reads:c3"]');
  expect(groupLines(container)).toEqual({ "group:commands:c1": false, "group:reads:c3": false });
  // The turn ends: its work folds under the run's line again, closed as the reader left its groups.
  await update(<ToolRows row={{ ...run("r1", calls), version: 99 }} sessionId="one-by-one" />);
  expect(lines(container)).toEqual([{ text: "Ran 2 commands and read 2 files", open: false }]);
});

test("a steered turn's open run line stays closed over groups the reader closed while it ran", async () => {
  const calls = [command("c1", "git pull"), command("c2", "git status"), read("c3", "a.md"), read("c4", "b.md")];
  // The running turn keeps its calls in sight in their groups, open (turns.ts codexRuns).
  const container = await mount(<ToolRows row={{ ...run("r1", calls), foldRun: false }} sessionId="steered" />);
  expect(groupLines(container)).toEqual({ "group:commands:c1": true, "group:reads:c3": true });
  await click(container, 'button[data-tool-group="group:commands:c1"]');
  await click(container, 'button[data-tool-group="group:reads:c3"]');
  // A steered turn's opened Worked for draws its run lines open (`runOpen`), but not over the reader's choice.
  await update(<ToolRows row={{ ...run("r1", calls), version: 99, runOpen: true }} sessionId="steered" />);
  expect(lines(container)).toEqual([{ text: "Ran 2 commands and read 2 files", open: false }]);
});

test("a run line the reader closed stays closed when the run splits back into groups", async () => {
  const two = [command("c1", "git pull"), command("c2", "git status")];
  const three = [...two, read("c3", "a.md"), read("c4", "b.md")];
  const container = await mount(<ToolRows row={run("r1", two)} sessionId="split" />);
  await open(container, /^Ran 2 commands$/);
  // Reads join: the group grows into a run, open where the reader opened the group; they close it.
  await update(<ToolRows row={run("r1", three)} sessionId="split" />);
  const runLine = lineNamed(container, /^Ran 2 commands and read 2 files$/)!;
  expect(runLine.getAttribute("aria-expanded")).toBe("true");
  await act(async () => runLine.click());
  expect(runLine.getAttribute("aria-expanded")).toBe("false");
  // A call still running unfolds the run into its groups: each stays closed, the reads' too, which
  // the reader never opened on its own.
  await update(<ToolRows row={{ ...run("r1", three), foldRun: false }} sessionId="split" />);
  expect(groupLines(container)).toEqual({ "group:commands:c1": false, "group:reads:c3": false });
});

test("a run keeps its open state when Find shows a hidden discovery call at its start", async () => {
  const discovery: AcpmuxActivity = {
    kind: "tool",
    text: "Loaded tools",
    tool: {
      id: "d1",
      title: "ToolSearch",
      status: "completed",
      provenance: { claudeTool: "ToolSearch" },
      output: "Loaded tools",
    },
  };
  const row = run("r1", [discovery, command("c1", "git pull"), command("c2", "git status"), read("c3", "notes.md")]);
  const container = await mount(<ToolRows row={row} sessionId="reveal" />);
  await open(container, /^Ran 2 commands and read a file$/);
  // Find shows the row's hidden calls (its match is elsewhere in the row, so nothing opens for it).
  await update(
    <FindReveal.Provider value={{ rowId: "r1", card: false, needle: "no such words", repaint: () => {} }}>
      <ToolRows row={row} sessionId="reveal" />
    </FindReveal.Provider>,
  );
  const now = lines(container);
  expect(now).toHaveLength(1);
  expect(now[0]!.open).toBe(true);
});

test("opening an Edited run line leaves the edits group in it as the reader left it", async () => {
  const items = [edit("e1", "/src/app.ts"), command("c1", "bun test"), command("c2", "git status")];
  const container = await mount(<ToolRows row={run("r1", items)} sessionId="edits" />);
  await open(container, /^Edited/);
  const edits = 'button[data-tool-group="group:edits:e1"]';
  expect(container.querySelector(edits)!.getAttribute("aria-expanded")).toBe("false");
  // The reader opens the edit's diff and closes it again, then closes the run and opens it again.
  await click(container, edits);
  await click(container, edits);
  expect(container.querySelector(edits)!.getAttribute("aria-expanded")).toBe("false");
  const runLine = lineNamed(container, /^Edited/)!;
  await act(async () => runLine.click());
  await act(async () => runLine.click());
  expect(runLine.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(edits)!.getAttribute("aria-expanded")).toBe("false");
});

test("an edits group keeps its own state when an opened run line splits into groups", async () => {
  const items = [edit("e1", "/src/app.ts"), command("c1", "bun test"), command("c2", "git status")];
  const container = await mount(<ToolRows row={run("r1", items)} sessionId="edits-split" />);
  await open(container, /^Edited/);
  // A call still running unfolds the run: the commands open with the run's line, the edit stays closed.
  await update(<ToolRows row={{ ...run("r1", items), foldRun: false }} sessionId="edits-split" />);
  expect(groupLines(container)).toEqual({ "group:edits:e1": false, "group:commands:c1": true });
});

const mcp = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "mcp__linear__create_issue",
  tool: { id, title: "mcp__linear__create_issue", kind: "other", status: "completed", output: "{}" },
});
/// The MCP group's line (McpCallRows.tsx `McpGroupRow`): the row's one toggle that is no run's line
/// or tool group's line, drawn before the calls in it.
const mcpLine = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLButtonElement>("button.cv-tool.is-toggle")].find(
    (button) => button.dataset.toolGroup === undefined && !button.classList.contains("is-run"),
  );

test("a run whose groups the reader closed stays open at the turn's end over an MCP group they opened", async () => {
  const calls = [command("c1", "git pull"), command("c2", "git status"), read("c3", "a.md"), read("c4", "b.md")];
  const items = [...calls, mcp("m1"), mcp("m2")];
  const container = await mount(<ToolRows row={{ ...run("r1", items), foldRun: false }} sessionId="mcp-open" />);
  await click(container, 'button[data-tool-group="group:commands:c1"]');
  await click(container, 'button[data-tool-group="group:reads:c3"]');
  const line = mcpLine(container);
  expect(line?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => line!.click());
  expect(mcpLine(container)?.getAttribute("aria-expanded")).toBe("true");
  // The turn ends: the run folds under its line, open, so the calls the reader opened stay in sight.
  await update(<ToolRows row={{ ...run("r1", items), version: 99 }} sessionId="mcp-open" />);
  expect(lines(container)).toEqual([{ text: expect.any(String), open: true }]);
});

test("an MCP group opened after the reader set the run line opens it again at the turn's end", async () => {
  const calls = [command("c1", "git pull"), command("c2", "git status"), read("c3", "a.md"), read("c4", "b.md")];
  const items = [...calls, mcp("m1"), mcp("m2")];
  const container = await mount(<ToolRows row={run("r1", items)} sessionId="mcp-later" />);
  await open(container, /^Ran 2 commands/);
  await update(<ToolRows row={{ ...run("r1", items), foldRun: false }} sessionId="mcp-later" />);
  await click(container, 'button[data-tool-group="group:commands:c1"]');
  await click(container, 'button[data-tool-group="group:reads:c3"]');
  await act(async () => mcpLine(container)!.click());
  await update(<ToolRows row={{ ...run("r1", items), version: 99 }} sessionId="mcp-later" />);
  expect(lines(container)).toEqual([{ text: expect.any(String), open: true }]);
  // A choice on the run line after it is the newer one and stands: closed, it stays closed.
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-tool.is-run")!.click());
  await update(<ToolRows row={{ ...run("r1", items), version: 100 }} sessionId="mcp-later" />);
  expect(lines(container)).toEqual([{ text: expect.any(String), open: false }]);
});

test("the running line names the call when the reader closed the run line its group split from", async () => {
  const calls = [command("c1", "git pull"), command("c2", "git status"), read("c3", "a.md"), read("c4", "b.md")];
  const live: AcpmuxRow = {
    id: "live",
    kind: "working",
    version: 1,
    at: 0,
    below: true,
    doing: "git status",
    doingCommand: true,
    doingGroup: "group:commands:c1",
    doingGroupOpen: true,
    doingRun: "run:c1",
  };
  const view = (row: AcpmuxRow) => (
    <>
      <ToolRows row={row} sessionId="named" />
      <TranscriptDisclosureProvider sessionId="named">
        <WorkingFor row={live} now={() => 1_000} />
      </TranscriptDisclosureProvider>
    </>
  );
  const named = (container: HTMLElement) => container.querySelector(".cv-worked__doing")?.textContent ?? "";
  const container = await mount(view(run("r1", calls)));
  await open(container, /^Ran 2 commands and read 2 files$/);
  await act(async () => lineNamed(container, /^Ran 2 commands and read 2 files$/)!.click());
  // A call still running splits the run into its groups: the commands group draws closed under the
  // closed run line, so its row does not name the call, and the running line must.
  await update(view({ ...run("r1", calls), foldRun: false }));
  expect(groupLines(container)["group:commands:c1"]).toBe(false);
  expect(named(container)).toBe("git status");
  // The reader opens the group: its own row names the call, and the line no longer does.
  await click(container, 'button[data-tool-group="group:commands:c1"]');
  expect(named(container)).toBe("");
});
