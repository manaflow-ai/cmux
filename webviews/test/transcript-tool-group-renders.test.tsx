// l10n-allow-file: test fixture commands and MCP calls, not shipped UI.
// The live row's tool groups (TurnRows.tsx groupNode): a streamed chunk to one call draws that call's
// group again and no other. The transcript replaces only that call's activity (direct.ts), so every
// other group's items are the same objects; each group line draws again only when what it shows
// changed. Counted through the real ToolRows path, by disclosure key: a ToolGroupRow and an MCP group
// read their open state (`useTranscriptDisclosure`) once per draw.
import { afterAll, beforeAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

/// Group draws, by disclosure key.
const drawn = new Map<string, number>();
const DISCLOSURE = "../src/agent-session/acpmux/conversation/transcriptDisclosureModel";
const real = await import(DISCLOSURE);
// Taken before the mock: the module's namespace then reads the mock (bun patches it in place).
const realDisclosure = real.useTranscriptDisclosure as (...args: unknown[]) => unknown;
void mock.module(DISCLOSURE, () => ({
  ...real,
  useTranscriptDisclosure: (key: string, ...rest: unknown[]) => {
    drawn.set(key, (drawn.get(key) ?? 0) + 1);
    return realDisclosure(key, ...rest);
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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
  mock.restore();
});

const command = (n: number, output = `line ${n}\n`, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${n}`,
  tool: { id: `cmd-${n}`, title: `echo ${n}`, kind: "execute", command: `echo ${n}`, status, output },
});
const mcp = (n: number): AcpmuxActivity => ({
  kind: "tool",
  text: "mcp__docs__search",
  tool: {
    id: `mcp-${n}`,
    title: "mcp__docs__search",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify({ query: `case ${n}` }),
    output: `found ${n}`,
  },
});
const search = (n: number): AcpmuxActivity => ({
  kind: "tool",
  text: `rg case${n}`,
  tool: { id: `search-${n}`, title: `Search case${n}`, kind: "search", status: "completed", output: "" },
});

const row = (items: AcpmuxActivity[], version: number): AcpmuxRow => ({
  id: "live",
  version,
  at: 1,
  kind: "activity",
  live: true,
  items,
});

async function draw(items: AcpmuxActivity[], version: number) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  root ??= createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(items, version)} sessionId="group-renders" />));
}

test("a chunk streamed to the live row's last call draws its group alone, no other group in the row", async () => {
  const { resetTranscriptDisclosure } = await import(DISCLOSURE);
  resetTranscriptDisclosure();
  // Four groups in one row: commands, MCP calls, searches, then the commands still running.
  const items: AcpmuxActivity[] = [
    ...[0, 1, 2].map((n) => command(n)),
    ...[0, 1, 2].map(mcp),
    ...[0, 1].map(search),
    command(3),
    command(4, "", "in_progress"),
  ];
  await draw(items, 1);
  const groups = [...host.querySelectorAll<HTMLElement>("[data-tool-group], button.cv-tool.is-toggle")].length;
  expect(groups).toBeGreaterThanOrEqual(4);
  const all = [...drawn.keys()];
  expect(all.length).toBeGreaterThanOrEqual(4);

  let output = "";
  drawn.clear();
  for (let chunk = 0; chunk < 5; chunk++) {
    output += `chunk ${chunk}\n`;
    items[items.length - 1] = command(4, output, "in_progress");
    await draw([...items], 2 + chunk);
  }
  // Five chunks: the running group drew five times and no other group drew at all (a call's own
  // `row:` key is its row's, drawn as its activity changes).
  console.log(`group draws over 5 chunks: ${JSON.stringify(Object.fromEntries(drawn))}`);
  const groupDraws = Object.fromEntries([...drawn].filter(([key]) => key.startsWith("group:")));
  expect(groupDraws).toEqual({ "group:commands:cmd-3": 5 });
});
