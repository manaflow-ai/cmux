// The who-else card from the tool calls two live sessions really made (whoElseCalls.fixture.json:
// the acpmux updates of an end-to-end run, paths renamed): Claude's acpmux MCP `who_else` and
// Codex's `sleep 60 && …/acpmux --json who-else src/lib.rs` in its shell, each through the client's
// own reducer, must reach the transcript as the card with the other session's row.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { whoElseCall } from "./whoElseCalls";
import fixture from "./whoElseCalls.fixture.json";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { kind: string; items?: AcpmuxActivity[] };

async function reduced(updates: unknown[]): Promise<AcpmuxActivity[]> {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    { mux: "user_message", msg: { text: "Who else works on src/lib.rs?" } },
    { mux: "turn_started", msg: {} },
    ...updates.map((update) => ({ update })),
    { mux: "turn_result", msg: { status: "completed" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const items = () => rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []) : []));
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!items().some((item) => item.tool?.status === "completed"))
      await new Promise<void>((resolve) => wakes.push(resolve));
    return items();
  } finally {
    client.close?.();
  }
}

test("Claude's acpmux MCP who_else call, as the daemon sent it, is the card naming the Codex session", async () => {
  const items = await reduced(fixture.claude);
  const call = items.map(whoElseCall).find(Boolean);
  expect(call?.pending).toBe(false);
  expect(call?.answer?.sessions.map((s) => [s.name, s.harness, s.branch, s.editedInCommon])).toEqual([
    ["greet-codex", "codex", "lane/greeting", 1],
  ]);
});

test("Codex's shell `… && acpmux --json who-else`, as the daemon sent it, is the card naming the Claude session", async () => {
  const items = await reduced(fixture.codex);
  const call = items.map(whoElseCall).find(Boolean);
  expect(call?.pending).toBe(false);
  expect(call?.answer?.sessions.map((s) => [s.name, s.harness, s.branch, s.editedInCommon])).toEqual([
    ["greet-claude", "claude", "main", 1],
  ]);
});
