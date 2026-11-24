// l10n-allow-file: benchmark output, not shipped UI.
// What one other chat's change costs the stores every agent page feeds from the session list (subsessions.ts
// SubsessionStore, started/sessionHover.ts SessionHoverStore), at a fleet's list size. Leo, 2026-11-22: "Why should
// non visible thing even affect the renderer thread anyways?" His NIGHTLY's renderer main thread sat about 99% busy
// in SubsessionStore.set rebuilding its name index over about 3,000 chats: each new chat (a sub-agent started, a
// peer's chat listed) and each rename read the whole list again. Each kind of change is applied ROUNDS times to a
// list of SIZE fleet-shaped rows (mockFixture.ts `fleetListedSession`) and timed per change, ms:
//   appended  a new chat listed after the others (session_changed `created`)
//   in_place  one chat's status changes, the list made in place (direct.ts `sessionEntryList`, noteReplaced)
//   renamed   one chat's name changes in place
//   removed   one chat leaves the list (a purge)
//   bun bench/session-store-change.bench.ts [SIZE=3000] [ROUNDS=200]
/// <reference types="bun" />
import { fleetListedSession } from "../src/agent-session/acpmux/mockFixture";
import { sessionEntry, type AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { noteReplaced } from "../src/agent-session/acpmux/sessionIndex";
import { SubsessionStore } from "../src/agent-session/acpmux/subagents/subsessions";
import { SessionHoverStore } from "../src/agent-session/acpmux/started/sessionHover";
import { perfRow } from "./perfRow";

const SIZE = Number(process.argv[2] ?? 3000);
const ROUNDS = Number(process.argv[3] ?? 200);
const now = Date.UTC(2026, 10, 22, 8, 0);
const row = (index: number, fields: Record<string, unknown> = {}) =>
  sessionEntry({ ...(fleetListedSession(index, now) as Record<string, unknown>), ...fields } as never);

type Store = { set(sessions: readonly AcpmuxSessionEntry[]): void; subscribe(listener: () => void): () => void };
const stores: Record<string, () => Store> = {
  subsessions: () => new SubsessionStore(),
  hover: () => new SessionHoverStore(),
};
const kinds = ["appended", "in_place", "renamed", "removed"] as const;
const results: Record<string, Record<string, number>> = {};
for (const [name, make] of Object.entries(stores)) {
  results[name] = {};
  for (const kind of kinds) {
    const store = make();
    store.subscribe(() => {});
    let list = Array.from({ length: SIZE }, (_, index) => row(index));
    store.set(list);
    let next = SIZE;
    const times: number[] = [];
    for (let round = 0; round < ROUNDS; round++) {
      const from = list;
      if (kind === "appended") list = [...list, row(next++)];
      else if (kind === "removed") list = list.filter((_, at) => at !== (round * 7919) % list.length);
      else {
        const at = (round * 7919) % list.length;
        list = list.slice();
        const index = Number(list[at]!.sessionId.slice("listed-".length));
        list[at] = row(
          index,
          kind === "renamed"
            ? { name: `renamed-${round}` }
            : { status: round % 2 ? "running" : "idle", updatedAt: now + round },
        );
        noteReplaced(from, list, [at]);
      }
      const started = performance.now();
      store.set(list);
      times.push(performance.now() - started);
    }
    times.sort((a, b) => a - b);
    const p50 = times[Math.floor(times.length / 2)]!;
    const p95 = times[Math.floor(times.length * 0.95)]!;
    results[name][kind] = Math.round(p50 * 1000) / 1000;
    console.log(`${name} ${kind} n=${SIZE}: p50 ${p50.toFixed(3)} ms, p95 ${p95.toFixed(3)} ms per change`);
    perfRow({ name: `session_store_change.${name}.${kind}.n${SIZE}`, p50, p95, target: 1 });
  }
}
console.log(`SESSION-STORE-CHANGE ${JSON.stringify(results)}`);
