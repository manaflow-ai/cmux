// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A finished turn folds as its harness family's own app does (Leo, 2026-11-01: "separate it per
// harness/model family. claude gets claude behaviour, codex gets codex").
//
// - Codex and ChatGPT: the turn's work, its interim chatter with it, folds under one "Worked for";
//   the final answer stays below it.
// - Claude, as Claude desktop: no "Worked for". Each run of calls, the short notes inside it with
//   it, folds into its own summary line; a longer message between runs stays in place; the final
//   answer stays last.
// - Both: a steer and the reply before it are never folded (Leo, 2026-10-31: "THE FACT THAT YOUR
//   INTERIM MESSAGE YOU SENT BETWEEN STEERS GOT COLLAPSED" was the miss).
//
// fixtures/claude-turn-groups.ndjson is one real Claude Code turn as acpmux recorded it (81 calls,
// 17 messages), its words and commands replaced with neutral ones of the same kind: a short note
// stays short, a long message stays long.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const CHAT = "0190a000-0000-7000-8000-0000000000c1";
const history = readFileSync(new URL("./fixtures/claude-turn-groups.ndjson", import.meta.url), "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));

/// The rows the pane's client makes of the recorded turn, attached as acpmux serves it.
async function replayRows(): Promise<AcpmuxRow[]> {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    steering: false,
    turnCount: 1,
    updatedAt: history.at(-1).at,
  };
  const lastSeq = history.at(-1).seq;
  const answer = (method: string) => {
    if (method === "initialize")
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    if (method === "_acpmux/watch") return { sessions: [session] };
    if (method === "_acpmux/attach") return { session, lastSeq, events: history, hasMore: false };
    if (method === "_acpmux/events") return { events: [], hasMore: false, more: false, lastSeq };
    return null;
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  client.close();
  return rows;
}

const SHORT = /^Checking step \d+\.$/;
const LONG = /^Step (\d+) found/;
/// Which message a long row is (its number in the recording).
const longAt = (row: AcpmuxRow) => Number(LONG.exec(row.text ?? "")?.[1]);
const assistants = (rows: readonly AcpmuxRow[]) => rows.filter((row) => row.kind === "assistant");

test("the recorded Claude turn ends as Claude desktop draws it: a line per run, longer messages between", async () => {
  const rows = await replayRows();
  const view = turnView(rows, new Set(), { now: history.at(-1).at + 60_000, liveRuns: true, agentFamily: "claude" });
  expect(view.some((row) => row.kind === WORKED)).toBe(false);
  // Every run folds into its summary line, which opens on a click (the edited-files card is not a run).
  const runs = view.filter((row) => row.kind === "activity" && !row.merged);
  expect(runs.length).toBeGreaterThan(1);
  expect(runs.every((row) => row.foldRun === true)).toBe(true);
  // The short notes between calls are inside the runs: none stands between two runs.
  const between = view.flatMap((row, at) =>
    row.kind === "assistant" && SHORT.test(row.text ?? "") && view[at - 1]?.foldRun && view[at + 1]?.foldRun
      ? [
          [
            row.text,
            view[at - 1]!.items?.map((item) => item.tool?.kind ?? item.kind),
            view[at + 1]!.items?.map((item) => item.tool?.kind ?? item.kind),
          ],
        ]
      : [],
  );
  expect(between).toEqual([]);
  expect(runs.some((row) => (row.items ?? []).some((item) => item.kind === "note"))).toBe(true);
  // The longer messages stay in place between the runs, and the final answer is the turn's last words.
  expect(
    assistants(view)
      .filter((row) => LONG.test(row.text ?? ""))
      .map(longAt),
  ).toEqual([14, 16, 17]);
  const summary = view.findIndex((row) => row.kind === "turnSummary");
  expect(assistants(view.slice(0, summary)).at(-1)?.text).toMatch(/^Step 17 found/);
  expect(view[summary]?.folded).toBe(false);
});

test("the same turn in a Codex chat folds all its work and chatter under one Worked for", async () => {
  const rows = await replayRows();
  const view = turnView(rows, new Set(), { now: history.at(-1).at + 60_000, liveRuns: true, agentFamily: "codex" });
  expect(view.filter((row) => row.kind === WORKED)).toHaveLength(1);
  expect(view.some((row) => row.kind === "activity" && !row.merged)).toBe(false);
  expect(assistants(view).map(longAt)).toEqual([17]);
  expect(view.find((row) => row.kind === "turnSummary")?.folded).toBe(true);
});

/// A turn steered once: two runs and a note, a reply, a run, the steer, then a note between two runs.
function steered() {
  let at = Date.UTC(2026, 10, 1, 9, 0, 0);
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 10_000),
    ...extra,
  });
  const run = (id: string) =>
    row(id, "activity", {
      items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }],
    });
  return [
    row("u", "user", { text: "Look at the fleet" }),
    run("b1"),
    row("n1", "assistant", { text: "Checking the minis." }),
    run("b2"),
    row("r1", "assistant", { text: "The minis are fine." }),
    run("b3"),
    row("s1", "user", { text: "and the runners", steer: "landed" }),
    run("b4"),
    row("n2", "assistant", { text: "Now the runners." }),
    run("b5"),
    row("answer", "assistant", { text: "All of them are healthy." }),
    row("sum", "turnSummary", { status: "completed" }),
  ];
}

test("a steered Claude turn keeps the steer and the reply before it in sight, each run on its own line", () => {
  const view = turnView(steered(), new Set(), {
    now: Date.UTC(2026, 10, 1, 10),
    liveRuns: true,
    agentFamily: "claude",
  });
  expect(view.map((row) => row.id)).toEqual(["u", "b1", "r1", "b3", "s1", "b4", "answer", "sum"]);
  // The notes inside a run draw as its quiet lines; the reply before the steer is never one.
  const notes = (id: string) =>
    (view.find((row) => row.id === id)?.items ?? []).filter((item) => item.kind === "note").map((item) => item.text);
  expect(notes("b1")).toEqual(["Checking the minis."]);
  expect(notes("b4")).toEqual(["Now the runners."]);
  expect(notes("b3")).toEqual([]);
});

test("a steered Codex turn still folds everything but the steer, the reply before it and the answer", () => {
  const view = turnView(steered(), new Set(), { now: Date.UTC(2026, 10, 1, 10), liveRuns: true, agentFamily: "codex" });
  expect(view.map((row) => row.id)).toEqual(["u", `${WORKED}-u`, "r1", "s1", "answer", "sum"]);
});
