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

/// A random delivery of `events`: each record may be lost, sent twice (the copy later), or swapped with the next
/// one; the socket may drop once. Every turn's `turn_result` arrives (the pane repairs a turn when it ends), and the
/// last record is the last one sent, so the whole log is owed back once the clock settles.
function perturb(events: EventRecord[], seed: number): Delivery {
  const random = prng(seed);
  const out: EventRecord[] = [];
  const lost = new Set<number>();
  const later: EventRecord[] = [];
  const log: string[] = [];
  for (let index = 0; index < events.length; index++) {
    const event = events[index]!;
    const final = index === events.length - 1;
    const ends = event.kind === "turn_result";
    const roll = random();
    if (!final && !ends && roll < 0.08) {
      lost.add(event.seq);
      log.push(`lose ${event.seq}`);
      continue;
    }
    if (!final && !ends && roll < 0.16 && index + 1 < events.length - 1) {
      out.push(events[index + 1]!, event);
      log.push(`swap ${event.seq}<>${events[index + 1]!.seq}`);
      index += 1;
      continue;
    }
    out.push(event);
    if (roll > 0.9) {
      later.push(event);
      log.push(`dup ${event.seq}`);
    }
    if (later.length && random() < 0.3) out.push(later.shift()!);
  }
  out.splice(out.length - 1, 0, ...later);
  const dropAt = random() < 0.5 ? Math.floor(random() * out.length * 0.8) : undefined;
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

const events = logFor(SESSION, "small", { turns: 8, checkpoints: [3, 6], depth: 3, chainEvery: 4, imageEvery: 5 }).events;
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
  // The same records stored before the pane opens (its attach reads all of them) draw the same rows.
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "running", updatedAt: clock.now },
    [...events],
  );
  const stored = await connectClient(daemon, SESSION, clock);
  await clock.advance(120_000);
  const storedRows = drawn(stored.rows());
  stored.client.close();
  expect(JSON.stringify(storedRows)).toBe(JSON.stringify(inOrder.rows));
});

test("duplicate, reordered, lost and reconnected deliveries converge to the in-order rows", async () => {
  const reference = await play(events, async (daemon) => {
    daemon.push(live);
    await clock!.advance(1000);
  });
  reference.client.close();
  clock!.uninstall();
  clock = undefined;
  const failures: string[] = [];
  for (let seed = FIRST_SEED; seed < FIRST_SEED + CASES; seed++) {
    const delivery = perturb(live, seed);
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
    const held = (result.client as unknown as { events: EventRecord[] }).events;
    const seqs = held.map((event) => event.seq);
    const unique = new Set(seqs).size === seqs.length;
    const ordered = seqs.every((seq, index) => index === 0 || seqs[index - 1]! < seq);
    if (!unique || !ordered)
      failures.push(`seed ${seed}: the held log is ${unique ? "" : "not unique "}${ordered ? "" : "not in order"}`);
    if (JSON.stringify(result.rows) !== JSON.stringify(reference.rows))
      failures.push(`seed ${seed}: rows differ after ${delivery.log.join(", ") || "plain delivery"}`);
    result.client.close();
    clock!.uninstall();
    clock = undefined;
  }
  expect(failures).toEqual([]);
});

test("closing the shown chat frees its records and rows", async () => {
  const run = await play(events, async (daemon) => {
    daemon.push(live);
    await clock!.advance(1000);
  });
  const { client, daemon } = run;
  daemon.add({ sessionId: "next-chat", cwd: "/home/dev/y", title: "y", harness: "claude", status: "idle", updatedAt: clock!.now });
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
