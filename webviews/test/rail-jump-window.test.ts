// A rail jump far above the held tail holds the target's indexed page as a window (direct.ts `jumpWindow`),
// everything newer left to page back in. The window keeps every whole turn that page brought. Cut at the first
// turn start after the target, it held the target's turn alone: a short turn left the view at the held rows'
// end, which read as following the latest row, and the pane swapped the window for the chat's newest page
// (`returnToLatest`), so a click on the first prompt's tick drew it and then went to the chat's end
// (bench/thread-rail-jump.bench.ts, unloaded case; Leo: "the problem is that it lags").
import { afterEach, expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { PromptHeads } from "../src/agent-session/acpmux/promptHeads";
import { connectClient, FakeDaemon, logFor, VirtualClock } from "../bench/stateGrowth";

const SESSION = "rail-jump-window";
let clock: VirtualClock | undefined;

afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

test("a far rail jump holds every whole turn of the target's page, not the target's turn alone", async () => {
  clock = new VirtualClock().install();
  const events = logFor(SESSION, "small", { turns: 2000 }).events;
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    [...events],
  );
  const { client } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  const tailStart: number = internal.firstSeq;
  const prompts = events.filter((event: EventRecord) => event.kind === "user_message" && event.seq < tailStart);
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
  const target = prompts[0]!.seq;
  const jumped = client.loadThrough(target);
  await clock.advance(60_000);
  expect(await jumped).toBe(true);
  // The jump took the window path: newer records are left to page back in.
  expect(client.hasNewerLeft()).toBe(true);
  const held: EventRecord[] = internal.events;
  expect(held[0]!.seq).toBe(target);
  const heldPrompts = held.filter((event) => event.kind === "user_message").length;
  // The indexed page reaches INDEXED_PAGE_RADIUS records past the target: many turns, all of them held.
  expect(heldPrompts).toBeGreaterThan(5);
  const pageEnd = held.at(-1)!.seq;
  const turnsInPage = prompts.filter((event) => event.seq >= target && event.seq <= pageEnd).length;
  expect(heldPrompts).toBe(turnsInPage);
  client.close();
});
