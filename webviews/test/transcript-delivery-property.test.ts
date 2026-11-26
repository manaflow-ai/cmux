// l10n-allow-file: generated agent chats for a property test, not shipped UI.
// cmux-web-test-timeout: 240
// The transcript's event apply converges whatever the delivery (bench/stateGrowth.ts's fake daemon and clock): a
// session's records delivered live with duplicates, neighbours swapped, frames lost and a reconnect in the middle
// draw the same rows as the same records delivered once, in order, once each turn has ended and the pane read back
// what it missed. Seeded random cases (the repo has no direct fast-check dependency): a failure prints its seed and
// the delivery, and PROPERTY_SEED=N PROPERTY_CASES=1 replays it.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { prng } from "../bench/godFixture";
import { connectClient, FakeDaemon, logFor, rekey, retainedEntries, VirtualClock } from "../bench/stateGrowth";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";

const SESSION = "prop-chat";
const CASES = Number(process.env.PROPERTY_CASES ?? 24);
const FIRST_SEED = Number(process.env.PROPERTY_SEED ?? 1);
let clock: VirtualClock | undefined;
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

/// What a row draws, without the fields a delivery's timing sets (when it arrived, its render version, and
/// `readAtOpen`: what of a running turn had arrived when the chat was first drawn).
function drawn(rows: readonly AcpmuxRow[]): unknown {
  const strip = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(strip);
    if (!value || typeof value !== "object") return value;
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value))
      if (!/^(version|at|.*At|receivedAt|startedAt|endedAt|elapsedMs|durationMs|readAtOpen)$/.test(key))
        out[key] = strip(item);
    return out;
  };
  return rows.map(strip);
}

type Delivery = { events: EventRecord[]; lost: Set<number>; dropAt?: number; log: string[] };

type Kind = "lose" | "swap" | "dup" | "drop";
const KINDS: readonly Kind[] = ["lose", "swap", "dup", "drop"];

/// A random delivery of `events`: each record may be lost, sent twice (the copy later), or swapped with the next
/// one; the socket may drop once. Every turn's `turn_result` arrives (the pane repairs a turn when it ends), and the
/// last record is the last one sent, so the whole log is owed back once the clock settles. `kinds` limits the faults
/// to some kinds (a failing case is tried again with each kind alone).
function perturb(events: EventRecord[], seed: number, kinds: readonly Kind[] = KINDS): Delivery {
  const random = prng(seed);
  const on = (kind: Kind) => kinds.includes(kind);
  const out: EventRecord[] = [];
  const lost = new Set<number>();
  const later: EventRecord[] = [];
  const log: string[] = [];
  for (let index = 0; index < events.length; index++) {
    const event = events[index]!;
    const final = index === events.length - 1;
    const ends = event.kind === "turn_result";
    const roll = random();
    if (!final && !ends && roll < 0.08 && on("lose")) {
      lost.add(event.seq);
      log.push(`lose ${event.seq}`);
      continue;
    }
    if (!final && !ends && roll >= 0.08 && roll < 0.16 && index + 1 < events.length - 1 && on("swap")) {
      out.push(events[index + 1]!, event);
      log.push(`swap ${event.seq}<>${events[index + 1]!.seq}`);
      index += 1;
      continue;
    }
    out.push(event);
    if (roll > 0.9 && on("dup")) {
      later.push(event);
      log.push(`dup ${event.seq}`);
    }
    if (later.length && random() < 0.3) out.push(later.shift()!);
  }
  out.splice(out.length - 1, 0, ...later);
  const dropRoll = random();
  const dropSpot = Math.floor(random() * out.length * 0.8);
  const dropAt = dropRoll < 0.5 && on("drop") ? dropSpot : undefined;
  if (dropAt !== undefined) log.push(`drop at ${dropAt}`);
  return { events: out, lost, dropAt, log };
}

async function play(
  events: EventRecord[],
  deliver: (daemon: FakeDaemon) => Promise<void>,
  stored = events.slice(0, events.findIndex((event) => event.kind === "turn_result") + 1),
) {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  // The chat starts with its first turn stored, so the pane opens on a transcript and the rest comes live.
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "running", updatedAt: clock.now },
    [...stored],
  );
  const { client, rows } = await connectClient(daemon, SESSION, clock);
  await deliver(daemon);
  // Long enough for every repair read and its retries, and the reconnect's backoff.
  await clock.advance(120_000);
  const result = { rows: drawn(rows()), client, daemon };
  return result;
}

const events = logFor(SESSION, "small", {
  turns: 8,
  checkpoints: [3, 6],
  depth: 3,
  chainEvery: 4,
  imageEvery: 5,
}).events;
const firstTurn = events.findIndex((event) => event.kind === "turn_result") + 1;
const live = events.slice(firstTurn);

test("in-order live delivery draws what the stored log draws", async () => {
  const inOrder = await play(events, async (daemon) => {
    daemon.push(live);
    await clock!.advance(1000);
  });
  inOrder.client.close();
  clock!.uninstall();
  clock = undefined;
  // The same records stored before the pane opens draw the same rows.
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "running", updatedAt: clock.now },
    [...events],
  );
  const stored = await connectClient(daemon, SESSION, clock);
  // Attach reads the newest records; the rest page in as the reader scrolls up. Read all of them.
  const whole = stored.client.loadThrough(events[0]!.seq);
  await clock.advance(120_000);
  expect(await whole).toBe(true);
  const storedRows = drawn(stored.rows());
  stored.client.close();
  expect(JSON.stringify(storedRows)).toBe(JSON.stringify(inOrder.rows));
});

// The regression the convergence property found first: a turn's prompt (its first record) lost, or overtaken by its
// `turn_started` and dropped as stale, was never read back when the turn ended (the repair read from the first prompt
// or start it held), so the finished turn drew without its prompt.
test("a turn whose prompt never arrived, or came after its start, draws its prompt once it ends", async () => {
  const reference = await play(events, async (daemon) => {
    daemon.push(live);
    await clock!.advance(1000);
  });
  reference.client.close();
  clock!.uninstall();
  clock = undefined;
  const prompt = live.findIndex((event) => event.kind === "user_message");
  expect(prompt).toBeGreaterThanOrEqual(0);
  const lost: Delivery = { events: live, lost: new Set([live[prompt]!.seq]), log: ["lose the prompt"] };
  expect(await converge(lost, reference.rows)).toEqual([]);
  const order = [...live];
  [order[prompt], order[prompt + 1]] = [order[prompt + 1]!, order[prompt]!];
  const overtaken: Delivery = { events: order, lost: new Set(), log: ["the record after the prompt first"] };
  expect(await converge(overtaken, reference.rows)).toEqual([]);
});

/// The first row that differs, both sides cut short, for a failure message.
function firstDiff(got: unknown, want: unknown): string {
  const [a, b] = [got as unknown[], want as unknown[]];
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const [x, y] = [JSON.stringify(a[index]) ?? "none", JSON.stringify(b[index]) ?? "none"];
    if (x === y) continue;
    // Where the two first part, with some context: the row's id, then the field that differs.
    let at = 0;
    while (at < x.length && x[at] === y[at]) at++;
    const near = (text: string) => text.slice(Math.max(0, at - 80), at + 160);
    return `row ${index} of ${a.length} (want ${b.length}) ${x.slice(0, 60)}: got ...${near(x)} want ...${near(y)}`;
  }
  return "same";
}

/// Plays one perturbed delivery and reports what is wrong with the result ([] when it converged).
async function converge(delivery: Delivery, reference: unknown): Promise<string[]> {
  const result = await play(events, async (daemon) => {
    // The daemon logs every record; the connection sees the perturbed stream.
    for (const event of live) daemon.sessions.get(SESSION)!.history.push(event);
    for (let index = 0; index < delivery.events.length; index++) {
      if (index === delivery.dropAt) {
        daemon.drop();
        await clock!.advance(5_000);
      }
      const event = delivery.events[index]!;
      if (!delivery.lost.has(event.seq)) daemon.deliver(event);
      if (index % 7 === 0) await clock!.advance(16);
    }
  });
  const problems: string[] = [];
  const held = (result.client as unknown as { events: EventRecord[] }).events;
  const seqs = held.map((event) => event.seq);
  const unique = new Set(seqs).size === seqs.length;
  const ordered = seqs.every((seq, index) => index === 0 || seqs[index - 1]! < seq);
  if (!unique || !ordered)
    problems.push(`the held log is ${unique ? "" : "not unique "}${ordered ? "" : "not in order"}`);
  if (JSON.stringify(result.rows) !== JSON.stringify(reference)) problems.push(firstDiff(result.rows, reference));
  if (clock!.errors.length) problems.push(`a timer threw: ${clock!.errors.join("; ")}`);
  result.client.close();
  clock!.uninstall();
  clock = undefined;
  return problems;
}

/// The in-order rows, then every seed's delivery with `kinds` of fault: what is wrong with each seed that does not
/// converge, and which fault kind alone breaks it. A throw anywhere (setup, a timer, the client) fails the caller.
async function convergence(kinds: readonly Kind[]): Promise<string[]> {
  const reference = await play(events, async (daemon) => {
    daemon.push(live);
    await clock!.advance(1000);
  });
  reference.client.close();
  clock!.uninstall();
  clock = undefined;
  const failures: string[] = [];
  for (let seed = FIRST_SEED; seed < FIRST_SEED + CASES; seed++) {
    const delivery = perturb(live, seed, kinds);
    const problems = await converge(delivery, reference.rows);
    if (!problems.length) continue;
    // Which kind of fault alone breaks it: the same seed with one kind at a time.
    const alone: string[] = [];
    if (kinds.length > 1)
      for (const kind of kinds) {
        const single = perturb(live, seed, [kind]);
        const wrong = await converge(single, reference.rows);
        if (wrong.length) alone.push(`${kind} alone (${single.log.join(", ")}): ${wrong.join("; ")}`);
      }
    failures.push(
      `seed ${seed}: ${problems.join("; ")}\n  after ${delivery.log.join(", ") || "plain delivery"}` +
        (alone.length ? `\n  ${alone.join("\n  ")}` : ""),
    );
  }
  for (const failure of failures) console.log(failure);
  return failures;
}

/// A fault mix known not to converge yet (manaflow-ai/cmuxterm-hq#8950): it must still show rows that differ, and
/// nothing may throw on the way (a throw fails the test, never passes it as `test.failing` would). Once it converges
/// this fails, naming the change: make it a convergence test.
function stillKnown(failures: string[], what: string): void {
  if (failures.length === 0)
    throw new Error(`${what} now converge at every seed: manaflow-ai/cmuxterm-hq#8950 is fixed here, hold them to it`);
}

test("all faults together still diverge only as manaflow-ai/cmuxterm-hq#8950 says", async () => {
  stillKnown(await convergence(KINDS), "all faults together");
});

test("closing the shown chat frees its records and rows", async () => {
  const run = await play(events, async (daemon) => {
    daemon.push(live);
    await clock!.advance(1000);
  });
  const { client, daemon } = run;
  daemon.add({
    sessionId: "next-chat",
    cwd: "/home/dev/y",
    title: "y",
    harness: "claude",
    status: "idle",
    updatedAt: clock!.now,
  });
  daemon.purge(SESSION);
  await clock!.advance(5_000);
  const held = (client as unknown as { events: EventRecord[] }).events;
  expect(held.filter((event) => event.sessionId === SESSION)).toEqual([]);
  // No store still keys a record of the closed chat: its rows, tool calls and messages went with it.
  const sizes = retainedEntries(client);
  const rowsLeft = ["rows", "toolRows", "messageRows"].map((name) => sizes.get(name) ?? 0);
  expect(rowsLeft).toEqual([0, 0, 0]);
  client.close();
});

// One fault kind at a time over the same seeds. Duplicates, a dropped socket and a swap converge alone and stay
// held to it (a swap's late record takes its place among the held ones, `mergeLate`; it was dropped as stale and
// missing until its turn ended); a record lost and never sent again still diverges until
// manaflow-ai/cmuxterm-hq#8950 is fixed.
for (const kind of ["dup", "drop", "swap"] as const)
  test(`${kind} alone converges to the in-order rows`, async () => {
    expect(await convergence([kind])).toEqual([]);
  });
for (const kind of ["lose"] as const)
  test(`${kind} alone still diverges only as manaflow-ai/cmuxterm-hq#8950 says`, async () => {
    stillKnown(await convergence([kind]), `${kind} alone`);
  });

// ---------- a recorded chat through a faulty delivery ----------
// Leo, 2026-11-21: "you guys need to analyze simulated behaviour. we can do this without any real agent sessions,
// just simulated ones. ... you can even replay my transcript." acpmux has a seeded delivery simulation
// (`acpmux simulation`); this is the pane's side of it. A recorded chat (test/fixtures/chat-sim, sanitized by
// sim/sanitize.ts) is delivered live with every record arriving at least once but not as written: sent twice,
// late, shuffled with its neighbours, dropped and sent again later, or lost while the socket was down and read back
// on the reconnect. Once the clock settles the rows drawn are the rows in-order delivery draws.
//
// SIM_SEEDS seeds from SIM_SEED (300 from 1); a failure prints `seed N` with its delivery, and
// SIM_SEED=N SIM_SEEDS=1 replays it. Known reds, each checked by taking the code out of direct.ts:
// - `apply` without its "at or below the newest seq folded" dedupe: a record sent twice is held and drawn twice
//   (seed 1, "the held log has 129 before 128", 14 rows for 8);
// - `apply` dropping a late record instead of `mergeLate`: its words are missing (seed 1);
// - `keepSame` not comparing a background turn's line: a finish whose result came after the next prompt stays
//   "ended by a prompt" (seed 56).
const SIM_SEEDS = Number(process.env.SIM_SEEDS ?? 300);
const SIM_FIRST = Number(process.env.SIM_SEED ?? 1);
/// The most records a seed delivers live: the rest of the chat before them is stored when the pane opens.
const SIM_LIVE = 120;
/// The records stored before them that the pane opens on: a late record folds the held ones again, so the count
/// held is what a seed costs.
const SIM_STORED = 150;

const recorded = parseRecords(
  readFileSync(path.join(import.meta.dir, "fixtures/chat-sim/replay-lane-session.ndjson"), "utf8"),
)
  .sort((a, b) => a.seq - b.seq)
  .map((event) => rekey(event, SESSION));

/// Where a seed's live part may start: the chat's first record after each turn's end, and each `SIM_LIVE` records
/// on from it inside a long turn (a pane opened in the middle of a turn).
const simStarts: number[] = [];
for (let index = 0, since = SIM_LIVE; index < recorded.length - 8; index++, since++) {
  const afterTurn = index > 0 && recorded[index - 1]!.kind === "turn_result";
  if (index > 0 && (afterTurn || since >= SIM_LIVE)) {
    simStarts.push(index);
    since = 0;
  }
}

type SimDelivery = { order: EventRecord[]; dropAt?: number; log: string[] };

/// A seeded delivery of `live`: every record is sent, at its place or later, and some twice.
function faulty(live: EventRecord[], seed: number): SimDelivery {
  const random = prng(seed);
  const log: string[] = [];
  // Each sending has a place in line: the record's own, or one further on.
  const sends: { at: number; event: EventRecord }[] = [];
  for (let index = 0; index < live.length; index++) {
    const event = live[index]!;
    const roll = random();
    const far = 2 + Math.floor(random() * 30);
    if (roll < 0.05) {
      // Sent twice: the copy up to 30 places later.
      sends.push({ at: index, event }, { at: index + far + 0.5, event });
      log.push(`dup ${event.seq}+${far}`);
    } else if (roll < 0.1) {
      // Late: overtaken by the records after it.
      sends.push({ at: index + far + 0.5, event });
      log.push(`late ${event.seq}+${far}`);
    } else if (roll < 0.16) {
      // Shuffled with its neighbours: a place within three of its own.
      sends.push({ at: index + (random() - 0.5) * 6, event });
      log.push(`shuffle ${event.seq}`);
    } else if (roll < 0.2) {
      // Dropped, then sent again far later (and sometimes a second time).
      const again = 20 + Math.floor(random() * 60);
      sends.push({ at: index + again + 0.5, event });
      if (random() < 0.3) sends.push({ at: index + again + 3.5, event });
      log.push(`resend ${event.seq}+${again}`);
    } else sends.push({ at: index, event });
  }
  sends.sort((a, b) => a.at - b.at);
  // The socket drops once in half the seeds: what is sent while it is down is lost, and the reconnect reads it.
  const dropRoll = random();
  const dropSpot = Math.floor(random() * sends.length);
  const dropAt = dropRoll < 0.5 ? dropSpot : undefined;
  if (dropAt !== undefined) log.push(`socket drops at ${dropAt}`);
  return { order: sends.map((send) => send.event), dropAt, log };
}

/// The rows as the person sees them. A reply's id is the first of its chunks the pane held, so one whose first
/// chunk came late is made again under the earlier id and keeps drawing in the element it had (`frame`,
/// `adoptFrames`): the same words in the same place, so the frame is not compared.
/// The rows without what depends on when they came rather than what they are: `frame`, and
/// `readAtOpen` (direct.ts `noteReadWork` marks what had arrived when an open read the running turn,
/// which a shuffled delivery changes by design).
function shown(rows: unknown): unknown[] {
  return (rows as readonly AcpmuxRow[]).map((row) =>
    row.frame === undefined && row.readAtOpen === undefined ? row : { ...row, frame: undefined, readAtOpen: undefined },
  );
}

/// Plays one window of the recorded chat: `deliver` sends its live part.
async function playRecorded(start: number, end: number, delivery?: SimDelivery) {
  const live = recorded.slice(start, end);
  const result = await play(
    recorded,
    async (daemon) => {
      const history = daemon.sessions.get(SESSION)!.history;
      if (!delivery) {
        daemon.push(live);
        await clock!.advance(1000);
        return;
      }
      // acpmux writes its log in order whatever the connection does: a record is in the log before it, or any
      // record after it, is sent.
      let written = start;
      for (let index = 0; index < delivery.order.length; index++) {
        const event = delivery.order[index]!;
        while (written < end && recorded[written]!.seq <= event.seq) history.push(recorded[written++]!);
        if (index === delivery.dropAt) {
          daemon.drop();
          // Sent into the closed socket: lost. The reconnect's attach reads the log.
          for (let lost = index; lost < Math.min(index + 6, delivery.order.length); lost++)
            daemon.deliver(delivery.order[lost]!);
          await clock!.advance(5_000);
        }
        daemon.deliver(event);
        if (index % 7 === 0) await clock!.advance(16);
      }
    },
    recorded.slice(Math.max(0, start - SIM_STORED), start),
  );
  const problems: string[] = [];
  const held = (result.client as unknown as { events: EventRecord[] }).events;
  for (let index = 1; index < held.length; index++)
    if (held[index - 1]!.seq >= held[index]!.seq) {
      problems.push(`the held log has ${held[index - 1]!.seq} before ${held[index]!.seq}`);
      break;
    }
  if (clock!.errors.length) problems.push(`a timer threw: ${clock!.errors.join("; ")}`);
  result.client.close();
  clock!.uninstall();
  clock = undefined;
  return { rows: result.rows, problems };
}

test(`a recorded chat delivered shuffled, twice, late and resent draws the in-order transcript (${SIM_SEEDS} seeds)`, async () => {
  expect(simStarts.length).toBeGreaterThan(10);
  const references = new Map<number, unknown>();
  const failures: string[] = [];
  let faults = 0;
  for (let seed = SIM_FIRST; seed < SIM_FIRST + SIM_SEEDS; seed++) {
    const start = simStarts[seed % simStarts.length]!;
    const end = Math.min(recorded.length, start + SIM_LIVE);
    let reference = references.get(start);
    if (reference === undefined) {
      const inOrder = await playRecorded(start, end);
      expect(inOrder.problems).toEqual([]);
      references.set(start, (reference = shown(inOrder.rows)));
    }
    const delivery = faulty(recorded.slice(start, end), seed);
    faults += delivery.log.length;
    const got = await playRecorded(start, end, delivery);
    const problems = [...got.problems];
    if (JSON.stringify(shown(got.rows)) !== JSON.stringify(reference))
      problems.push(firstDiff(shown(got.rows), reference));
    if (problems.length)
      failures.push(
        `seed ${seed} (records ${recorded[start]!.seq}-${recorded[end - 1]!.seq}; SIM_SEED=${seed} SIM_SEEDS=1 replays it): ` +
          `${problems.join("; ")}\n  after ${delivery.log.join(", ") || "plain delivery"}`,
      );
  }
  for (const failure of failures.slice(0, 5)) console.log(failure);
  if (failures.length > 5)
    console.log(
      `and ${failures.length - 5} more seeds: ${failures
        .slice(5)
        .map((f) => f.split(" (")[0])
        .join(", ")}`,
    );
  // The faults are real: every seed's delivery differs from the log.
  expect(faults).toBeGreaterThan(SIM_SEEDS * 5);
  expect(failures.map((failure) => failure.split(" (")[0])).toEqual([]);
}, 120_000);
