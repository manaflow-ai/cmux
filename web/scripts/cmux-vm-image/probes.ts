/**
 * Optional smoke probes for a cmux VM image clone (plans/cmux-next/cloud-automation.md 17, 18).
 *
 * - Cloud agent bind probe: writes a bind.json with a random, never-issued token for the
 *   development API. `cmux host run`'s cloud role (inotify on /var/lib/cmux) must make its
 *   per-clone keys, call the dev API and get a final refusal, and remove bind.json without
 *   writing bound.json. Proves the trigger, the runtime, the keys and egress to the API with no
 *   user credential. A real bind needs a machine the dev API created (its one-time token).
 *   The per-clone machine-id comes from the supervisor's rekey job at bind.
 * - Resize probe: grows one clone from sm to md and times the call and the guest view
 *   (vCPU, memory, root filesystem).
 */
import { run, sleep, type Vm } from "./guest";
import { API_ORIGINS, HOST_JOURNAL, HOST_UNIT } from "./host-agent";

const ALNUM20 = "$(tr -dc a-z0-9 </dev/urandom | head -c 20)";

/** Each step prints its own FAIL label, so a failure names the step (no silent set -e exit). */
export function agentBindProbeCommand(): string {
  const step = (label: string, command: string) => `{ ${command}; } || { echo "FAIL ${label}"; ${HOST_JOURNAL} | tail -5; exit 1; }`;
  return [
    step("host-unit-active", `test "$(systemctl is-active ${HOST_UNIT})" = active`),
    step("not-bound-yet", "test ! -e /var/lib/cmux/bound.json"),
    `team="team_${ALNUM20}"; machine="vm_${ALNUM20}"; token="bt_probe_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 40)"`,
    `umask 077; printf '{"team":"%s","machine":"%s","bind_token":"%s","api_origin":"${API_ORIGINS.dev}","env":"dev"}' "$team" "$machine" "$token" > /var/lib/cmux/bind.json.tmp`,
    "mv /var/lib/cmux/bind.json.tmp /var/lib/cmux/bind.json",
    // Test-side wait for the agent's answer (bounded); the agent itself is event driven.
    "for i in $(seq 1 150); do [ -e /var/lib/cmux/bind.json ] || break; sleep 0.2; done",
    step("bind-file-consumed", "test ! -e /var/lib/cmux/bind.json"),
    step("no-bound-file", "test ! -e /var/lib/cmux/bound.json"),
    step("install-key-0600", 'test "$(stat -c %a /var/lib/cmux/install/key.json)" = 600'),
    step("wg-key-0600", 'test "$(stat -c %a /var/lib/cmux/wg/key.json)" = 600'),
    // Per-clone machine-id: the supervisor's rekey job at this clone's bind, both files equal.
    step("machine-id-dbus-equal", 'test "$(cat /etc/machine-id)" = "$(cat /var/lib/dbus/machine-id)"'),
    step("journal-machine-id-line", `${HOST_JOURNAL} | grep -q 'new machine-id='`),
    `${HOST_JOURNAL} | grep -m1 'cloud: bind: '`,
  ].join("\n");
}

export async function agentBindProbe(vm: Vm): Promise<{ ok: boolean; detail: string }> {
  const r = await run(vm, agentBindProbeCommand(), 90_000);
  const line = r.stdout.trim().split("\n").at(-1) ?? "";
  return { ok: r.code === 0 && /bind: refused /.test(line), detail: `${r.stdout.trim().split("\n").slice(-6).join(" | ")} ${r.stderr.slice(-200)}`.trim() };
}

const MEASURE = "nproc; awk '/MemTotal/{print int($2/1024)}' /proc/meminfo; df -BM --output=size / | tail -1 | tr -dc 0-9";

type Shape = { cpu: number; memoryMb: number; rootMb: number };

async function shape(vm: Vm): Promise<Shape> {
  const [cpu, mem, root] = (await run(vm, MEASURE)).stdout.trim().split("\n").map(Number);
  return { cpu, memoryMb: mem, rootMb: root };
}

/**
 * Grows the clone to md (4 vCPU, 8 GiB, 32 GiB) in two provider calls (vCPU+memory, then disk) so
 * a slow sample names its phase (cloud-automation.md 18: one 21.2 s outlier in six samples), with
 * UTC start times for correlation with the provider.
 */
export async function resizeProbe(vm: Vm): Promise<Record<string, number | string>> {
  const before = await shape(vm);
  const t0 = Date.now();
  const startedAt = new Date(t0).toISOString();
  await vm.resize({ cpu: 4, memory: 8192 });
  const cpuMemoryCallMs = Date.now() - t0;
  const t1 = Date.now();
  await vm.resize({ storage: 32768 });
  const storageCallMs = Date.now() - t1;
  const callMs = Date.now() - t0;
  let after = await shape(vm);
  while (Date.now() - t0 < 90_000 && (after.cpu < 4 || after.memoryMb < 7000 || after.rootMb < 32768 * 0.85)) {
    await sleep(1000);
    after = await shape(vm);
  }
  return { before: JSON.stringify(before), after: JSON.stringify(after), startedAt, cpuMemoryCallMs, storageCallMs, callMs, guestViewMs: Date.now() - t0 };
}
