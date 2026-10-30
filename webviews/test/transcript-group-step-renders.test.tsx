// l10n-allow-file: test fixture commands and thoughts, not shipped UI.
// An opened "Ran N commands" group lists every step (ToolGroupRow.tsx, as Claude Code desktop
// lists a run's), so a call streaming its output must not draw its siblings again or rebuild the
// group's step list on each chunk: the transcript replaces only that call's activity
// (direct.ts), and each step row is memoized on it. Counted through the real ToolRows path.
import { afterAll, beforeAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement, type ComponentProps } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

/// CommandRow draws, by command.
const drawn: string[] = [];
const COMMAND_ROW = "../src/agent-session/acpmux/conversation/CommandRow";
const real = await import(COMMAND_ROW);
const RealCommandRow = real.CommandRow;
void mock.module(COMMAND_ROW, () => ({
  ...real,
  CommandRow: (props: ComponentProps<typeof real.CommandRow>) => {
    drawn.push(props.item.tool!.command!);
    // CommandRow is memoized (an object, not a function), so draw it as an element.
    return createElement(RealCommandRow, props);
  },
}));

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
  mock.restore();
});

const command = (n: number, output = `line ${n}\n`, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${n}`,
  tool: { id: `cmd-${n}`, title: `echo ${n}`, kind: "execute", command: `echo ${n}`, status, output },
});
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text, startedAt: 0, endedAt: 2_000 });

const row = (items: AcpmuxActivity[], version: number): AcpmuxRow => ({
  id: "stream",
  version,
  at: 1,
  kind: "activity",
  items,
});

async function draw(items: AcpmuxActivity[], version: number) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  root ??= createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(items, version)} sessionId="step-renders" />));
}

test("a streaming call draws again alone; its 12 siblings and the thoughts stay drawn", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  const { stepProbe } = await import("../src/agent-session/acpmux/conversation/ToolGroupRow");
  resetTranscriptDisclosure();
  // A leading thought, 13 commands, and two consecutive thoughts in the middle (merged into a new
  // object on every update, thoughts.ts mergeThoughts).
  const items: AcpmuxActivity[] = [
    thought("Check the retry loop, then its callers."),
    ...Array.from({ length: 6 }, (_, n) => command(n)),
    thought("The loop has no status check."),
    thought("So the fix belongs in the loop."),
    ...Array.from({ length: 6 }, (_, n) => command(n + 6)),
    command(12, "", "in_progress"),
  ];
  await draw(items, 1);
  expect(host.querySelectorAll(".cv-steps .cv-step").length).toBe(15);
  // The leading thought shows open, in full; the merged one is one closed line.
  expect(host.querySelector(".cv-step.is-lead .cv-step-thought__body")?.textContent).toContain("retry loop");
  expect(host.querySelectorAll('.cv-step-thought[aria-expanded="false"]').length).toBe(1);
  expect(new Set(drawn).size).toBe(13);

  let builds = 0;
  stepProbe.build = () => builds++;
  drawn.length = 0;
  let output = "";
  for (let chunk = 0; chunk < 5; chunk++) {
    output += `chunk ${chunk}\n`;
    items[items.length - 1] = command(12, output, "in_progress");
    await draw([...items], 2 + chunk);
  }
  stepProbe.build = undefined;
  // Five chunks: the streaming call drew five times, nothing else drew, and the step list was
  // never rebuilt.
  expect(drawn).toEqual(Array(5).fill("echo 12"));
  expect(builds).toBe(0);

  // A new call joins: the list is rebuilt once, and only the new call draws.
  drawn.length = 0;
  stepProbe.build = () => builds++;
  await draw([...items, command(13)], 10);
  stepProbe.build = undefined;
  expect(builds).toBe(1);
  expect(drawn).toEqual(["echo 13"]);
});
