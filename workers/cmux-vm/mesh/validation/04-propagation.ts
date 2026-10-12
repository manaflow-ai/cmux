// Q4: propagation latency of rule create, rule delete, tunnel delete and
// rotate-key, measured on the data plane. N runs each (default 50).
//
// A watch in wgprobe starts a TCP connect to the VM every PERIOD ms (each with
// a 300 ms timeout) and reports the start time of the first attempt in the
// final stable run of the wanted outcome. Both clocks are this host's wall clock.
// Latency = that start time - the moment the API call returned (also reported
// relative to the moment it was sent).
import { api, createRule, del, forget, pct, result, summary, withRun, wgKeypair } from "./lib";
import { fromTunnel, meshTunnel, meshVm, meshVpc, Probe, warm } from "./fixtures";

const N = Number(process.env.MESH_Q4_N ?? 50);
const PERIOD = 10;
const ATT_TO = 300;
const ops = (process.env.MESH_Q4_OPS ?? "rule,tunnel,rotate").split(",");
const traces: any[] = [];
const keep = (label: string, x: any) => {
  if (traces.length < 12 && (x.event !== "done" || traces.length < 6)) traces.push({ label, event: x.event, t: x.t % 100000, attempts: x.attempts, first: x.first % 100000, trace: x.trace?.slice(-6) });
};

await withRun("Q4", async () => {
  const vpc = await meshVpc("q4");
  const vm = await meshVm("q4-vm", vpc.id);
  const dst = `${vm.ip}:8080`;
  const out: Record<string, unknown> = { n: N, periodMs: PERIOD, attemptTimeoutMs: ATT_TO };

  if (ops.includes("rule")) {
    const t = await meshTunnel("q4-rule", vpc);
    const p = await Probe.start("q4r", t, { keepalive: 25 });
    // Prime the WireGuard session with a first rule, then remove it.
    const prime = await createRule("q4-prime", { tunnelId: t.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
    await warm(p, dst);
    await del("rule", prime.id);
    await (await p.watch({ dst, want: "closed", periodMs: PERIOD, timeoutMs: ATT_TO, stable: 5, maxMs: 30000 })).done;
    const create: number[] = [], createSent: number[] = [], del_: number[] = [], delSent: number[] = [], apiC: number[] = [], apiD: number[] = [];
    let timeouts = 0;
    for (let i = 0; i < N; i++) {
      let w = (await p.watch({ dst, want: "open", periodMs: PERIOD, timeoutMs: ATT_TO, stable: 3, maxMs: 30000 })).done;
      const s0 = Date.now();
      const r = await createRule(`q4-r${i}`, { tunnelId: t.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
      const s1 = Date.now();
      let x = await w;
      keep(`create${i} sent=${s0 % 100000} ret=${s1 % 100000}`, x);
      if (x.event === "done") {
        create.push(x.first - s1);
        createSent.push(x.first - s0);
      } else timeouts++;
      apiC.push(s1 - s0);
      w = (await p.watch({ dst, want: "closed", periodMs: PERIOD, timeoutMs: ATT_TO, stable: 5, maxMs: 30000 })).done;
      const d0 = Date.now();
      await del("rule", r.id);
      const d1 = Date.now();
      x = await w;
      keep(`delete${i} sent=${d0 % 100000} ret=${d1 % 100000}`, x);
      if (x.event === "done") {
        del_.push(x.first - d1);
        delSent.push(x.first - d0);
      } else timeouts++;
      apiD.push(d1 - d0);
    }
    await p.stop();
    await del("tunnel", t.id);
    out.ruleCreate = { afterReturn: summary(create), afterSend: summary(createSent), api: summary(apiC) };
    out.ruleDelete = { afterReturn: summary(del_), afterSend: summary(delSent), api: summary(apiD) };
    out.ruleTimeouts = timeouts;
    result("Q4-rule", { ...out });
  }

  if (ops.includes("tunnel")) {
    const lat: number[] = [], latSent: number[] = [], apiT: number[] = [], warmMs: number[] = [];
    let timeouts = 0;
    for (let i = 0; i < N; i++) {
      const t = await meshTunnel(`q4-td${i}`, vpc);
      const tdRule = await createRule(`q4-td${i}`, { tunnelId: t.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
      const p = await Probe.start(`q4t${i}`, t, { keepalive: 25 });
      warmMs.push(await warm(p, dst));
      const w = (await p.watch({ dst, want: "closed", periodMs: PERIOD, timeoutMs: ATT_TO, stable: 5, maxMs: 30000 })).done;
      const d0 = Date.now();
      await del("tunnel", t.id); // its rule is deleted with it
      const d1 = Date.now();
      forget(tdRule.id, "cascade: tunnel deleted");
      const x = await w;
      keep(`tdel${i} sent=${d0 % 100000} ret=${d1 % 100000}`, x);
      if (x.event === "done") {
        lat.push(x.first - d1);
        latSent.push(x.first - d0);
      } else timeouts++;
      apiT.push(d1 - d0);
      await p.stop();
    }
    out.tunnelDelete = { afterReturn: summary(lat), afterSend: summary(latSent), api: summary(apiT), timeouts, firstConnectAfterCreate: summary(warmMs) };
    result("Q4-tunnel", { tunnelDelete: out.tunnelDelete });
  }

  if (ops.includes("rotate")) {
    let kp = wgKeypair();
    const t0 = await meshTunnel("q4-rot", vpc, { kp });
    await createRule("q4-rot", { tunnelId: t0.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
    let cur = await Probe.start("q4rot0", t0, { keepalive: 25 });
    await warm(cur, dst);
    const oldDead: number[] = [], newAlive: number[] = [], apiR: number[] = [];
    let oldNeverDied = 0, newTimeouts = 0, serverKeyChanged = 0;
    let prevServerKey = t0.serverPublicKey;
    for (let i = 0; i < N; i++) {
      const next = wgKeypair();
      const wOld = (await cur.watch({ dst, want: "closed", periodMs: PERIOD, timeoutMs: ATT_TO, stable: 5, maxMs: 60000 })).done;
      const s0 = Date.now();
      const r = await api("POST", `/v5/tunnels/${t0.id}/rotate-key`, { clientPublicKey: next.pub });
      const s1 = Date.now();
      apiR.push(s1 - s0);
      if (r.json.clientPrivateKey) throw new Error("rotate minted a private key");
      const nt = fromTunnel(r.json, next);
      if (nt.serverPublicKey !== prevServerKey) serverKeyChanged++;
      prevServerKey = nt.serverPublicKey;
      const np = await Probe.start(`q4rot${i + 1}`, nt, { keepalive: 25 });
      const wNew = (await np.watch({ dst, want: "open", periodMs: PERIOD, timeoutMs: ATT_TO, stable: 3, maxMs: 30000 })).done;
      const [xo, xn] = await Promise.all([wOld, wNew]);
      keep(`rotOld${i} ret=${s1 % 100000}`, xo);
      if (xo.event === "done") oldDead.push(xo.first - s1);
      else oldNeverDied++;
      if (xn.event === "done") newAlive.push(xn.first - s1);
      else newTimeouts++;
      await cur.stop();
      cur = np;
      kp = next;
    }
    await cur.stop();
    out.rotateKey = {
      oldKeyDeadAfterReturn: summary(oldDead),
      newKeyWorksAfterReturn: summary(newAlive),
      api: summary(apiR),
      oldKeyStillWorkingAt60s: oldNeverDied,
      newKeyTimeouts: newTimeouts,
      serverPublicKeyChangedOnRotate: `${serverKeyChanged}/${N}`,
    };
  }
  if (process.env.MESH_Q4_TRACE) out.traces = traces;
  result("Q4", out);
});
