// Q9: is the first session after a long tunnel idle (> 5 min) dropped or slow?
// Tunnels with no keepalive. Per round, three tunnels run in parallel:
//   used-90s:   connected, then fully idle 90 s (control)
//   used-360s:  connected, then fully idle 360 s
//   never-360s: created and attached, never dialed for 360 s
// After the idle, sequential TCP connects (1 s timeout each) until one succeeds.
// The VM keeps itself awake with its own outbound pings, so VM idle-pause is
// not part of this measurement (its state is recorded).
import { api, createRule, exec, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, warm, type MeshTunnel } from "./fixtures";

const ROUNDS = Number(process.env.MESH_Q9_ROUNDS ?? 2);
const LONG = Number(process.env.MESH_Q9_LONG ?? 360);
const SHORT = 90;

await withRun("Q9", async () => {
  const vpc = await meshVpc("q9");
  const vm = await meshVm("q9-vm", vpc.id);
  await exec(vm.id, `sudo setsid sh -c 'while true; do ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; sleep 15; done' </dev/null >/dev/null 2>&1 &`);
  const dst = `${vm.ip}:8080`;
  const rows: any[] = [];

  const firstConnect = async (p: Probe) => {
    const t0 = Date.now();
    const attempts: string[] = [];
    for (let i = 0; i < 60; i++) {
      const r = await p.tcp(dst, 1000);
      attempts.push(r.ok ? `ok@${Date.now() - t0}` : "x");
      if (r.ok) return { firstOkMs: Date.now() - t0, attempts: attempts.length };
    }
    return { firstOkMs: null, attempts: attempts.length };
  };

  for (let round = 0; round < ROUNDS; round++) {
    const mk = async (name: string) => {
      const t = await meshTunnel(`q9-${name}-r${round}`, vpc);
      await createRule(`q9-${name}-r${round}`, { tunnelId: t.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
      return t;
    };
    const [tShort, tLong, tNever] = await Promise.all([mk("used90"), mk("used360"), mk("never")]);
    const run = async (label: string, t: MeshTunnel, idle: number, used: boolean) => {
      let p: Probe | null = null;
      let warmMs: number | null = null;
      if (used) {
        p = await Probe.start(`q9-${label}-${round}`, t);
        warmMs = await warm(p, dst);
      }
      const idleStart = Date.now();
      await Bun.sleep(idle * 1000);
      if (!p) p = await Probe.start(`q9-${label}-${round}`, t);
      const before = await p.stats();
      const fc = await firstConnect(p);
      const after = await p.stats();
      await p.stop();
      return {
        round,
        label,
        idleS: Math.round((Date.now() - idleStart) / 1000),
        warmMs,
        ...fc,
        handshakeRefreshedDuringFirstConnect: after.last_handshake_time_sec !== before.last_handshake_time_sec,
      };
    };
    const r = await Promise.all([run("used90", tShort, SHORT, true), run(`used${LONG}`, tLong, LONG, true), run(`never${LONG}`, tNever, LONG, false)]);
    rows.push(...r);
    const st = await api("GET", `/v5/vms/${vm.id}`);
    rows.push({ round, vmState: st.json.state, lastNetworkActivity: st.json.lastNetworkActivity });
    for (const t of [tShort, tLong, tNever]) await (await import("./lib")).del("tunnel", t.id);
  }
  result("Q9", { rows });
});
