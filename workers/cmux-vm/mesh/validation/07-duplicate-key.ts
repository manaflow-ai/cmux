// Q7: may two tunnels carry the same clientPublicKey? If yes, where does traffic go?
// Case 1: same key, same VPC. Case 2: same key, two VPCs. One client process per
// tunnel config; rules allow each tunnel to its own VM only.
import { api, createRule, result, withRun, wgKeypair } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe } from "./fixtures";

await withRun("Q7", async () => {
  const kp = wgKeypair();
  const vpc1 = await meshVpc("q7a");
  const vpc2 = await meshVpc("q7b");
  const vm1 = await meshVm("q7-vm1", vpc1.id);
  const vm2 = await meshVm("q7-vm2", vpc2.id);
  const t1 = await meshTunnel("q7-t1", vpc1, { kp });
  const t2same = await meshTunnel("q7-t2-samevpc", vpc1, { kp, allow: [400, 409] });
  const t3other = await meshTunnel("q7-t3-othervpc", vpc2, { kp, allow: [400, 409] });
  const created = (t: any) => (t._status >= 400 ? `refused ${t._status} ${JSON.stringify(t._error).slice(0, 200)}` : `created ${t.id}`);
  const out: any = { sameVpc: created(t2same), otherVpc: created(t3other) };
  const tunnels = [t1, t2same, t3other].filter((t: any) => !(t._status >= 400));
  out.serverKeys = tunnels.map((t: any) => t.serverPublicKey.slice(0, 8));
  out.endpoints = tunnels.map((t: any) => t.endpoint);
  await createRule("q7-t1", { tunnelId: t1.id }, { vmId: vm1.id, port: 8080, protocol: "tcp" });
  if (!(t3other._status >= 400)) await createRule("q7-t3", { tunnelId: t3other.id }, { vmId: vm2.id, port: 8080, protocol: "tcp" });
  if (!(t2same._status >= 400)) await createRule("q7-t2", { tunnelId: t2same.id }, { vmId: vm1.id, port: 8081, protocol: "tcp" });
  // One at a time, then both at once.
  const reach = async (p: Probe) => ({
    vm1_8080: (await p.tcp(`${vm1.ip}:8080`, 1500)).ok,
    vm1_8081: (await p.tcp(`${vm1.ip}:8081`, 1500)).ok,
    vm2_8080: (await p.tcp(`${vm2.ip}:8080`, 1500)).ok,
  });
  const solo: any = {};
  for (const t of tunnels as any[]) {
    const p = await Probe.start(`q7-${t.id.slice(-4)}`, t, { keepalive: 25 });
    await Bun.sleep(1500);
    solo[t.raw.displayName.split("-").slice(-2).join("-")] = await reach(p);
    await p.stop();
  }
  out.solo = solo;
  if (tunnels.length > 1) {
    const ps = await Promise.all((tunnels as any[]).map((t) => Probe.start(`q7c-${t.id.slice(-4)}`, t, { keepalive: 25 })));
    await Bun.sleep(1500);
    out.concurrent = {};
    for (let i = 0; i < ps.length; i++) out.concurrent[(tunnels as any[])[i].raw.displayName.split("-").slice(-2).join("-")] = await reach(ps[i]);
    await Promise.all(ps.map((p) => p.stop()));
  }
  result("Q7", out);
});
