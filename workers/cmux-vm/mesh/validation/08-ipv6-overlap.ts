// Q8: two VPCs with the same IPv4 CIDR on one tunnel. Is the second attach
// refused for IPv4 overlap, and does an IPv6-only attachment avoid the refusal
// and carry traffic?
import { api, createRule, result, withRun } from "./lib";
import { fromTunnel, meshTunnel, meshVm, meshVpc, Probe } from "./fixtures";

const CIDR = process.env.MESH_Q8_CIDR ?? "10.251.7.0/24";

function v6In(cidrV6: string, host: string) {
  const [net] = cidrV6.split("/");
  return net.endsWith("::") ? `${net}${host}` : `${net.replace(/:0$/, "")}:${host}`;
}

await withRun("Q8", async () => {
  const out: any = { cidr: CIDR };
  const x = await meshVpc("q8x", { cidr: CIDR });
  const y = await meshVpc("q8y", { cidr: CIDR }).catch((e) => ({ _err: String(e).slice(0, 200) }));
  out.sameCidrSecondVpc = (y as any)._err ?? `created ${(y as any).id} (${(y as any).cidr}, ${(y as any).cidrV6})`;
  if ((y as any)._err) return result("Q8", out);
  const vy = y as any;
  const vmx = await meshVm("q8-vmx", x.id);
  const vmy = await meshVm("q8-vmy", vy.id);
  out.vmx = { ip: vmx.ip, ipv6: vmx.ipv6 };
  out.vmy = { ip: vmy.ip, ipv6: vmy.ipv6 };
  const t = await meshTunnel("q8-t", x, { routes: [CIDR, "fd00::/8"] });

  // 1) default attach of the overlapping VPC
  const a1 = await api("POST", `/v5/tunnels/${t.id}/vpcs/${vy.id}`, {}, { allow: [400, 409] });
  out.attachOverlapDefault = a1.status === 200 ? "accepted" : `${a1.status} ${a1.text.slice(0, 200)}`;
  // 2) IPv6-only attach (explicit IPv6 address, the only family selector the API has)
  let tunnelNow: any = t.raw;
  if (a1.status !== 200) {
    const want6 = v6In(vy.cidrV6, "77");
    const a2 = await api("POST", `/v5/tunnels/${t.id}/vpcs/${vy.id}`, { ipv6: want6 }, { allow: [400, 409] });
    out.attachOverlapIpv6Only = a2.status === 200 ? "accepted" : `${a2.status} ${a2.text.slice(0, 200)}`;
    out.requestedIpv6 = want6;
    if (a2.status === 200) tunnelNow = a2.json;
  }
  // 3) can a VPC be created without IPv4 at all (explicit null CIDR)?
  const z = await meshVpc("q8z", { cidr: null }).catch((e) => ({ _err: String(e).slice(0, 200) }));
  out.vpcWithNullCidr = (z as any)._err ?? { cidr: (z as any).cidr ?? null, cidrV6: (z as any).cidrV6 ?? null };
  out.attachments = (tunnelNow.attachments ?? []).map((a: any) => ({ vpc: a.vpcId === x.id ? "x" : "y", ipv4: a.ipv4 ?? null, ipv6: a.ipv6 ?? null, allowedIps: a.allowedIps }));
  const attY = (tunnelNow.attachments ?? []).find((a: any) => a.vpcId === vy.id);
  if (attY) {
    await createRule("q8-t-vmx", { tunnelId: t.id }, { vmId: vmx.id, port: 8080, protocol: "tcp" });
    await createRule("q8-t-vmy", { tunnelId: t.id }, { vmId: vmy.id, port: 8080, protocol: "tcp" });
    const tt = fromTunnel(tunnelNow, t.kp);
    const p = await Probe.start("q8", tt, { keepalive: 25 });
    await Bun.sleep(1500);
    const tries = async (dst: string) => {
      for (let i = 0; i < 10; i++) {
        const r = await p.tcp(dst, 1000);
        if (r.ok) return `ok ${r.ms}ms`;
      }
      return "fail";
    };
    out.dataPlane = {
      vmxV4: await tries(`${vmx.ip}:8080`),
      vmyV6: vmy.ipv6 ? await tries(`[${vmy.ipv6}]:8080`) : "vm y has no ipv6",
      vmxV6: vmx.ipv6 ? await tries(`[${vmx.ipv6}]:8080`) : "vm x has no ipv6",
    };
    const e = await p.echo(`[${vmy.ipv6}]:8080`, "q8");
    out.vmySeesSource = e.reply ?? e.err;
    await p.stop();
  }
  result("Q8", out);
});
