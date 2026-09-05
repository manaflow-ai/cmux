#!/usr/bin/env bun
/**
 * Minimal Freestyle VPC and TCP probe.
 *
 * This creates one VPC and two short-lived Ubuntu VMs. One VM listens on
 * 0.0.0.0:1337. The other connects to its private IPv4 address. The create
 * calls do not include a TLS rule: TLS rules publish named domains and are not
 * needed for a direct VPC connection.
 *
 * Run from web/ after loading the normal development environment:
 *   source scripts/load-dev-env.sh
 *   bun scripts/probe-freestyle-vpc.ts
 *
 * Set PROBE_KEEP=1 to leave resources for manual inspection. They still have
 * a provider TTL, but delete them when the probe is complete by default.
 */
import { Freestyle, type Vm, type VmData } from "freestyle";

const apiKey = process.env.FREESTYLE_API_KEY?.trim();
const stackAccessToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN?.trim();
const teamId = process.env.FREESTYLE_TEAM_ID?.trim();
if (!apiKey && !(stackAccessToken && teamId)) {
  throw new Error("set FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID");
}

const fs = new Freestyle({
  ...(apiKey ? { apiKey } : { stackAccessToken, teamId }),
  baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined,
});
const keep = process.env.PROBE_KEEP === "1";
const stamp = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
const slug = `cmux-probe-${stamp}`;
const snapshotId = process.env.PROBE_SNAPSHOT?.trim() || "freestyle/ubuntu-sm";
const vmFirewall = { rules: [{ action: "allow" as const, source: {}, destination: { public: true } }] };

let vpcId: string | undefined;
const vms: Array<{ name: string; vm: Vm; id: string }> = [];

function step(message: string): void {
  console.log(`\n[probe] ${message}`);
}

function compact(data: VmData): Record<string, unknown> {
  return {
    id: data.id,
    state: data.state,
    slug: data.slug,
    snapshotId: data.snapshotId,
    publicIpv6: data.publicIpv6,
    vpcs: data.vpcs,
    networks: data.networks,
  };
}

async function waitRunning(name: string, vm: Vm): Promise<VmData> {
  const deadline = Date.now() + 180_000;
  let last: VmData | undefined;
  while (Date.now() < deadline) {
    last = await vm.data();
    console.log(`[probe] ${name} state=${last.state}`);
    if (last.state === "running") return last;
    if (last.state === "stopped" || last.state === "paused") {
      await vm.start();
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(`${name} did not become running: ${last ? JSON.stringify(compact(last)) : "no data"}`);
}

async function exec(name: string, vm: Vm, command: string, timeoutMs = 60_000): Promise<{ code: number; output: string }> {
  const result = await vm.exec({ command, timeoutMs, linuxUser: "root" });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  const code = result.statusCode ?? 124;
  console.log(`\n[probe] ${name} $ ${command}\n${output}\n[probe] exit=${code}`);
  if (code !== 0) throw new Error(`${name} failed with exit ${code}`);
  return { code, output };
}

async function createVm(name: string): Promise<{ vm: Vm; id: string; data: VmData }> {
  if (!vpcId) throw new Error("VPC was not created");
  step(`create ${name} VM in VPC ${vpcId}`);
  const created = await fs.vms.create({
    snapshotId,
    displayName: `${name} ${slug}`,
    ttlSeconds: 1_200,
    automaticRestart: false,
    firewall: vmFirewall,
    vpcs: [{ vpcId, ipv4: true, ipv6: true }],
  });
  vms.push({ name, vm: created.vm, id: created.vmId });
  const data = await waitRunning(name, created.vm);
  console.log(`[probe] ${name} data=${JSON.stringify(compact(data))}`);
  return { vm: created.vm, id: created.vmId, data };
}

try {
  step(`create VPC ${slug}`);
  const createdVpc = await fs.vpc.create({
    slug,
    displayName: `cmux VPC probe ${stamp}`,
    firewall: { rules: [{ action: "allow", source: {}, destination: {} }] },
  });
  vpcId = createdVpc.vpcId;
  console.log(`[probe] VPC=${vpcId} data=${JSON.stringify(createdVpc.data)}`);
  const vpcRules = await fs.firewall.rules.list({ vpcId });
  console.log(`[probe] VPC firewall rules=${JSON.stringify(vpcRules.rules)}`);
  if (!vpcRules.rules.some((rule) => rule.source.vpcId === vpcId && rule.destination.vpcId === vpcId)) {
    throw new Error("VPC has no member-to-member firewall rule");
  }

  const server = await createVm("server");
  const client = await createVm("client");
  const serverNetwork = server.data.vpcs[0] ?? server.data.networks[0];
  const clientNetwork = client.data.vpcs[0] ?? client.data.networks[0];
  const serverIpv4 = serverNetwork?.ipv4?.trim();
  const clientIpv4 = clientNetwork?.ipv4?.trim();
  if (!serverIpv4 || !clientIpv4) throw new Error("VM data has no private IPv4 address");
  if ((serverNetwork.vpcId ?? serverNetwork.vpc) !== vpcId || (clientNetwork.vpcId ?? clientNetwork.vpc) !== vpcId) {
    throw new Error("VM data does not show both VMs attached to the test VPC");
  }
  console.log(`[probe] server IPv4=${serverIpv4}; client IPv4=${clientIpv4}`);

  step("ask the provider firewall evaluator about client -> server:1337");
  const decision = await fs.firewall.evaluate({
    source: { vpcIds: [vpcId], address: clientIpv4 },
    destination: { vpcIds: [vpcId], address: serverIpv4, port: 1337 },
    protocol: "tcp",
  });
  console.log(`[probe] firewall decision=${JSON.stringify(decision)}`);
  if (decision.outcome !== "allowedByRule" && decision.outcome !== "allowedByPlatform") {
    throw new Error(`provider denied client -> server:1337: ${JSON.stringify(decision)}`);
  }

  await exec("server baseline", server.vm, "hostname; ip -4 addr; ip -4 route; ss -lntp 2>/dev/null || true; awk '$2 ~ /:0539$/ {print}' /proc/net/tcp /proc/net/tcp6 || true");
  await exec("server start listener", server.vm, "nohup python3 -m http.server 1337 --bind 0.0.0.0 >/tmp/cmux-vpc-http.log 2>&1 </dev/null & echo $! >/tmp/cmux-vpc-http.pid; sleep 1; kill -0 $(cat /tmp/cmux-vpc-http.pid); ss -lntp | grep ':1337 '");
  await exec("client TCP and HTTP probe", client.vm, `python3 - <<'PY'
import socket
import urllib.request
host = ${JSON.stringify(serverIpv4)}
with socket.create_connection((host, 1337), timeout=10):
    print("tcp_connect=ok")
with urllib.request.urlopen("http://" + host + ":1337/", timeout=10) as response:
    print("http_status=" + str(response.status))
PY`);
  await exec("server TLS egress probe", server.vm, "command -v curl >/dev/null || { echo curl_missing >&2; exit 2; }; curl -fsSI --max-time 10 https://api.freestyle.sh/ | sed -n '1,3p'");
  step("probe passed: private VPC IPv4 reached port 1337 without a TLS rule");
} finally {
  if (keep) {
    console.log(`\n[probe] PROBE_KEEP=1; resources remain: VPC=${vpcId ?? "none"} VMs=${vms.map((entry) => entry.id).join(",") || "none"}`);
  } else {
    for (const entry of [...vms].reverse()) {
      try {
        step(`delete ${entry.name} VM ${entry.id}`);
        await entry.vm.delete();
      } catch (error) {
        console.error(`[probe] cleanup failed for VM ${entry.id}: ${String(error)}`);
      }
    }
    if (vpcId) {
      let deleted = false;
      for (let attempt = 1; attempt <= 8; attempt++) {
        try {
          step(`delete VPC ${vpcId} (attempt ${attempt})`);
          await fs.vpc.delete(vpcId);
          deleted = true;
          break;
        } catch (error) {
          if (attempt === 8) {
            console.error(`[probe] cleanup failed for VPC ${vpcId}: ${String(error)}`);
          } else {
            console.log(`[probe] VPC delete is still settling: ${String(error)}`);
            await new Promise((resolve) => setTimeout(resolve, 3_000));
          }
        }
      }
      if (!deleted) {
        console.error(`[probe] VPC ${vpcId} may still exist; inspect it before another probe`);
      }
    }
  }
}
