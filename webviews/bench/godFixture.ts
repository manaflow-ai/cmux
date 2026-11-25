// l10n-allow-file: generated agent chats for a bench, not shipped UI.
// The god session: one generated acpmux session log at the size a heavy user's oldest chat reaches, for every lag
// bench to run beside its ordinary chat (Leo, 2026-11-10: "to load in my God sessions, it needs to be the exact same,
// or close enough to the exact same as the small sessions"). Same type and seq keys as replayLogs.ts's logs (checkSeq
// holds), so transcript-replay.bench.ts plays it and parseLog reads it back from JSON lines.
//   small  an ordinary chat: 300 turns over one working day, one subagent two deep, one image, no MB output
//   god    tens of thousands of transcript rows (7,000 turns), four tool outputs of 1 to 4 MB, a subagent chain five
//          deep every 800 turns (acpmux's model: `subagent_spawned` / `subagent_state_update` with
//          `_meta.acpmux.subagents` {id, parent}, the child's own updates tagged `_meta.acpmux.subagent`; Rust:
//          cmux-tui/crates/acpmux/src/subagents.rs, claude_stdio/inbound.rs spawn_subagent), a screenshot (an ACP
//          `image` block in a Read's result) every 250 turns, and about four months of history with weekends and longer
//          gaps off.
// Both have streamed checkpoints (replayLogs.ts streamedTurn: thought, reply tokens, a shell call's output, reads) at
// the fifths of the log, so transcript-replay measures work per token at god scale too. Deterministic: one seeded PRNG,
// no clock read, so two runs make the same bytes.
// Benches pick it with FIXTURE=god (env, since chat-open and chat-switch take positional args); each PERF_ROW then
// gets a `god` segment after the bench's prefix (chat_open.compact.latest -> chat_open.god.compact.latest), so a row
// pairs with its small twin by dropping `.god`. FIXTURE unset (or small) changes nothing a bench measured before.
//   bun bench/godFixture.ts [--scale god|small] [--out FILE.jsonl]   writes JSON lines that `transcript-replay --log`
//                                                                     reads; prints records, rows and bytes
import { deflateSync } from "node:zlib";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { loadTurn, sourceFile } from "../src/agent-session/acpmux/loadFixture";
import type { PerfRow } from "./perfRow";
import { checkSeq, rowsIn, streamedTurn, toRecord, type Burst, type ReplayLog, type Step } from "./replayLogs";

export type Scale = "small" | "god";
export const SCALES: readonly Scale[] = ["small", "god"];

/// The newest reply of every generated log starts with this, once: what a bench waits for to call the chat painted.
export const LATEST_TEXT = "Answer final:";

export type GodOptions = {
  /// Finished turns before the last one.
  turns?: number;
  /// Calendar days the history spans (the first turn that many days before the last).
  days?: number;
  /// Sizes in MB of the tool outputs that big (a full test log, a dumped table): each is one shell call's result.
  mbOutputs?: number[];
  /// How deep each subagent chain goes (1: the chat's own subagent only).
  depth?: number;
  /// A subagent chain every this many turns.
  chainEvery?: number;
  /// A Read of a screenshot (an ACP image block) every this many turns.
  imageEvery?: number;
  /// Turn indices of the streamed checkpoints; default the log's fifths.
  checkpoints?: number[];
  /// The PRNG seed: another seed, another log of the same shape.
  seed?: number;
};

const PRESETS: Record<Scale, Required<Omit<GodOptions, "checkpoints">>> = {
  small: { turns: 300, days: 1, mbOutputs: [], depth: 2, chainEvery: 1000, imageEvery: 1000, seed: 1 },
  god: { turns: 7000, days: 120, mbOutputs: [1, 2, 3, 4], depth: 5, chainEvery: 800, imageEvery: 250, seed: 1 },
};

/// mulberry32: a small seeded PRNG, [0, 1).
export function prng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------- images ----------
const CRC = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (bytes: Uint8Array) => {
  let c = 0xffffffff;
  for (const byte of bytes) c = CRC[(c ^ byte) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type: string, data: Uint8Array) => {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
};

/// A valid `size`x`size` RGB PNG, as base64: a two-tone chart-like picture whose colours follow `index` (pure).
export function pngBase64(index: number, size = 24): string {
  const header = new Uint8Array(13);
  const view = new DataView(header.buffer);
  view.setUint32(0, size);
  view.setUint32(4, size);
  header.set([8, 2, 0, 0, 0], 8); // 8-bit RGB, no interlace
  const raw = new Uint8Array(size * (1 + size * 3));
  for (let y = 0; y < size; y++) {
    const row = y * (1 + size * 3);
    for (let x = 0; x < size; x++) {
      const bar = (x * 7 + index * 13) % size > size - y;
      const at = row + 1 + x * 3;
      raw.set(bar ? [(index * 53) % 256, 120, 200] : [245, 245, (index * 29) % 256], at);
    }
  }
  const parts = [
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", new Uint8Array(deflateSync(raw))),
    chunk("IEND", new Uint8Array()),
  ];
  return Buffer.concat(parts).toString("base64");
}

// ---------- the log ----------
const text = (value: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: value } });
const output = (value: string) => [{ type: "content", content: { type: "text", text: value } }];

/// A shell log of about `bytes` bytes, each line different (pure).
export function bigOutput(turn: number, bytes: number): string {
  const lines: string[] = [];
  let size = 0;
  for (let index = 0; size < bytes; index++) {
    const line =
      index % 40 === 39
        ? `FAIL src/feature${(turn + index) % 40}/case${index}.test.ts > retries the request ${index % 7} times`
        : `✓ turn ${turn} case ${index} keeps the ${["cache", "queue", "layout", "parser"][index % 4]} stable [${(index % 97) / 10}ms]`;
    lines.push(line);
    size += line.length + 1;
  }
  return lines.join("\n");
}

/// When each turn starts (pure): `turns` turns over `days` calendar days ending at `end`, on working days only,
/// with weekends and a few longer gaps (a holiday, a week on something else) off, a few minutes apart within a day.
export function turnTimes(turns: number, days: number, end: number, random: () => number): number[] {
  const DAY = 86_400_000;
  const firstDay = Math.floor(end / DAY) - days;
  const active: number[] = [];
  for (let day = firstDay; day <= firstDay + days; day++) {
    const weekday = new Date(day * DAY).getUTCDay();
    if (weekday === 0 || weekday === 6) continue;
    // A gap of days off now and then: ten days away about every two months.
    if (days > 30 && day - firstDay > 20 && (day - firstDay) % 60 < 10) continue;
    if (days > 7 && random() < 0.1) continue;
    active.push(day);
  }
  if (!active.length) active.push(firstDay);
  const perDay = Math.ceil(turns / active.length);
  const times: number[] = [];
  let clock = 0;
  for (let turn = 0; turn < turns; turn++) {
    const day = active[Math.min(active.length - 1, Math.floor(turn / perDay))]!;
    // From 08:00, three to five minutes a turn, so a full day ends before midnight with room for its streams.
    clock = turn % perDay === 0 ? day * DAY + 8 * 3_600_000 : clock + (3 + Math.floor(random() * 3)) * 60_000;
    times.push(clock);
  }
  return times;
}

type Push = (at: number, step: Step) => void;

/// A subagent chain `depth` deep, as acpmux records it in the parent chat's log: each level's spawn (tagged with its
/// parent subagent when it has one), its Agent call, a read and a line of its own, then each ends, innermost first,
/// its Agent call completing with its report.
function pushChain(push: Push, sessionId: string, turn: number, at: number, depth: number) {
  const ids = Array.from({ length: depth }, (_, level) => `toolu_god_${turn}_${level + 1}`);
  const child = (level: number) => `${sessionId}/${ids[level]}`;
  const tagged = (level: number, extra: Record<string, unknown> = {}) =>
    level === 0 ? { acpmux: extra } : { acpmux: { subagent: child(level - 1), ...extra } };
  let clock = at;
  for (let level = 0; level < depth; level++) {
    const task = level === 0 ? `Audit turn ${turn}'s failing suites` : `Dig into layer ${level + 1} of turn ${turn}`;
    const prompt = `Find why the suite of turn ${turn} fails at layer ${level + 1}; report the cause and the fix.`;
    const id = child(level);
    const parent = level === 0 ? null : child(level - 1);
    push((clock += 50), {
      update: {
        sessionUpdate: "subagent_spawned",
        subagentSessionId: id,
        name: `layer-${level + 1}`,
        task,
        prompt,
        capabilities: {},
        _meta: { claude: { subagentType: "general-purpose", toolUseId: ids[level] } },
      },
      meta: tagged(level, {
        subagents: [{ id, parent, name: `layer-${level + 1}`, task, state: "running", toolCallId: ids[level] }],
      }),
    });
    push((clock += 10), {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: ids[level],
        kind: "think",
        title: task,
        status: "in_progress",
        rawInput: { description: task, prompt, subagent_type: "general-purpose" },
        _meta: { claudeCode: { toolName: "Agent" } },
      },
      ...(level === 0 ? {} : { meta: tagged(level) }),
    });
    const read = `god-sub-read-${turn}-${level}`;
    push((clock += 200), {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: read,
        kind: "read",
        title: `Read src/feature${(turn + level) % 40}/layer${level}.ts`,
        status: "completed",
        locations: [{ path: `/mock/project/src/feature${(turn + level) % 40}/layer${level}.ts` }],
        content: output(sourceFile(turn * 10 + level, 30)),
      },
      meta: { acpmux: { subagent: id } },
    });
    push((clock += 100), {
      update: text(`Layer ${level + 1}: the guard reads the stale total; going one level down.`),
      meta: { acpmux: { subagent: id } },
    });
  }
  for (let level = depth - 1; level >= 0; level--) {
    const id = child(level);
    const parent = level === 0 ? null : child(level - 1);
    const report = `Layer ${level + 1} of turn ${turn}: the cause is the stale total; the fix moves the guard first.`;
    push((clock += 300), {
      update: {
        sessionUpdate: "tool_call_update",
        toolCallId: ids[level],
        status: "completed",
        content: output(report),
      },
      ...(level === 0 ? {} : { meta: tagged(level) }),
    });
    push((clock += 10), {
      update: { sessionUpdate: "subagent_state_update", subagentSessionId: id, state: "completed" },
      meta: tagged(level, { subagents: [{ id, parent, state: "completed", lastMessage: report }] }),
    });
  }
  return clock;
}

/// One ordinary turn (pure but for `random`): a prompt, a paragraph, a read or two, sometimes a short test run,
/// sometimes a screenshot read, an MB-sized output when `mb` is set, and a closing line.
function pushTurn(
  push: Push,
  turn: number,
  at: number,
  random: () => number,
  extra: { image: boolean; mb?: number },
): number {
  let clock = at;
  push(clock, {
    mux: "user_message",
    msg: { text: `Turn ${turn}: why does step ${turn} still fail on the merged head?` },
  });
  push(clock, { mux: "turn_started" });
  push((clock += 1500), {
    update: text(
      `Turn ${turn}: the guard in \`step${turn}\` runs after the total, so the ${turn % 2 ? "second" : "first"} ` +
        "pass lets a value past the ceiling through. Reading the module first.",
    ),
  });
  const reads = 1 + Math.floor(random() * 2);
  for (let read = 0; read < reads; read++) {
    const file = `src/feature${(turn + read) % 40}/step${turn}-${read}.ts`;
    push((clock += 400), {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `god-read-${turn}-${read}`,
        kind: "read",
        title: `Read ${file}`,
        status: "completed",
        locations: [{ path: `/mock/project/${file}` }],
        content: output(sourceFile(turn + read, 8 + Math.floor(random() * 16))),
      },
    });
  }
  if (extra.image)
    push((clock += 600), {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `god-shot-${turn}`,
        kind: "read",
        title: `Read screenshots/turn-${turn}.png`,
        status: "completed",
        locations: [{ path: `/mock/project/screenshots/turn-${turn}.png` }],
        content: [
          { type: "content", content: { type: "text", text: "" } },
          { type: "content", content: { type: "image", mimeType: "image/png", data: pngBase64(turn) } },
        ],
      },
    });
  if (extra.mb !== undefined || random() < 0.4) {
    const command = `bun test src/feature${turn % 40}`;
    push((clock += 2000), {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `god-test-${turn}`,
        kind: "execute",
        title: `Run ${command}`,
        status: "completed",
        rawInput: { command },
        rawOutput: { exit_code: extra.mb === undefined ? 0 : 1 },
        content: output(
          extra.mb === undefined
            ? bigOutput(turn, 400 + Math.floor(random() * 1200))
            : bigOutput(turn, Math.round(extra.mb * 2 ** 20)),
        ),
      },
    });
  }
  push((clock += 1000), { update: text(`\n\nTurn ${turn} done: the guard now runs first, and the suite passes.`) });
  push(clock, { mux: "turn_result", msg: { status: "completed" } });
  return clock;
}

/// The generated log at `scale` (pure, deterministic): see the header. `opts` overrides the preset's numbers.
export function godLog(scale: Scale, opts: GodOptions = {}): ReplayLog {
  const o = { ...PRESETS[scale], ...opts };
  const random = prng(o.seed);
  const sessionId = `replay-${scale}`;
  const end = Date.UTC(2026, 10, 6, 17, 0, 0);
  const times = turnTimes(o.turns, o.days, end, random);
  const checkpoints = new Set(
    o.checkpoints ?? [2, ...[1, 2, 3, 4].map((fifth) => Math.floor((o.turns * fifth) / 5)), o.turns - 1],
  );
  // The MB outputs spread through the log, away from the checkpoints.
  const mbAt = new Map(
    o.mbOutputs.map((mb, index) => [Math.floor((o.turns * (index * 2 + 1)) / (o.mbOutputs.length * 2 + 1)) + 7, mb]),
  );
  const events: EventRecord[] = [];
  const bursts: Burst[] = [];
  const push: Push = (at, step) => {
    // Never back in time: a turn's own steps can run past the next turn's planned start.
    const last = events.at(-1)?.at ?? at;
    events.push(toRecord(sessionId, events.length + 1, Math.max(at, last), step));
  };
  for (let turn = 0; turn < o.turns; turn++) {
    const at = Math.max(times[turn]!, events.at(-1)?.at ?? 0);
    if (checkpoints.has(turn)) {
      streamedTurn(events, bursts, sessionId, turn, at);
      continue;
    }
    const chain = turn % o.chainEvery === o.chainEvery - 1 || (scale === "small" && turn === Math.floor(o.turns / 2));
    if (chain) {
      push(at, { mux: "user_message", msg: { text: `Turn ${turn}: send agents to find the root cause` } });
      push(at, { mux: "turn_started" });
      const clock = pushChain(push, sessionId, turn, at + 500, o.depth);
      push(clock + 500, { update: text(`Turn ${turn}: the agents agree: the guard runs after the total.`) });
      push(clock + 500, { mux: "turn_result", msg: { status: "completed" } });
      continue;
    }
    // Every 20th turn a heavy one (loadFixture.ts): a large edit diff, a long shell log, a closing code block.
    if (turn % 20 === 10 && !mbAt.has(turn)) {
      for (const step of loadTurn(turn)) push(at, step as Step);
      continue;
    }
    const image = turn % o.imageEvery === o.imageEvery - 3 || (scale === "small" && turn === Math.floor(o.turns / 3));
    pushTurn(push, turn, at, random, { image, mb: mbAt.get(turn) });
  }
  const last = (events.at(-1)?.at ?? end) + 60_000;
  push(last, { mux: "user_message", msg: { text: "Where does it stand?" } });
  push(last, { mux: "turn_started" });
  push(last + 2000, { update: text(`${LATEST_TEXT} every check on the merged head is green.`) });
  push(last + 2000, { mux: "turn_result", msg: { status: "completed" } });
  const log: ReplayLog = {
    name: scale,
    sessionId,
    summary: {
      sessionId,
      cwd: "/mock/project",
      title:
        scale === "god" ? `God session: ${o.turns} turns over ${o.days} days` : `Ordinary session: ${o.turns} turns`,
      harness: "claude",
      name: "claude",
      createdAt: events[0]!.at,
      updatedAt: events.at(-1)!.at,
    },
    events,
    bursts,
  };
  checkSeq(log);
  return log;
}

/// One record as the chat benches' stand-in daemons hold it (test/support/papercutChat.ts's shape).
export type ChatEvent = {
  sessionId: string;
  seq: number;
  at: number;
  dir: string;
  kind: string;
  msg: Record<string, unknown>;
};

/// The god session as the chat benches' stand-in acpmux holds it: its records under `sessionId` and the summary
/// `_acpmux/watch` and `attach` report (`fields` added), as papercutEvents returns a chat. Its newest reply starts
/// with LATEST_TEXT.
export function godChat(sessionId: string, fields: Record<string, unknown> = {}) {
  const log = godLog("god");
  const events: ChatEvent[] = log.events.map((event) => ({
    sessionId,
    seq: event.seq,
    at: event.at,
    dir: event.dir,
    kind: event.kind,
    msg: event.msg as Record<string, unknown>,
  }));
  const session = {
    ...log.summary,
    sessionId,
    family: "claude",
    status: "ready",
    turnCount: events.filter((event) => event.kind === "user_message").length,
    updatedAt: events.at(-1)!.at,
    lastSeq: events.length,
    ...fields,
  };
  return { events, session };
}

/// How deep the log's subagents nest (pure): the longest parent chain in its `_meta.acpmux.subagents`.
export function subagentDepth(events: readonly EventRecord[]): number {
  const parents = new Map<string, string | null>();
  for (const event of events) {
    const subagents = (event.msg as { params?: { _meta?: { acpmux?: { subagents?: unknown } } } }).params?._meta?.acpmux
      ?.subagents;
    if (!Array.isArray(subagents)) continue;
    for (const each of subagents as { id?: unknown; parent?: unknown }[])
      if (typeof each.id === "string" && !parents.has(each.id))
        parents.set(each.id, typeof each.parent === "string" ? each.parent : null);
  }
  let deepest = 0;
  for (const id of parents.keys()) {
    let depth = 0;
    for (let at: string | null | undefined = id; at && depth <= parents.size; at = parents.get(at)) depth++;
    deepest = Math.max(deepest, depth);
  }
  return deepest;
}

/// The log as JSON lines, one record each: what parseLog and `transcript-replay --log` read.
export function toJsonLines(log: ReplayLog): string {
  return log.events.map((event) => JSON.stringify(event)).join("\n") + "\n";
}

/// The fixture a bench runs on, from FIXTURE (unset: small). Throws on any other value.
export function benchFixture(env: Record<string, string | undefined> = process.env): Scale {
  const value = env.FIXTURE ?? "small";
  if (!(SCALES as readonly string[]).includes(value)) throw new Error(`FIXTURE must be small or god, not ${value}`);
  return value as Scale;
}

/// A row's name at `scale` (pure): small keeps it; god puts `god` after the bench's prefix, its first segment.
export function scaledRowName(name: string, scale: Scale): string {
  if (scale === "small") return name;
  const dot = name.indexOf(".");
  return dot < 0 ? `${name}.god` : `${name.slice(0, dot)}.god${name.slice(dot)}`;
}

/// `print` (perfRow) with each row renamed for `scale`.
export function scaledPerfRow(print: (row: PerfRow) => void, scale: Scale): (row: PerfRow) => void {
  return (row) => print({ ...row, name: scaledRowName(row.name, scale) });
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const flag = (name: string) => {
    const at = argv.indexOf(name);
    return at >= 0 ? argv[at + 1] : undefined;
  };
  const scale = (flag("--scale") ?? "god") as Scale;
  if (!SCALES.includes(scale)) {
    console.error("usage: bun bench/godFixture.ts [--scale god|small] [--out FILE.jsonl]");
    process.exit(2);
  }
  const started = performance.now();
  const log = godLog(scale);
  const lines = toJsonLines(log);
  const out = flag("--out");
  if (out) await Bun.write(out, lines);
  const big = log.events.filter((event) => JSON.stringify(event).length > 2 ** 20).length;
  const first = new Date(log.events[0]!.at).toISOString().slice(0, 10);
  const last = new Date(log.events.at(-1)!.at).toISOString().slice(0, 10);
  console.log(
    `godFixture: ${scale}: ${log.events.length} records, ${rowsIn(log.events)} rows, ` +
      `${(Buffer.byteLength(lines) / 2 ** 20).toFixed(1)} MB, ${big} records over 1 MB, subagents ${subagentDepth(log.events)} deep, ` +
      `${first} to ${last}, ${log.bursts.length} bursts, made in ${((performance.now() - started) / 1000).toFixed(1)} s` +
      (out ? `, written to ${out}` : ""),
  );
}
