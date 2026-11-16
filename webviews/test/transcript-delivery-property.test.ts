// l10n-allow-file: generated agent chats for a property test, not shipped UI.
// cmux-web-test-timeout: 240
// The transcript's event apply converges whatever the delivery (bench/stateGrowth.ts's fake daemon and clock): a
// session's records delivered live with duplicates, neighbours swapped, frames lost and a reconnect in the middle
// draw the same rows as the same records delivered once, in order, once each turn has ended and the pane read back
// what it missed. Seeded random cases (the repo has no direct fast-check dependency): a failure prints its seed and
// the delivery, and PROPERTY_SEED=N PROPERTY_CASES=1 replays it.
import { afterEach, expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { prng } from "../bench/godFixture";
import { connectClient, FakeDaemon, logFor, retainedEntries, VirtualClock } from "../bench/stateGrowth";

const SESSION = "prop-chat";
const CASES = Number(process.env.PROPERTY_CASES ?? 24);
const FIRST_SEED = Number(process.env.PROPERTY_SEED ?? 1);
let clock: VirtualClock | undefined;
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

/// What a row draws, without the fields a delivery's timing sets (when it arrived, its render version).
function drawn(rows: readonly AcpmuxRow[]): unknown {
  const strip = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(strip);
    if (!value || typeof value !== "object") return value;
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value))
      if (!/^(version|at|.*At|receivedAt|startedAt|endedAt|elapsedMs|durationMs)$/.test(key)) out[key] = strip(item);
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

async function play(events: EventRecord[], deliver: (daemon: FakeDaemon) => Promise<void>) {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  // The chat starts with its first turn stored, so the pane opens on a transcript and the rest comes live.
  const firstTurn = events.findIndex((event) => event.kind === "turn_result") + 1;
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "running", updatedAt: clock.now },
    events.slice(0, firstTurn),
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

// One fault kind at a time over the same seeds. Duplicates and a dropped socket converge alone and stay held to it;
// a lost record, and a swap (its later record is dropped as stale, so a loss too), still diverge until
// manaflow-ai/cmuxterm-hq#8950 is fixed.
for (const kind of ["dup", "drop"] as const)
  test(`${kind} alone converges to the in-order rows`, async () => {
    expect(await convergence([kind])).toEqual([]);
  });
for (const kind of ["swap", "lose"] as const)
  test(`${kind} alone still diverges only as manaflow-ai/cmuxterm-hq#8950 says`, async () => {
    stillKnown(await convergence([kind]), `${kind} alone`);
  });
