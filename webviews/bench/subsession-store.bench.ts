// l10n-allow-file: benchmark output, not shipped UI.
// What one session list change costs the agent pane's sub-session store (subagents/subsessions.ts
// `SubsessionStore.set`, run in a layout effect on every snapshot) at 3,000 listed sessions. Leo,
// 2026-11-22: "i feel likesometimes there's like... lags every few frames or something. like a regular
// stutter". A V8 profile of his NIGHTLY's agent pane renderer then had `set` rebuilding its whole name
// index 18-24 ms at a time whenever a chat came or went, or a chat's model, folder or name moved: a
// coordinator starting and ending helpers does that every few seconds.
// Kinds, each one set() of a list one change from the last (the direct client keeps an unchanged
// session's entry, as here):
//   add      a new chat at the head (a helper started)
//   remove   that chat leaves again
//   rename   one chat's name changes (the name index reads it)
//   model    one chat's model changes (its sender hover reads it)
//   status   one chat's turn starts or ends (only its sub-session card reads it)
// Rows: subsession_store.set.<kind>.n<SIZE> (ms p50/p95), target TARGET_MS.
//   bun bench/subsession-store.bench.ts [--size 3000] [--rounds 400]
/// <reference types="bun" />
import { sessionEntry, type AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { SubsessionStore } from "../src/agent-session/acpmux/subagents/subsessions";
import { perfRow } from "./perfRow";

const argValue = (name: string, fallback: number) => {
  const at = process.argv.indexOf(`--${name}`);
  return at > 0 ? Number(process.argv[at + 1]) : fallback;
};
const SIZE = argValue("size", 3000);
const ROUNDS = argValue("rounds", 400);
/// A frame at 120 Hz is 8.3 ms; one store's share of a list change is a small part of it.
const TARGET_MS = 2;

function session(index: number, fields: Record<string, unknown> = {}): AcpmuxSessionEntry {
  return sessionEntry({
    sessionId: `s${index}`,
    title: `Chat ${index}`,
    name: `lane/chat-${index}`,
    shortName: `chat-${index}`,
    harness: index % 3 ? "claude" : "codex",
    model: index % 2 ? "opus" : "sonnet",
    status: "idle",
    cwd: `/Users/me/code/p${index % 40}`,
    updatedAt: 1_000_000 + index,
    createdAt: 1_000_000 + index,
    ...(index % 5 === 0 ? { host: `mac-${index % 4}`, hostKind: "peer", peer: `mac-${index % 4}` } : {}),
    ...(index % 7 === 3 ? { startedBy: `s${index - 1}` } : {}),
    ...(index % 11 === 0 ? { archived: true } : {}),
    ...fields,
  });
}

const quantile = (values: number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))]!;
};

const store = new SubsessionStore();
let list = Array.from({ length: SIZE }, (_, index) => session(index));
store.set(list);
const times: Record<string, number[]> = { add: [], remove: [], rename: [], model: [], status: [] };
const timed = (kind: string, next: AcpmuxSessionEntry[]) => {
  const start = performance.now();
  store.set(next);
  times[kind]!.push(performance.now() - start);
  list = next;
};
for (let round = 0; round < ROUNDS; round++) {
  const at = 1 + ((round * 37) % (SIZE - 2));
  timed("add", [session(SIZE + round, { startedBy: "s1" }), ...list]);
  timed("remove", list.slice(1));
  const renamed = list.slice();
  renamed[at] = session(at, { name: `lane/renamed-${round}` });
  timed("rename", renamed);
  const model = list.slice();
  model[at] = session(at, { name: `lane/renamed-${round}`, model: round % 2 ? "haiku" : "opus" });
  timed("model", model);
  const status = list.slice();
  status[at] = { ...list[at]!, status: round % 2 ? "running" : "idle" };
  timed("status", status);
}
for (const [kind, values] of Object.entries(times)) {
  const p50 = quantile(values, 0.5);
  const p95 = quantile(values, 0.95);
  console.log(
    `${kind.padEnd(7)} n=${SIZE} p50 ${p50.toFixed(3)} ms  p95 ${p95.toFixed(3)} ms  max ${Math.max(...values).toFixed(3)} ms`,
  );
  perfRow({ name: `subsession_store.set.${kind}.n${SIZE}`, p50, p95, target: TARGET_MS });
}
