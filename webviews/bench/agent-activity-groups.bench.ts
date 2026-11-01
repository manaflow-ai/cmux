// The grouped, filtered session list the Agent Activity page draws (model.ts `groups`): App asks for it
// once per render and hands it to the layout. The host pushes the whole state as one snapshot per change,
// so a snapshot carries new session objects and must project again; a local action (select, scrub,
// layout) and a frame event re-render with the same sessions, names, connections and filter, so they
// reuse the last projection. Two arms, each timing one render's `groups` ask:
//   snapshot: the state came from a fresh host snapshot (new objects), the projection is rebuilt;
//   local:    the state is the same objects (a select, scrub, layout action or frame event).
//   bun bench/agent-activity-groups.bench.ts [rounds=9] [renders=200]
import { groups, initialActivityState, reduceActivity, type ActivitySession } from "../src/agent-activity/model";

const ROUNDS = Number(process.argv[2] ?? 9);
const RENDERS = Number(process.argv[3] ?? 200);
const SIZES = [100, 1000, 5000];
const MACHINES = 5;

const session = (index: number): ActivitySession => ({
  id: `s${index}`,
  machine: `m${index % MACHINES}`,
  machineName: `Machine ${index % MACHINES}`,
  label: `Session ${index}`,
  agentKind: "claude",
  agentName: "Claude",
  attribution: "",
  colorHex: "#000000",
  targetApps: ["Safari"],
  status: index % 3 ? "active" : "idle",
  startedAt: 0,
  lastActionAt: (index * 7919) % 10007,
  acts: 0,
  observes: 0,
  errors: 0,
  foregroundOnly: false,
});

function stateOf(size: number) {
  let state = { ...initialActivityState(), filter: "session" };
  for (let machine = 0; machine < MACHINES; machine += 1) {
    const sessions = Array.from({ length: size }, (_, i) => i)
      .filter((i) => i % MACHINES === machine)
      .map(session);
    state = reduceActivity(state, { type: "sessions", machine: `m${machine}`, sessions });
  }
  return state;
}

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;

console.log("sessions | snapshot render ms | local render ms | median of", ROUNDS, "rounds x", RENDERS);
for (const size of SIZES) {
  const snapshotRounds: number[] = [];
  const localRounds: number[] = [];
  for (let round = 0; round < ROUNDS + 1; round += 1) {
    const base = stateOf(size);
    // The host's snapshots arrive deserialized: new objects each time (built before the clock).
    const snapshots = Array.from({ length: RENDERS }, () => {
      const wire = JSON.parse(JSON.stringify({ sessionsByMachine: base.sessionsByMachine }));
      return reduceActivity(base, { type: "snapshot", state: wire });
    });
    let seen = 0;
    let started = performance.now();
    for (const state of snapshots) seen += groups(state).length;
    const snapshotMs = (performance.now() - started) / RENDERS;
    started = performance.now();
    for (let render = 0; render < RENDERS; render += 1) {
      const state = reduceActivity(base, { type: "scrub", seq: render });
      seen += groups(state).length;
    }
    const localMs = (performance.now() - started) / RENDERS;
    if (seen < 0) throw new Error("unreachable");
    if (round > 0) {
      snapshotRounds.push(snapshotMs);
      localRounds.push(localMs);
    }
  }
  console.log(`${size} | ${median(snapshotRounds).toFixed(4)} | ${median(localRounds).toFixed(4)}`);
}
