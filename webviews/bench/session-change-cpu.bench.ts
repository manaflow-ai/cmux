// l10n-allow-file: benchmark output, not shipped UI.
// CPU of an idle chat pane while acpmux lists thousands of chats and other chats keep changing (Leo, 2026-11-11:
// "not sure what's up with 100% cpu still :("). On his Mac one agent chat page held about 120% of a core while
// the daemon pushed about 5 `session_changed` a second and a `lagged {watch:true}` every 20 to 30 s, at 12,000
// sessions (#40935, "Not in this PR"). This drives the pane's state layer (the acpmux direct client, no pixels)
// through the same traffic on a virtual clock and prints the main-thread milliseconds it spends per second of it.
//   bun bench/session-change-cpu.bench.ts [SESSIONS] [--seconds N] [--rate PER_S] [--lag-every S]
/// <reference types="bun" />
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { FakeDaemon, VirtualClock, connectClient } from "./stateGrowth";

const args = process.argv.slice(2);
const flag = (name: string, fallback: number) => {
  const at = args.indexOf(name);
  return at >= 0 ? Number(args[at + 1]) : fallback;
};
/// The session count: the one argument that is not a flag or a flag's value.
const positional = args.filter((arg, at) => !arg.startsWith("--") && !args[at - 1]?.startsWith("--"));
const sessions = Number(positional[0] ?? 12000);
const seconds = flag("--seconds", 60);
const rate = flag("--rate", 5);
const lagEvery = flag("--lag-every", 25);

const clock = new VirtualClock().install();
// One frame per 16 ms of the virtual clock, as the page's requestAnimationFrame.
AcpmuxDirectClient.scheduleFrame = (run) => {
  const id = setTimeout(run, 16);
  return () => clearTimeout(id);
};

const daemon = new FakeDaemon();
const base = Date.UTC(2026, 10, 10, 0, 0, 0);
const summary = (index: number, updatedAt: number) => ({
  sessionId: `s-${index}`,
  name: `peer-${index % 30}/lane-${index}`,
  peer: index % 30 === 0 ? undefined : `peer-${index % 30}`,
  harness: "claude",
  cwd: `/home/agent/work/${index}`,
  status: index % 7 === 0 ? "running" : "idle",
  createdAt: base + index,
  updatedAt,
  title: `chat ${index}`,
});
for (let index = 0; index < sessions; index++) daemon.add(summary(index, base + index));
const opened = await connectClient(daemon, "s-0", clock);

let changes = 0;
let lags = 0;
const startSnapshots = opened.snapshots();
const cpuBefore = process.cpuUsage();
const wallBefore = performance.now();
const stepMs = 1000 / rate;
for (let at = 0; at < seconds * 1000; at += stepMs) {
  // Another chat on some machine changed (a turn ran, its title moved): acpmux sends its whole row.
  const index = 1 + ((changes * 7919) % (sessions - 1));
  daemon.changed(summary(index, base + sessions + changes));
  changes += 1;
  if (lagEvery > 0 && Math.floor((at + stepMs) / (lagEvery * 1000)) > Math.floor(at / (lagEvery * 1000))) {
    (daemon as any).send("_acpmux/lagged", { watch: true, dropped: 3 });
    lags += 1;
  }
  await clock.advance(stepMs);
}
const cpu = process.cpuUsage(cpuBefore);
const wall = performance.now() - wallBefore;
const cpuMs = (cpu.user + cpu.system) / 1000;
opened.client.close?.();
clock.uninstall();
if (clock.errors.length) console.log(`timer errors: ${clock.errors.join(" | ")}`);
console.log(
  [
    `sessions=${sessions}`,
    `virtual_s=${seconds}`,
    `changes=${changes}`,
    `lags=${lags}`,
    `snapshots=${opened.snapshots() - startSnapshots}`,
    `cpu_ms=${cpuMs.toFixed(0)}`,
    `wall_ms=${wall.toFixed(0)}`,
    `cpu_ms_per_virtual_s=${(cpuMs / seconds).toFixed(1)}`,
    `ms_per_change=${(cpuMs / changes).toFixed(2)}`,
  ].join(" "),
);
process.exit(0);
