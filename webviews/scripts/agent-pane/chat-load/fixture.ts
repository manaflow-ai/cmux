// l10n-allow-file: a benchmark fixture writer, never shown to a user.
// Chat-load benchmark fixtures (perf100): acpmux homes whose sessions hold N finished turns of
// the load fixture (src/agent-session/acpmux/loadFixture.ts: Markdown, a read, every 3rd turn a
// large edit, every 5th a long shell log), written as acpmux writes its logs
// (`sessions/<id>/session.json` + `events/NNNNNN.ndjson`, 8 MiB segments). Deterministic: the same
// arguments write the same bytes (timestamps come from a fixed base).
//
//   bun scripts/agent-pane/chat-load/fixture.ts --home DIR [--turns 100,1000,10000] [--noise 0]
//       [--huge 0] [--harness fc]
//
// --noise K adds K non-transcript records per turn shaped like a Claude stream's raw events
// (`claude.stream_event`, ~420 B), as a Chief log holds; the pane's attach filters them out.
// --huge N adds one session of N turns whose every turn carries a 5,000-line shell log.
// Prints one JSON line: {sessions: [{id, turns, records, bytes, lastMarker}]}.
import fs from "node:fs";
import path from "node:path";
import { loadTurn, type LoadStep } from "../../../src/agent-session/acpmux/loadFixture";

const arg = (name: string, fallback?: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const home = arg("home");
if (!home) throw new Error("--home is required");
const sizes = (arg("turns", "100,1000,10000") ?? "")
  .split(",")
  .filter(Boolean)
  .map((value) => Number(value));
const noise = Number(arg("noise", "0"));
const huge = Number(arg("huge", "0"));
const harness = arg("harness", "fc")!;
const SEGMENT = 8 * 1024 * 1024;
const BASE = 1_791_000_000_000;

/// A UUIDv7 for `ms` with deterministic random bits.
function uuid7(ms: number, salt: number): string {
  const hex = (value: number, width: number) => value.toString(16).padStart(width, "0").slice(-width);
  const time = hex(ms, 12);
  const a = hex((salt * 2654435761) >>> 0, 8);
  const b = hex((salt * 40503 + 7) >>> 0, 8);
  return `${time.slice(0, 8)}-${time.slice(8)}-7${a.slice(0, 3)}-${(8 + (salt % 4)).toString(16)}${a.slice(3, 6)}-${b}${a.slice(6, 8)}${hex(salt, 2)}`;
}

function writeSession(index: number, turns: number, title: string, opts: { logLines?: number } = {}) {
  const createdAt = BASE + index * 3_600_000;
  const id = uuid7(createdAt, index + 1);
  const dir = path.join(home!, "sessions", id);
  const events = path.join(dir, "events");
  fs.mkdirSync(events, { recursive: true, mode: 0o700 });
  let seq = 0;
  let segment = 1;
  let segmentBytes = 0;
  let total = 0;
  let fd = fs.openSync(path.join(events, `${String(segment).padStart(6, "0")}.ndjson`), "w", 0o600);
  let chunks: string[] = [];
  let pending = 0;
  const flush = () => {
    if (chunks.length) fs.writeSync(fd, chunks.join(""));
    chunks = [];
    pending = 0;
  };
  const write = (dirName: string, kind: string, msg: unknown, at: number) => {
    seq += 1;
    const line = `${JSON.stringify({ seq, at, dir: dirName, kind, msg })}\n`;
    if (segmentBytes >= SEGMENT) {
      flush();
      fs.closeSync(fd);
      segment += 1;
      fd = fs.openSync(path.join(events, `${String(segment).padStart(6, "0")}.ndjson`), "w", 0o600);
      segmentBytes = 0;
    }
    chunks.push(line);
    pending += line.length;
    segmentBytes += line.length;
    total += line.length;
    if (pending > 1 << 20) flush();
  };
  const record = (step: LoadStep, at: number, turn: number) => {
    if ("update" in step)
      write(
        "in",
        String(step.update.sessionUpdate),
        { jsonrpc: "2.0", method: "session/update", params: { sessionId: `agent-${id}`, update: step.update } },
        at,
      );
    else if (step.mux === "user_message") write("mux", "user_message", { ...step.msg, promptId: `p-${turn}` }, at);
    else if (step.mux === "turn_started")
      write("mux", "turn_started", { turnId: `t-${turn}`, promptId: `p-${turn}` }, at);
    else if (step.mux === "turn_result")
      write(
        "mux",
        "turn_result",
        { ...step.msg, stopReason: "end_turn", turnId: `t-${turn}`, promptId: `p-${turn}` },
        at,
      );
    else write("mux", step.mux, step.msg ?? {}, at);
  };
  // An agent lists its slash commands once, when it starts: the log's first record.
  const commands = {
    sessionUpdate: "available_commands_update",
    availableCommands: ["compact", "review", "init"].map((name) => ({ name, description: `Run /${name}` })),
  };
  record({ update: commands }, createdAt - 1, 0);
  for (let turn = 0; turn < turns; turn += 1) {
    const at = createdAt + turn * 60_000;
    const steps = loadTurn(turn, opts);
    steps.forEach((step, stepIndex) => {
      record(step, at + stepIndex, turn);
      for (let k = 0; k < noise && "update" in step; k += 1)
        write(
          "in",
          "claude.stream_event",
          {
            type: "stream_event",
            event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: `w${turn}.${k} ` } },
            session_id: "s",
            uuid: "0".repeat(36),
            parent_tool_use_id: null,
            pad: "y".repeat(250),
          },
          at + stepIndex,
        );
    });
  }
  flush();
  fs.closeSync(fd);
  const updatedAt = createdAt + turns * 60_000;
  const meta = {
    schema: "acpmux.session.v1",
    id,
    name: title,
    harness,
    harnessArgv: ["false"],
    cwd: "/tmp",
    agentSessionId: `agent-${id}`,
    status: "closed",
    createdAt,
    updatedAt,
    lastSeq: seq,
    eventCount: seq,
    turnCount: turns,
    title,
    lastPrompt: `Turn ${turns - 1}: why does step ${turns - 1} let values past the limit through?`,
    preview: `Done with turn ${turns - 1}`,
    // acpmux keeps the newest command list in the session (an acpmux before it ignores this).
    availableCommands: commands,
  };
  fs.writeFileSync(path.join(dir, "session.json"), JSON.stringify(meta, null, 2), { mode: 0o600 });
  return { id, turns, records: seq, bytes: total, lastMarker: `Done with turn ${turns - 1}`, title };
}

fs.mkdirSync(path.join(home, "sessions"), { recursive: true, mode: 0o700 });
const sessions = sizes.map((turns, index) => writeSession(index, turns, `Load ${turns} turns`));
if (huge > 0) sessions.push(writeSession(sizes.length, huge, `Load ${huge} turns, huge output`, { logLines: 5000 }));
console.log(JSON.stringify({ home, noise, sessions }));
