/**
 * The machine health loop and guard drop-ins (images/cmux-vm/machine-health/cmux-machine-health):
 * the bake installs them with the script's own `install` entry point, the same one a persistent
 * machine such as huge-blue runs, and the smoke checks them on a clone.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { MACHINE_HEALTH_DIR } from "./dns";

export const MACHINE_HEALTH_SCRIPT = path.join(MACHINE_HEALTH_DIR, "cmux-machine-health");
/** The image's disk reclaim script (web/services/vms/hygiene), the health loop's default hygiene command. */
export const MACHINE_HYGIENE_SOURCE = path.resolve(MACHINE_HEALTH_DIR, "../../../web/services/vms/hygiene/cmux-machine-hygiene");
export const MACHINE_HYGIENE_PATH = "/usr/local/bin/cmux-machine-hygiene";
const STAGED = "/root/cmux-machine-health";

export function machineHealthFiles(): Array<{ path: string; text: string; mode: number }> {
  return [
    { path: STAGED, text: readFileSync(MACHINE_HEALTH_SCRIPT, "utf8"), mode: 0o755 },
    { path: MACHINE_HYGIENE_PATH, text: readFileSync(MACHINE_HYGIENE_SOURCE, "utf8"), mode: 0o755 },
  ];
}

/**
 * Install from the staged copy, verify the units, run one pass; prints the health JSON last. The
 * timer is enabled but not started (`--no-start`) for the rest of the bake, so no pass (and no disk hygiene) runs
 * while later steps build, clean and catalogue the image: machineHealthArmCommand starts it as the
 * last step before the snapshot, and clones resume with it running.
 */
export function machineHealthBakeCommand(): string {
  return [
    `python3 ${STAGED} install --no-start`,
    `rm -f ${STAGED}`,
    "systemd-analyze verify /etc/systemd/system/cmux-machine-health.service /etc/systemd/system/cmux-machine-health.timer",
    "test \"$(systemctl is-enabled cmux-machine-health.timer)\" = enabled",
    // A check-only pass: no fix (and so no disk hygiene unit) runs during the bake.
    "/usr/local/sbin/cmux-machine-health run --check-only",
    "cat /run/cmux/machine-health.json",
  ].join(" && ");
}

/** The last step before the snapshot: no pass ran since the bake's own (its files are gone), the timer runs. */
export const MACHINE_HEALTH_ARM_COMMAND = "rm -f /run/cmux/machine-health.json /run/cmux/machine-health-state.json && systemctl start cmux-machine-health.timer && systemctl is-active cmux-machine-health.timer";

/**
 * Smoke on a clone: the timer runs, one pass exits 0 and writes valid JSON, and the guard
 * drop-ins apply. A `systemd-run --scope` named like logind's session scopes stands in for an
 * ssh login and prints its own cgroup limits, and a transient service under the work user's
 * manager prints the OOM score its services get. One `key=value` line each.
 */
export function machineHealthSmokeCommand(workUser: string): string {
  const scope = "g=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup); echo $(cat $g/pids.max) $(cat $g/memory.high) $(cat $g/memory.max) $(cat $g/memory.swap.max)";
  return [
    "echo timer=$(systemctl is-active cmux-machine-health.timer)",
    // The arm step deleted the health file, so its existence proves a timer-started pass on this clone.
    "for _ in $(seq 90); do [ -s /run/cmux/machine-health.json ] && break; sleep 1; done; echo timerpass=$(test -s /run/cmux/machine-health.json && systemctl show -p Result --value cmux-machine-health.service)",
    "systemctl start cmux-machine-health.service; echo run=$?",
    "echo result=$(systemctl show -p Result --value cmux-machine-health.service)",
    "echo health=$(tr -d '\\n' < /run/cmux/machine-health.json)",
    `echo scope=$(systemd-run --quiet --scope --unit=session-cmux-smoke-$$.scope -- sh -c '${scope}')`,
    "echo userslice=$(systemctl show user.slice -p MemoryMax --value)",
    "echo memtotal=$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)",
    `echo usermanager=$(systemctl show user@$(id -u ${workUser}).service -p OOMScoreAdjust -p MemoryMin | tr '\\n' ' ')`,
    `u=$(id -u ${workUser}); systemctl start user@$u.service; echo userservice=$(timeout 30 systemd-run --user -M ${workUser}@ --wait --pipe --quiet cat /proc/self/oom_score_adj)`,
  ].join("; ");
}

/** Problems in machineHealthSmokeCommand's output; none on a healthy clone. */
export function machineHealthSmokeProblems(stdout: string): string[] {
  const kv = new Map(stdout.trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()] as const));
  const problems: string[] = [];
  if (kv.get("timer") !== "active") problems.push(`timer: ${kv.get("timer") ?? "no answer"}`);
  if (kv.get("timerpass") !== "success") problems.push(`timer: no pass started by the timer within 90 s (${kv.get("timerpass") || "no health file"})`);
  if (kv.get("run") !== "0" || kv.get("result") !== "success") problems.push(`one pass: exit ${kv.get("run")}, result ${kv.get("result")}`);
  try {
    const health = JSON.parse(kv.get("health") ?? "") as { schema?: number; checkedAt?: string; problems?: unknown[]; fixed?: unknown[] };
    if (health.schema !== 1 || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(health.checkedAt ?? "") || !Array.isArray(health.fixed)) problems.push(`health file: bad shape: ${kv.get("health")?.slice(0, 200)}`);
    if (!Array.isArray(health.problems) || health.problems.length > 0) problems.push(`health file problems: ${JSON.stringify(health.problems).slice(0, 300)}`);
  } catch {
    problems.push(`health file: not JSON: ${kv.get("health")?.slice(0, 200)}`);
  }
  const [tasks, high, max, swap] = (kv.get("scope") ?? "").split(" ");
  const mem = Number(kv.get("memtotal"));
  const near = (value: string | undefined, share: number) => Math.abs(Number(value) / mem - share) < 0.02;
  if (tasks !== "8192" || !near(high, 0.7) || !near(max, 0.8) || !/^\d+$/.test(swap ?? "")) problems.push(`session scope limits: pids.max ${tasks}, memory.high ${high}, memory.max ${max}, memory.swap.max ${swap} of ${mem} (want 8192, 70%, 80%, a swap limit)`);
  if (!near(kv.get("userslice"), 0.9)) problems.push(`user.slice MemoryMax: ${kv.get("userslice")} of ${mem} (want 90%)`);
  if (!/OOMScoreAdjust=-900/.test(kv.get("usermanager") ?? "") || !/MemoryMin=67108864/.test(kv.get("usermanager") ?? "")) problems.push(`user manager: ${kv.get("usermanager")}`);
  if (kv.get("userservice") !== "200") problems.push(`user service OOM score: ${kv.get("userservice") || "no answer"} (want 200, not the manager's -900)`);
  return problems;
}
