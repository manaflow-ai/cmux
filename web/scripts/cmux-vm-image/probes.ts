/**
 * Optional smoke probes for a cmux VM image clone (plans/cmux-next/cloud-automation.md 17, 18).
 *
 * - VM agent bind probe: writes a bind.json with a random, never-issued token for the
 *   development API. The path unit must start the agent, the agent must make its per-clone
 *   keys, call the dev API and get a final refusal, and remove bind.json without writing
 *   bound.json. Proves the trigger, the runtime, MMDS, the keys and egress to the API with no
 *   user credential. A real bind needs a machine the dev API created (its one-time token).
 * - Resize probe: grows one clone from sm to md and times the call and the guest view
 *   (vCPU, memory, root filesystem).
 */
import { API_ORIGINS } from "../../../images/cmux-vm/guest/vm-agent";
import { run, sleep, type Vm } from "./guest";

const ALNUM20 = "$(tr -dc a-z0-9 </dev/urandom | head -c 20)";

export function agentBindProbeCommand(): string {
  return [
    "set -e",
    'test "$(systemctl is-enabled cmux-vm-agent.path)" = enabled',
    'test "$(systemctl is-active cmux-vm-agent.path)" = active',
    "test ! -e /var/lib/cmux/bound.json",
    `team="team_${ALNUM20}"; machine="vm_${ALNUM20}"; token="bt_probe_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 40)"`,
    `umask 077; printf '{"team":"%s","machine":"%s","bind_token":"%s","api_origin":"${API_ORIGINS.dev}","env":"dev"}' "$team" "$machine" "$token" > /var/lib/cmux/bind.json.tmp`,
    "mv /var/lib/cmux/bind.json.tmp /var/lib/cmux/bind.json",
    // Test-side wait for the agent's answer (bounded); the agent itself is event driven.
    "for i in $(seq 1 150); do [ -e /var/lib/cmux/bind.json ] || break; sleep 0.2; done",
    "test ! -e /var/lib/cmux/bind.json",
    "test ! -e /var/lib/cmux/bound.json",
    'test "$(stat -c %a /var/lib/cmux/install/key.json)" = 600',
    'test "$(stat -c %a /var/lib/cmux/wg/key.json)" = 600',
    "journalctl -u cmux-vm-agent.service --no-pager -o cat | grep -m1 'bind: '",
  ].join("\n");
}

export async function agentBindProbe(vm: Vm): Promise<{ ok: boolean; detail: string }> {
  const r = await run(vm, agentBindProbeCommand(), 90_000);
  const line = r.stdout.trim().split("\n").at(-1) ?? "";
  return { ok: r.code === 0 && /bind: refused /.test(line), detail: `${line} ${r.stderr.slice(-200)}`.trim() };
}

const MEASURE = "nproc; awk '/MemTotal/{print int($2/1024)}' /proc/meminfo; df -BM --output=size / | tail -1 | tr -dc 0-9";

type Shape = { cpu: number; memoryMb: number; rootMb: number };

async function shape(vm: Vm): Promise<Shape> {
  const [cpu, mem, root] = (await run(vm, MEASURE)).stdout.trim().split("\n").map(Number);
  return { cpu, memoryMb: mem, rootMb: root };
}

/** Grows the clone to md (4 vCPU, 8 GiB, 32 GiB) and reports how long the call and the guest view take. */
export async function resizeProbe(vm: Vm): Promise<Record<string, number | string>> {
  const before = await shape(vm);
  const t0 = Date.now();
  await vm.resize({ cpu: 4, memory: 8192, storage: 32768 });
  const callMs = Date.now() - t0;
  let after = await shape(vm);
  while (Date.now() - t0 < 90_000 && (after.cpu < 4 || after.memoryMb < 7000 || after.rootMb < 32768 * 0.85)) {
    await sleep(1000);
    after = await shape(vm);
  }
  return { before: JSON.stringify(before), after: JSON.stringify(after), callMs, guestViewMs: Date.now() - t0 };
}
