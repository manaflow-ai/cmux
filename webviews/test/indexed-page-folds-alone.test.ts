// A rail click near the held records merges its indexed page below them (`mergeIndexedPage`). That page now folds
// above the held rows alone (`foldOlder`), as an older page does, not with every record held again: each click
// refolded the whole held window, 130 ms of `reduceEvent` at n=500 (bench/chat-fast-scroll.bench.ts). The rows it
// draws must be the rows the whole refold draws, right after the click and after the gap below it fills.
import { afterEach, expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { PromptHeads } from "../src/agent-session/acpmux/promptHeads";
import { connectClient, FakeDaemon, logFor, VirtualClock } from "../bench/stateGrowth";
import type { GodOptions } from "../bench/godFixture";

const SESSION = "indexed-alone";
let clock: VirtualClock | undefined;

afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

/// What a person reads of each row, in order: no version or render bookkeeping.
function drawn(rows: readonly AcpmuxRow[]) {
  return rows.map((row) => {
    const { version: _version, ...rest } = row as AcpmuxRow & Record<string, unknown>;
    return JSON.stringify(rest, (key, value) => (key === "version" ? undefined : value));
  });
}

async function open(events: EventRecord[], whole: boolean, gapFill: boolean, pagedFirst: boolean) {
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock!.now },
    [...events],
  );
  const { client, rows } = await connectClient(daemon, SESSION, clock!);
  const internal = client as any;
  if (whole) internal.olderIndexedRecords = () => undefined;
  if (!gapFill) internal.startIndexedGapFill = () => {};
  // The chat opened on its newest page, which starts inside a turn; or the reader scrolled up a page first, and the
  // held records start one.
  if (pagedFirst) {
    const paged = client.loadOlder(undefined, false, true);
    await clock!.advance(60_000);
    await paged;
  }
  return { client, internal, rows };
}

async function jump(
  events: EventRecord[],
  whole: boolean,
  gapFill: boolean,
  pagedFirst: boolean,
  pick: (prompts: EventRecord[]) => number,
) {
  const { client, internal, rows } = await open(events, whole, gapFill, pagedFirst);
  const cut = !(internal.events[0].kind === "user_message");
  const tailStart: number = internal.firstSeq;
  const prompts = events.filter((event) => event.kind === "user_message" && event.seq < tailStart);
  internal.promptIndex = {
    sessionId: SESSION,
    generation: internal.selectionGeneration,
    tries: 1,
    retryAt: 0,
    heads: PromptHeads.fromRows(
      prompts.map((event): AcpmuxRow => ({
        id: `user-${event.seq}`,
        version: 1,
        at: event.at,
        kind: "user",
        text: "p",
      })),
    ),
  };
  // The clicks whose page folded alone (`olderIndexedRecords` let it).
  let folded = 0;
  const olderIndexedRecords = internal.olderIndexedRecords.bind(internal);
  internal.olderIndexedRecords = (...args: unknown[]) => {
    const older = olderIndexedRecords(...args);
    if (older) folded += 1;
    return older;
  };
  const target = pick(prompts);
  const jumped = client.loadThrough(target);
  await clock!.advance(60_000);
  expect(await jumped).toBe(true);
  const result = { rows: drawn(rows()), folded, tailStart, target, cut };
  client.close();
  return result;
}

const SHAPES: [string, GodOptions][] = [
  ["prose and tools", { turns: 400 }],
  ["subagent chains", { turns: 400, chainEvery: 7, depth: 3 }],
  ["images and big outputs", { turns: 300, imageEvery: 5, mbOutputs: [0.2] }],
];

for (const [name, options] of SHAPES)
  for (const pagedFirst of [false, true])
    for (const gapFill of [false, true])
      test(`an indexed page folded alone draws what the whole refold does: ${name}, ${pagedFirst ? "paged up first" : "on open"}, ${gapFill ? "after the gap fills" : "at the click"}`, async () => {
        clock = new VirtualClock().install();
        const events = logFor(SESSION, "small", options).events;
        // Clicks folded alone with no hole between the page and the held records, and with one the gap fill reads.
        const alone = { next: 0, hole: 0, cut: 0 };
        // Prompts just above the held records (no hole, or a small one) and further up (a hole the gap fill reads).
        for (const back of [1, 2, 3, 5, 8, 13, 21, 26, 30, 35, 40, 50, 60]) {
          const pick = (prompts: EventRecord[]) => prompts[Math.max(0, prompts.length - back)]!.seq;
          const folded = await jump(events, false, gapFill, pagedFirst, pick);
          const whole = await jump(events, true, gapFill, pagedFirst, pick);
          if (!pagedFirst && folded.cut && folded.folded > 0) alone.cut += 1;
          expect(folded.rows).toEqual(whole.rows);
          if (folded.folded > 0) {
            // The page reads INDEXED_PAGE_RADIUS (240) records on each side of its target.
            if (folded.target + 241 < folded.tailStart) alone.hole += 1;
            else alone.next += 1;
          }
        }
        // The incremental fold ran in both cases, not only the whole refold it falls back to.
        expect(alone.next).toBeGreaterThan(0);
        expect(alone.hole).toBeGreaterThan(0);
        // On open the held records start inside a turn: that turn's held head folded again with the page.
        if (!pagedFirst) expect(alone.cut).toBeGreaterThan(0);
      });
