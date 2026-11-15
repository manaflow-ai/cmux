// l10n-allow-file: regression fixture commands and paths, not shipped copy.
// A tool call or group the reader opened stays open when new calls arrive and the run's folds
// regroup, and one they closed stays closed; only what they never touched folds on its own (Leo,
// 2026-11-08: "if i have a tool call expanded, the auto folding situation shouldn't collapse it when
// a new tool call comes in and the folds reformat").
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { ToolRows } from "./TurnRows";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { resetTranscriptViews, setTranscriptView } from "./transcriptView";
import { settleReact } from "../../../../test/support/domTeardown";

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
    "CustomEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    CustomEvent: dom.window.CustomEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
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
  resetTranscriptViews();
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

const command = (id: string, text: string): AcpmuxActivity => ({
  kind: "tool",
  text,
  tool: { id, title: "Shell", kind: "execute", status: "completed", command: text, output: `${text}: ok\n` },
});
const read = (id: string, path: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Read ${path}`,
  tool: { id, title: `Read ${path}`, kind: "read", status: "completed", output: `contents of ${path}` },
});
const aside = (text: string): AcpmuxActivity => ({ kind: "note", text });

/// The live turn's latest row: its calls draw one by one, groups open.
const live = (id: string, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: items.length,
  at: 1,
  kind: "activity",
  live: true,
  items,
});
/// The same row once text followed it: settled, folding into its lines (turns.ts codexRuns).
const settled = (id: string, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: items.length + 100,
  at: 1,
  kind: "activity",
  settled: true,
  foldRun: true,
  items,
});

/// The disclosure line of a group or run, by its words.
const line = (container: HTMLElement, words: RegExp) =>
  [...container.querySelectorAll<HTMLButtonElement>(".cv-tool.is-run")].find((button) =>
    words.test(button.querySelector(".cv-tool__summary")?.textContent ?? ""),
  );
/// A call's own line (ToolRow, CommandRow, McpCallRow), by its id.
const call = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLButtonElement>(`button[data-tool-id="${id}"]`) ?? undefined;
const isOpen = (button: HTMLButtonElement | undefined) => button?.getAttribute("aria-expanded") === "true";

async function click(button: HTMLButtonElement | undefined) {
  expect(button).toBeDefined();
  await act(async () => button!.click());
}

test("a lone call the reader opened stays open when a second call groups it, and when the run folds", async () => {
  const session = "pin-lone";
  const container = await mount(<ToolRows row={live("r1", [read("c1", "notes.md")])} sessionId={session} />);
  expect(isOpen(call(container, "c1"))).toBe(false);
  await click(call(container, "c1"));
  expect(isOpen(call(container, "c1"))).toBe(true);
  // A second read arrives: the two calls group under "Read 2 files".
  const two = [read("c1", "notes.md"), read("c2", "plan.md")];
  await update(<ToolRows row={live("r1", two)} sessionId={session} />);
  expect(line(container, /^Read 2 files$/)).toBeDefined();
  expect(isOpen(call(container, "c1"))).toBe(true);
  // Text follows: the finished run folds, but not over the call the reader opened.
  await update(<ToolRows row={settled("r1", two)} sessionId={session} />);
  expect(isOpen(line(container, /^Read 2 files$/))).toBe(true);
  expect(isOpen(call(container, "c1"))).toBe(true);
});

test("a call opened inside a folded group stays open as more calls join the group", async () => {
  const session = "pin-folded";
  const two = [command("c1", "git pull"), command("c2", "git status")];
  const container = await mount(<ToolRows row={settled("r1", two)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 2 commands$/))).toBe(false);
  await click(line(container, /^Ran 2 commands$/));
  await click(call(container, "c1"));
  expect(isOpen(call(container, "c1"))).toBe(true);
  await update(<ToolRows row={settled("r1", [...two, command("c3", "git log -1")])} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 3 commands$/))).toBe(true);
  expect(isOpen(call(container, "c1"))).toBe(true);
});

test("a call opened in a group stays open when a call of another kind joins and the group becomes a run", async () => {
  const session = "pin-join";
  const reads = [read("c1", "notes.md"), read("c2", "plan.md")];
  const container = await mount(<ToolRows row={settled("r1", reads)} sessionId={session} />);
  await click(line(container, /^Read 2 files$/));
  await click(call(container, "c1"));
  expect(isOpen(call(container, "c1"))).toBe(true);
  // A command joins: the group's line becomes the run's ("Read 2 files and ran a command").
  await update(<ToolRows row={settled("r1", [...reads, command("c3", "git status")])} sessionId={session} />);
  const run = line(container, /ran a command/i);
  expect(isOpen(run)).toBe(true);
  expect(isOpen(call(container, "c1"))).toBe(true);
});

test("a call opened in a live group stays open when the agent's words end or split the run", async () => {
  const session = "pin-split";
  const three = [command("c1", "git pull"), command("c2", "git status"), command("c3", "git log -1")];
  const container = await mount(<ToolRows row={live("r1", three)} sessionId={session} />);
  // Live, the group is open by default; the reader opens the second call in it.
  expect(isOpen(line(container, /^Ran 3 commands$/))).toBe(true);
  await click(call(container, "c2"));
  expect(isOpen(call(container, "c2"))).toBe(true);
  // A short aside lands between the second and third calls and the turn's words follow: the run
  // splits into two lines, each folding as it finishes.
  const split = [three[0]!, three[1]!, aside("Pulled. Now the log:"), three[2]!];
  await update(<ToolRows row={settled("r1", split)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 2 commands$/))).toBe(true);
  expect(isOpen(call(container, "c2"))).toBe(true);
  // The later run, which the reader never touched, folds as before.
  expect(isOpen(line(container, /^Ran a command$/) ?? call(container, "c3"))).toBe(false);
});

test("a group the reader never touched still folds when its run finishes", async () => {
  const session = "pin-untouched";
  const two = [command("c1", "git pull"), command("c2", "git status")];
  const container = await mount(<ToolRows row={live("r1", two)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 2 commands$/))).toBe(true);
  await update(<ToolRows row={settled("r1", two)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 2 commands$/))).toBe(false);
  expect(call(container, "c1")).toBeUndefined();
});

test("a group the reader closed stays closed as calls join it and the run folds", async () => {
  const session = "pin-closed-group";
  const two = [command("c1", "git pull"), command("c2", "git status")];
  const container = await mount(<ToolRows row={live("r1", two)} sessionId={session} />);
  await click(line(container, /^Ran 2 commands$/));
  expect(isOpen(line(container, /^Ran 2 commands$/))).toBe(false);
  const three = [...two, command("c3", "git log -1")];
  await update(<ToolRows row={live("r1", three)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 3 commands$/))).toBe(false);
  await update(<ToolRows row={settled("r1", three)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 3 commands$/))).toBe(false);
});

test("closing a call inside a group that folds on its own keeps the group where the reader left it", async () => {
  const session = "pin-close-inside";
  const two = [command("c1", "git pull"), command("c2", "git status")];
  const container = await mount(<ToolRows row={live("r1", two)} sessionId={session} />);
  await click(call(container, "c1"));
  await click(call(container, "c1"));
  expect(isOpen(call(container, "c1"))).toBe(false);
  // The reader worked inside the group: the run finishing does not fold it away under them.
  await update(<ToolRows row={settled("r1", two)} sessionId={session} />);
  expect(isOpen(line(container, /^Ran 2 commands$/))).toBe(true);
  expect(isOpen(call(container, "c1"))).toBe(false);
});

test("a lone call the reader closed in the Verbose view stays closed when a second call groups it", async () => {
  const session = "pin-verbose";
  setTranscriptView(session, "verbose");
  const container = await mount(<ToolRows row={live("r1", [command("c1", "git pull")])} sessionId={session} />);
  // Verbose opens every call; the reader closes this one.
  expect(isOpen(call(container, "c1"))).toBe(true);
  await click(call(container, "c1"));
  expect(isOpen(call(container, "c1"))).toBe(false);
  await update(
    <ToolRows row={live("r1", [command("c1", "git pull"), command("c2", "git status")])} sessionId={session} />,
  );
  expect(line(container, /^Ran 2 commands$/)).toBeDefined();
  expect(isOpen(call(container, "c1"))).toBe(false);
  expect(isOpen(call(container, "c2"))).toBe(true);
});
