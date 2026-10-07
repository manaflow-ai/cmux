// Q14: keepalive and NAT / gateway idle timeouts.
// Each tunnel: connect, open a long-lived TCP connection to the VM (port 8081),
// then send nothing for T seconds. After T:
//   (1) inbound: the VM opens a new TCP connection to the client (port 7000).
//       This needs the gateway's session and this client's home NAT mapping.
//   (2) the held TCP connection sends one line and waits for the reply.
// T in {30, 120, 300, 600} without keepalive, plus 600 with PersistentKeepalive 25.
// The VM keeps itself awake with outbound pings so idle-pause does not interfere.
import { createRule, exec, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, warm } from "./fixtures";

const CASES: [number, number][] = (process.env.MESH_Q14_CASES ?? "30:0,120:0,300:0,600:0,600:25")
  .split(",")
  .map((s) => s.split(":").map(Number) as [number, number]);

await withRun("Q14", async () => {
  const vpc = await meshVpc("q14");
  const vm = await meshVm("q14-vm", vpc.id);
  await exec(vm.id, `sudo setsid sh -c 'while true; do ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; sleep 15; done' </dev/null >/dev/null 2>&1 &`);
  const run = async ([idle, ka]: [number, number], i: number) => {
    const t = await meshTunnel(`q14-${idle}-${ka}`, vpc);
    await createRule(`q14-in-${i}`, { tunnelId: t.id }, { vmId: vm.id });
    await createRule(`q14-out-${i}`, { vmId: vm.id }, { tunnelId: t.id, port: 7000, protocol: "tcp" });
    const p = await Probe.start(`q14-${i}`, t, { keepalive: ka });
    await warm(p, `${vm.ip}:8080`);
    await p.cmd({ op: "listen", port: 7000 }, 5000);
    const vmConnect = async () => {
      const r = await exec(vm.id, `timeout 12 python3 -c "
import socket,time
t=time.time()
try:
  s=socket.create_connection(('${t.attach4}',7000),10); s.sendall(b'in\\n'); print('ok', round((time.time()-t)*1000), s.recv(50).decode().strip())
except Exception as e: print('fail', round((time.time()-t)*1000), type(e).__name__)
"`);
      return String(r.stdout ?? "").trim();
    };
    const pre = await vmConnect();
    const open = await p.cmd({ op: "hold", payload: "open", proto: "h", dst: `${vm.ip}:8081` });
    const s0 = await p.stats();
    await Bun.sleep(idle * 1000);
    const inbound = await vmConnect(); // before any client-originated packet
    const held = await p.cmd({ op: "hold", payload: "send", proto: "h", timeoutMs: 15000 }, 30000);
    const s1 = await p.stats();
    await p.stop();
    return {
      idleS: idle,
      keepalive: ka,
      inboundBeforeIdle: pre,
      holdOpen: open.ok,
      inboundAfterIdle: inbound,
      heldTcpAfterIdle: held.ok ? `ok ${held.ms}ms` : `fail ${held.err}`,
      handshakeAgeAtEndS: Math.round(Date.now() / 1000 - s1.last_handshake_time_sec),
      rxBytesDuringIdle: s1.rx_bytes - s0.rx_bytes,
    };
  };
  const rows = await Promise.all(CASES.map((c, i) => run(c, i)));
  result("Q14", { rows });
});
