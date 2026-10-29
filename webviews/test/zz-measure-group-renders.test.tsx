// Temporary measurement harness (not committed): rows drawn and time per streamed chunk of one
// call in an opened 13-command group with thoughts, through the real ToolRows path.
import { expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const { window } = new JSDOM("<!doctype html><div id=root></div>");
Object.assign(globalThis as Record<string, unknown>, {
  window,
  document: window.document,
  navigator: window.navigator,
  HTMLElement: window.HTMLElement,
  customElements: window.customElements,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const host = window.document.querySelector<HTMLElement>("#root")!;
const counts = { command: 0, thought: 0 };
const CR = "../src/agent-session/acpmux/conversation/CommandRow";
const TR = "../src/agent-session/acpmux/conversation/ThoughtRow";
const cr = await import(CR);
const tr = await import(TR);
void mock.module(CR, () => ({ ...cr, CommandRow: (p: never) => (counts.command++, cr.CommandRow(p)) }));
void mock.module(TR, () => ({
  ...tr,
  ThoughtRow: (p: never) => (counts.thought++, tr.ThoughtRow(p)),
  ...(tr.StepThought ? { StepThought: (p: never) => (counts.thought++, tr.StepThought(p)) } : {}),
}));

const command = (n: number, output = `line ${n}\n`, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${n}`,
  tool: { id: `cmd-${n}`, title: `echo ${n}`, kind: "execute", command: `echo ${n}`, status, output },
});
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text, startedAt: 0, endedAt: 2_000 });

test("measure", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const root = createRoot(host);
  const items: AcpmuxActivity[] = [
    command(100),
    ...Array.from({ length: 6 }, (_, n) => command(n)),
    thought("The loop has no status check."),
    thought("So the fix belongs in the loop."),
    ...Array.from({ length: 6 }, (_, n) => command(n + 6)),
    command(12, "", "in_progress"),
  ];
  const row = (v: number): AcpmuxRow => ({ id: "m", version: v, at: 1, kind: "activity", items: [...items] });
  await act(async () => root.render(<ToolRows row={row(1)} sessionId="m" />));
  // Open every group fully (base hides earlier calls behind "+K more").
  const more = host.querySelector<HTMLButtonElement>(".cv-tool-group__more");
  if (more) await act(async () => more.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  const shown = host.querySelectorAll(".cv-command__line").length;
  const CHUNKS = 200;
  let out = "";
  counts.command = 0;
  counts.thought = 0;
  const t0 = performance.now();
  for (let c = 0; c < CHUNKS; c++) {
    out += `chunk ${c}\n`;
    items[items.length - 1] = command(12, out, "in_progress");
    await act(async () => root.render(<ToolRows row={row(2 + c)} sessionId="m" />));
  }
  const ms = performance.now() - t0;
  console.log(
    `MEASURE shown=${shown} commandRendersPerChunk=${(counts.command / CHUNKS).toFixed(2)} thoughtRendersPerChunk=${(counts.thought / CHUNKS).toFixed(2)} msPerChunk=${(ms / CHUNKS).toFixed(3)}`,
  );
  expect(shown).toBeGreaterThan(0);
});
