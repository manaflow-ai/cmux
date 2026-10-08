// Q13: does tunnel traffic wake a paused VM, and how fast?
// (a) API pause, then a tunnel TCP connect: N runs. Wake latency = completion of
//     the first successful connect - the moment probing started.
// (b) Denied traffic (no rule for that port) to a paused VM: does it wake?
// (c) One run of the idle-timeout pause (idleTimeoutSeconds 300), then wake.
import { api, createRule, result, sleep, summary, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, warm } from "./fixtures";

const N = Number(process.env.MESH_Q13_N ?? 10);
const IDLE_RUN = process.env.MESH_Q13_IDLE !== "0";

const state = async (id: string) => (await api("GET", `/v5/vms/${id}`)).json.state as string;

await withRun("Q13", async () => {
  const vpc = await meshVpc("q13");
  const vm = await meshVm("q13-vm", vpc.id, { egress: false });
  const t = await meshTunnel("q13-t", vpc);
  await createRule("q13", { tunnelId: t.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
  const p = await Probe.start("q13", t, { keepalive: 25 });
  const dst = `${vm.ip}:8080`;
  await warm(p, dst);
  const pauseMs: number[] = [], wake: number[] = [], wakeFirstAttempt: number[] = [];
  const notPaused: string[] = [];
  for (let i = 0; i < N; i++) {
    const s0 = performance.now();
    await api("POST", `/v5/vms/${vm.id}/pause`, {});
    pauseMs.push(performance.now() - s0);
    const st = await state(vm.id);
    if (st !== "paused") notPaused.push(st);
    await sleep(2000);
    const armT = Date.now();
    const w = (await p.watch({ dst, want: "open", periodMs: 20, timeoutMs: 300, stable: 3, maxMs: 60000 })).done;
    const x = await w;
    if (x.event === "done") {
      wake.push(x.firstOkEnd - armT);
      wakeFirstAttempt.push(x.first - armT);
    }
    await sleep(1000);
  }
  // (b) denied traffic to a paused VM
  await api("POST", `/v5/vms/${vm.id}/pause`, {});
  const beforeDenied = await state(vm.id);
  for (let i = 0; i < 5; i++) await p.tcp(`${vm.ip}:9`, 1000);
  await sleep(3000);
  const afterDenied = await state(vm.id);
  // (c) idle-timeout pause, then wake by traffic
  let idle: any = { skipped: true };
  if (IDLE_RUN) {
    await warm(p, dst, 60000); // wakes it and resets activity
    await p.stop(); // no keepalive traffic while idling
    const t0 = Date.now();
    let st = "running";
    while (st !== "paused" && Date.now() - t0 < 480_000) {
      await sleep(10_000);
      st = await state(vm.id);
    }
    const pausedAfterS = Math.round((Date.now() - t0) / 1000);
    const p2 = await Probe.start("q13b", t, { keepalive: 25 });
    const armT = Date.now();
    const x = await (await p2.watch({ dst, want: "open", periodMs: 20, timeoutMs: 300, stable: 3, maxMs: 60000 })).done;
    idle = { pausedByIdleAfterS: st === "paused" ? pausedAfterS : `not paused after ${pausedAfterS}s (${st})`, wakeMs: x.firstOkEnd ? x.firstOkEnd - armT : null };
    await p2.stop();
  } else await p.stop();
  result("Q13", {
    apiPause: summary(pauseMs),
    stateAfterPauseNotPaused: notPaused,
    wakeByTunnelTcp: summary(wake),
    wakeFirstSuccessfulAttemptStart: summary(wakeFirstAttempt),
    deniedTrafficWakes: `${beforeDenied} -> ${afterDenied}`,
    idleTimeout: idle,
  });
});
