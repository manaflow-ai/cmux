// Q6: does a `cidr` source rule match a tunnel's traffic, and by which address?
// Candidate addresses: the attachment address inside the VPC (/32), the whole
// VPC CIDR, and the tunnel's own client address (seen only by the gateway).
// Each rule is tried alone; data plane and evaluate_firewall are both recorded.
import { api, createRule, del, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe } from "./fixtures";

await withRun("Q6", async () => {
  const vpc = await meshVpc("q6");
  const vm = await meshVm("q6-vm", vpc.id);
  const t = await meshTunnel("q6-t", vpc);
  const p = await Probe.start("q6", t, { keepalive: 25 });
  const dst = `${vm.ip}:8080`;
  const clientV4 = t.clientAddrs.find((a) => !a.includes(":"))!.split("/")[0];
  const candidates: [string, string][] = [
    ["attachment /32", `${t.attach4}/32`],
    ["vpc cidr", vpc.cidr],
    ["tunnel client address /32", `${clientV4}/32`],
    ["10.0.0.0/8", "10.0.0.0/8"],
  ];
  const baseline = await p.tcp(dst, 1500);
  const cases: any[] = [];
  for (const [label, cidr] of candidates) {
    const r = await createRule(`q6-${label.replace(/\W+/g, "-")}`, { cidr }, { vmId: vm.id, port: 8080, protocol: "tcp" }, { allow: [400] });
    if (r._status === 400) {
      cases.push({ label, cidr, create: `400 ${JSON.stringify(r._error).slice(0, 150)}` });
      continue;
    }
    // give propagation a generous window, then probe 5 times
    let ok = 0;
    const firstOkAt: number[] = [];
    const t0 = Date.now();
    for (let i = 0; i < 20 && ok < 3; i++) {
      const x = await p.tcp(dst, 500);
      if (x.ok) {
        ok++;
        firstOkAt.push(Date.now() - t0);
      }
    }
    const ev = await api("POST", "/v5/firewall/evaluate", {
      source: { tunnelId: t.id, address: t.attach4, vpcIds: [vpc.id] },
      destination: { vmId: vm.id, address: vm.ip, vpcIds: [vpc.id], port: 8080 },
      protocol: "tcp",
    }, { allow: [400, 422] });
    cases.push({ label, cidr, dataPlaneOkOf3: ok, firstOkMs: firstOkAt[0] ?? null, evaluate: ev.json?.outcome ?? ev.status });
    await del("rule", r.id);
    // wait for the rule to stop matching before the next candidate
    for (let i = 0; i < 40; i++) if (!(await p.tcp(dst, 300)).ok) break;
  }
  const echo = await (async () => {
    const r = await createRule("q6-echo", { tunnelId: t.id }, { vmId: vm.id, port: 8080, protocol: "tcp" });
    for (let i = 0; i < 20; i++) if ((await p.tcp(dst, 500)).ok) break;
    const e = await p.echo(dst, "src?");
    await del("rule", r.id);
    return e.reply;
  })();
  await p.stop();
  result("Q6", { attach4: t.attach4, clientV4, vpcCidr: vpc.cidr, baselineNoRule: baseline.ok, vmSeesSource: echo, cases });
});
