// Q16: where do tunnel endpoints and VMs resolve? One region or several?
// Three tunnels and three VMs. From this host: DNS of every endpoint name, a
// UDP traceroute to the endpoint address, ipinfo of each address, the
// WireGuard handshake time, and ICMP RTT to every VM through the tunnel.
// From each VM: its egress address geolocation and RTT to well-known anycast.
import { api, createRule, exec, result, summary, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe } from "./fixtures";

async function sh(cmd: string[]) {
  const p = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
  return (await new Response(p.stdout).text()).trim();
}

await withRun("Q16", async () => {
  const host = await sh(["hostname"]);
  const hostGeo = await sh(["curl", "-s", "-m", "8", "https://ipinfo.io/json"]);
  const vpc = await meshVpc("q16");
  const vms = [];
  for (let i = 0; i < 3; i++) vms.push(await meshVm(`q16-vm${i}`, vpc.id, { server: false }));
  const tunnels = [];
  for (let i = 0; i < 3; i++) tunnels.push(await meshTunnel(`q16-t${i}`, vpc));
  for (const vm of vms) await createRule(`q16-${vm.id.slice(-4)}`, { tunnelId: tunnels[0].id }, { vmId: vm.id, protocol: "icmp" });

  const endpoints: any[] = [];
  for (const t of tunnels) {
    const name = t.endpoint.split(":")[0];
    const a = await sh(["dig", "+short", "A", name]);
    const aaaa = await sh(["dig", "+short", "AAAA", name]);
    endpoints.push({ name, A: a.split("\n").filter(Boolean), AAAA: aaaa.split("\n").filter(Boolean) });
  }
  const ip = endpoints[0].A.at(-1);
  const ipGeo = ip ? await sh(["curl", "-s", "-m", "8", `https://ipinfo.io/${ip}/json`]) : "";
  const trace = ip ? await sh(["traceroute", "-n", "-q", "1", "-w", "1", "-m", "18", "-P", "UDP", ip]) : "";
  const p = await Probe.start("q16", tunnels[0], { keepalive: 25 });
  const handshakeMs = await (async () => {
    const t0 = Date.now();
    for (let i = 0; i < 50; i++) {
      const s = await p.stats();
      if (s.last_handshake_time_sec > 0) return Date.now() - t0;
      await p.ping(vms[0].ip, 1, 200);
    }
    return null;
  })();
  const rtts: any = {};
  for (const vm of vms) {
    const r = await p.ping(vm.ip, 30, 1000, 0, 50);
    rtts[vm.id] = summary(r.rtts);
  }
  await p.stop();
  const vmInfo: any = {};
  for (const vm of vms) {
    const r = await exec(vm.id, `curl -s -m 8 https://ipinfo.io/json | tr -d '\\n ' | head -c 250; echo; ping -c 5 -q 1.1.1.1 | tail -1; ping -c 5 -q 8.8.8.8 | tail -1`);
    const g = await api("GET", `/v5/vms/${vm.id}`);
    vmInfo[vm.id] = { egressIpv4: g.json.egressIpv4, publicIpv6: g.json.publicIpv6, inside: String(r.stdout ?? "").trim().split("\n") };
  }
  const apiDns = await sh(["dig", "+short", "api.freestyle.sh"]);
  result("Q16", {
    vantage: { host, geo: hostGeo.replace(/\s+/g, " ").slice(0, 200) },
    endpoints,
    endpointGeo: ipGeo.replace(/\s+/g, " ").slice(0, 250),
    tracerouteLastHops: trace.split("\n").slice(-4),
    handshakeMs,
    tunnelIcmpRttToEachVm: rtts,
    vms: vmInfo,
    apiFreestyleSh: apiDns.split("\n"),
  });
});
