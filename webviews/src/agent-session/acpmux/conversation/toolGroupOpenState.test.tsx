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
import { ToolRows } from "./TurnRows";
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
