// The grouped, filtered session list the Agent Activity page draws (model.ts `groups`), per Timeline or
// Grid render. A render asks for it twice (App's follow subscription, then the layout), and a frame
// event (`events`) re-renders without changing sessions, names, connections or the filter. Each iteration
// here is one frame event followed by those two asks; the report is the median over rounds.
//   bun bench/agent-activity-groups.bench.ts [rounds=9] [renders=200]
import { groups, initialActivityState, reduceActivity, type ActivitySession } from "../src/agent-activity/model";

const ROUNDS = Number(process.argv[2] ?? 9);
const RENDERS = Number(process.argv[3] ?? 200);
const SIZES = [100, 1000, 10000];
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
  lastActionAt: index * 7919 % 10007,
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

console.log("sessions | ms per frame-event render (two groups asks) | median of", ROUNDS, "rounds x", RENDERS);
for (const size of SIZES) {
  const rounds: number[] = [];
  for (let round = 0; round < ROUNDS + 1; round += 1) {
    let state = stateOf(size);
    const started = performance.now();
    let seen = 0;
    for (let render = 0; render < RENDERS; render += 1) {
      state = reduceActivity(state, {
        type: "events",
        session: "s0",
        events: [{ seq: render, time: render, kind: "click", ok: true }],
      });
      seen += groups(state).length + groups(state).length;
    }
    const elapsed = (performance.now() - started) / RENDERS;
    if (seen < 0) throw new Error("unreachable");
    if (round > 0) rounds.push(elapsed);
  }
  console.log(`${size} | ${median(rounds).toFixed(4)} ms`);
}
