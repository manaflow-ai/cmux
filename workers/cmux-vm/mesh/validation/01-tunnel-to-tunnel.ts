// Q1: does Freestyle forward tunnel -> tunnel inside one VPC?
// Two tunnels A and B attached to one VPC, both running wgprobe on this host.
// Pairwise allow rules both ways (tcp 7000 and icmp), then a VPC-wide rule.
// Sanity: A -> VM works through the same gateway.
import { createRule, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, ruleTunnelToVm, warm } from "./fixtures";

await withRun("Q1", async () => {
  const vpc = await meshVpc("q1");
  const vm = await meshVm("q1-vm", vpc.id);
  const ta = await meshTunnel("q1-a", vpc);
  const tb = await meshTunnel("q1-b", vpc);
  await ruleTunnelToVm("q1-a-vm", ta.id, vm.id, 8080);
  const a = await Probe.start("q1a", ta, { keepalive: 25 });
  const b = await Probe.start("q1b", tb, { keepalive: 25 });
  const sanityMs = await warm(a, `${vm.ip}:8080`);
  await a.cmd({ op: "listen", port: 7000 }, 5000);
  await b.cmd({ op: "listen", port: 7000 }, 5000);

  const pair = async (label: string) => ({
    label,
    aToB_tcp: await a.tcp(`${tb.attach4}:7000`, 2000),
    bToA_tcp: await b.tcp(`${ta.attach4}:7000`, 2000),
    aToB_ping: (await a.ping(tb.attach4!, 5, 1000)).recv,
    bToA_ping: (await b.ping(ta.attach4!, 5, 1000)).recv,
  });

  const before = await pair("no tunnel<->tunnel rule");
  await createRule("q1-ab-tcp", { tunnelId: ta.id }, { tunnelId: tb.id, port: 7000, protocol: "tcp" });
  await createRule("q1-ba-tcp", { tunnelId: tb.id }, { tunnelId: ta.id, port: 7000, protocol: "tcp" });
  await createRule("q1-ab-icmp", { tunnelId: ta.id }, { tunnelId: tb.id, protocol: "icmp" });
  await createRule("q1-ba-icmp", { tunnelId: tb.id }, { tunnelId: ta.id, protocol: "icmp" });
  await Bun.sleep(2000);
  const pairwise = await pair("pairwise tunnel rules both ways");
  await createRule("q1-vpcwide", { vpcId: vpc.id }, { vpcId: vpc.id });
  await Bun.sleep(2000);
  const vpcWide = await pair("plus vpc-wide member rule");
  const accepts = { a: a.accepts().map((x) => x.remote), b: b.accepts().map((x) => x.remote) };
  await a.stop();
  await b.stop();
  const fmt = (r: any) => ({
    label: r.label,
    aToB_tcp: r.aToB_tcp.ok ? `ok ${r.aToB_tcp.ms}ms` : `fail ${r.aToB_tcp.err}`,
    bToA_tcp: r.bToA_tcp.ok ? `ok ${r.bToA_tcp.ms}ms` : `fail ${r.bToA_tcp.err}`,
    aToB_ping_recv_of_5: r.aToB_ping,
    bToA_ping_recv_of_5: r.bToA_ping,
  });
  result("Q1", { clientAddrsA: ta.clientAddrs, clientAddrsB: tb.clientAddrs, sanityAtoVmMs: sanityMs, attachA: ta.attach4, attachB: tb.attach4, cases: [before, pairwise, vpcWide].map(fmt), accepts });
});
