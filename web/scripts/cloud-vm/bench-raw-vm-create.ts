#!/usr/bin/env bun
/**
 * The floor for New Machine: create one VM straight from a devbox snapshot
 * with the Freestyle SDK, attached to an existing private network, and time
 * until its cmux-tui daemon accepts TCP on 1337 through the Mac's WireGuard
 * hub. No cmux backend, database, auth, billing, or app is involved.
 *
 *   FREESTYLE_API_KEY=... bun scripts/cloud-vm/bench-raw-vm-create.ts \
 *     --snapshot sh-... --vpc <vpcId> --hub <hub socket> [--runs 3] [--slug-prefix x]
 *
 * `--vpc` is the owner's network (read it from any of their VMs); `--hub` is
 * the socket `vm.cmux_remote_info` returns as `wireguard_hub_socket`.
 * Every VM this script creates is deleted before it exits.
 */
import { connect, isIPv4 } from "node:net";
import { parseArgs } from "node:util";
import { Freestyle } from "freestyle";

const { values } = parseArgs({
  options: {
    snapshot: { type: "string" },
    vpc: { type: "string" },
    hub: { type: "string" },
    runs: { type: "string", default: "3" },
    "slug-prefix": { type: "string" },
  },
});
const snapshotId = values.snapshot, vpcId = values.vpc, hub = values.hub;
if (!snapshotId || !vpcId || !hub) throw new Error("--snapshot, --vpc and --hub are required");
const apiKey = process.env.FREESTYLE_API_KEY?.trim();
if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
const fs = new Freestyle({ apiKey, baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined });

/** One SOCKS5 CONNECT through the hub; resolves true when the daemon accepts. */
function probe(ip: string, timeoutMs = 400): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect(hub!);
    let stage = 0;
    const done = (ok: boolean) => { socket.destroy(); resolve(ok); };
    const timer = setTimeout(() => done(false), timeoutMs);
    socket.on("error", () => { clearTimeout(timer); done(false); });
    socket.on("connect", () => socket.write(Buffer.from([5, 1, 0])));
    socket.on("data", (chunk) => {
      if (stage === 0) {
        stage = 1;
        const address = isIPv4(ip) ? Buffer.from([1, ...ip.split(".").map(Number)]) : Buffer.alloc(0);
        socket.write(Buffer.concat([Buffer.from([5, 1, 0]), address, Buffer.from([1337 >> 8, 1337 & 0xff])]));
      } else {
        clearTimeout(timer);
        done(chunk.length >= 2 && chunk[1] === 0);
      }
    });
  });
}

/** Starts a new probe every 100 ms (early SYNs to a fresh VM are lost). */
async function firstReachable(ip: string, deadlineMs = 30_000): Promise<number | null> {
  const started = performance.now();
  return new Promise((resolve) => {
    let settled = false;
    const tick = setInterval(() => {
      if (performance.now() - started > deadlineMs) { clearInterval(tick); if (!settled) { settled = true; resolve(null); } return; }
      const at = performance.now();
      void probe(ip).then((ok) => {
        if (ok && !settled) { settled = true; clearInterval(tick); resolve(at); }
      });
    }, 50);
  });
}

const runs = Number(values.runs);
for (let run = 1; run <= runs; run++) {
  const slug = values["slug-prefix"] ? `${values["slug-prefix"]}-${run}-${Date.now().toString(36)}` : undefined;
  const t0 = performance.now();
  const { vm, vmId, data } = await fs.vms.create({
    snapshotId,
    ...(slug ? { slug } : {}),
    idleTimeoutSeconds: 600,
    metadata: { cmux: "bench-raw" },
    firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
    vpcs: [{ vpcId, ipv4: true, ipv6: true }],
  });
  const t1 = performance.now();
  try {
    const ip = (data.vpcs ?? []).map((n) => n.ipv4).find(Boolean);
    if (!ip) throw new Error(`VM ${vmId} has no VPC IPv4`);
    const reachableAt = await firstReachable(ip);
    const created = Math.round(t1 - t0);
    const reach = reachableAt === null ? "timeout" : `${Math.round(reachableAt - t1)} ms`;
    const total = reachableAt === null ? "timeout" : `${Math.round(reachableAt - t0)} ms`;
    let hostname = "";
    if (slug) {
      const r = await vm.exec({ command: "curl -s -m 2 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/hostname", timeoutMs: 10_000 });
      hostname = ` guest-metadata-hostname=${(r.stdout ?? "").trim()} slug=${slug}`;
    }
    console.log(`run ${run}: create ${created} ms, reachable +${reach} after create, total ${total} (${vmId} ${ip})${hostname}`);
  } finally {
    await vm.delete().catch((error) => console.error(`delete ${vmId} failed`, error));
  }
}
