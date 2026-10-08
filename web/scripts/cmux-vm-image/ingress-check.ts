/**
 * Edge-only ingress check for the session host port (bead cx-wx2, vm-image.md 6.3a).
 *
 * `cmux host run` with `"carrier": "freestyle-edge"` binds [::]:1337 and grants carrier auth to
 * every link, so it assumes nothing reaches 1337 except the Freestyle edge. This check creates:
 * - target: the cmux-next create firewall (cloud-driver-body.ts: egress only, no inbound rule);
 * - control: the same plus an inbound public rule for 1337 (proves the probe sees an open port);
 * - probe: an outside machine (egress only) that dials both over every address they hold.
 * Both listeners bind [::]:1337 dual-stack. PASS = the probe reaches the control and never the
 * target, on every address. Every VM id goes to the ledger the moment it exists; the script
 * deletes exactly those ids (never a list call).
 *
 * With --image, the target and control are clones of an image whose session host already listens
 * on [::]:1337 (the real listener, not a stand-in), and nothing is started on them.
 *
 * Usage (from web/): bun scripts/cmux-vm-image/ingress-check.ts [--out-dir <dir>] [--snapshot <id|slug>] [--image]
 */
import path from "node:path";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, type Vm } from "./guest";
import type { Freestyle } from "freestyle";

const PORT = 1337;
const LISTENER = `systemd-run --unit cmuxnp-ingress-listen --collect python3 -c 'import socket,time
s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM)
s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("::",${PORT}))
s.listen(16)
while True:
  c,a=s.accept()
  c.sendall(b"cmux-ingress-ok\\n")
  c.close()' && for i in $(seq 1 50); do ss -Hltn "sport = :${PORT}" | grep -q . && break; sleep 0.1; done && ss -Hltn "sport = :${PORT}"`;
const ADDRESSES = "ip -o addr show scope global | awk '{print $4}' | cut -d/ -f1";

type Created = { vm: Vm; vmId: string; name: string };

async function make(fs: Freestyle, ledger: Ledger, name: string, snapshotId: string, inbound: boolean): Promise<Created> {
  if (!inbound) {
    const { vm, vmId, t0 } = await createVm(fs, ledger, { name, snapshotId });
    await firstExec(vm, t0);
    return { vm, vmId, name };
  }
  // createVm writes the egress-only firewall; the control needs the extra inbound rule.
  const t0 = Date.now();
  const { vm, vmId } = await fs.vms.create({
    snapshotId,
    displayName: name,
    firewall: {
      rules: [
        { action: "allow", source: {}, destination: { public: true } },
        { action: "allow", source: { public: true }, destination: { port: PORT, protocol: "tcp" } },
      ],
    },
    idleTimeoutSeconds: 300,
  } as Parameters<Freestyle["vms"]["create"]>[0]);
  ledger.record(vmId, "vm", name);
  await firstExec(vm, t0);
  return { vm, vmId, name };
}

/** The platform's addresses for the machine (public IPv6, VPC addresses) plus the guest's own global ones. */
async function addresses(vm: Vm): Promise<string[]> {
  const data = (await vm.data()) as { publicIpv6?: string | null; vpcs?: Array<{ ipv4?: string | null; ipv6?: string | null }> | null };
  const platform = [data.publicIpv6, ...(data.vpcs ?? []).flatMap((n) => [n.ipv4, n.ipv6])].map((a) => a?.trim() ?? "").filter(Boolean);
  const r = await run(vm, ADDRESSES);
  const guest = r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
  return [...new Set([...platform, ...guest])];
}

/** One TCP connect from the probe (bash /dev/tcp, 6 s); true when the handshake completed. */
async function dial(probe: Vm, address: string): Promise<{ reached: boolean; detail: string }> {
  const r = await run(probe, `if timeout 6 bash -c 'exec 3<>/dev/tcp/${address}/${PORT}' 2>/dev/null; then echo OPEN; else echo "CLOSED rc=$?"; fi`, 30_000);
  const out = r.stdout.trim();
  return { reached: out === "OPEN", detail: out };
}

async function main(): Promise<number> {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15).toLowerCase();
  const outDir = path.resolve(argValue("--out-dir") ?? `cmux-vm-image-out/ingress-${stamp}`);
  const snapshotId = argValue("--snapshot") ?? "freestyle/ubuntu-sm";
  const image = process.argv.includes("--image");
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const fs = freestyleClient();
  const made: Created[] = [];
  let failed = false;
  try {
    const target = await make(fs, ledger, `cmuxnp-dev-ingress-target-${stamp}`, snapshotId, false);
    made.push(target);
    const control = await make(fs, ledger, `cmuxnp-dev-ingress-control-${stamp}`, snapshotId, true);
    made.push(control);
    const probe = await make(fs, ledger, `cmuxnp-dev-ingress-probe-${stamp}`, snapshotId, false);
    made.push(probe);
    console.log(`VMS target=${target.vmId} control=${control.vmId} probe=${probe.vmId}`);
    for (const vm of [target, control]) {
      if (image) {
        const r = await run(vm.vm, `for i in $(seq 1 120); do ss -Hltn "sport = :${PORT}" | grep -q . && break; sleep 0.5; done; ss -Hltnp "sport = :${PORT}"`);
        console.log(`image listener ${vm.name}: ${r.stdout.trim()}`);
        if (!r.stdout.includes(`:${PORT}`)) throw new Error(`no listener on ${PORT} in ${vm.name}`);
        continue;
      }
      const r = await run(vm.vm, LISTENER);
      console.log(`listen ${vm.name}: rc=${r.code} ${r.stdout.trim()}`);
      if (r.code !== 0) throw new Error(`listener did not start on ${vm.name}: ${r.stderr.slice(-300)}`);
      const self = await run(vm.vm, `timeout 5 curl -sS --max-time 3 telnet://127.0.0.1:${PORT} </dev/null; timeout 5 curl -sS --max-time 3 'telnet://[::1]:${PORT}' </dev/null`);
      console.log(`loopback ${vm.name}: ${self.stdout.trim().replace(/\s+/g, " ")}`);
    }
    const targetAddrs = await addresses(target.vm);
    const controlAddrs = await addresses(control.vm);
    console.log(`addresses target=${targetAddrs.join(",")} control=${controlAddrs.join(",")}`);
    if (targetAddrs.length === 0 || controlAddrs.length === 0) throw new Error("a machine has no global address");
    let controlReached = 0;
    for (const a of controlAddrs) {
      const d = await dial(probe.vm, a);
      console.log(`control ${a}: ${d.reached ? "REACHED" : "refused/timeout"} (${d.detail})`);
      if (d.reached) controlReached += 1;
    }
    let targetReached = 0;
    for (const a of targetAddrs) {
      const d = await dial(probe.vm, a);
      console.log(`target ${a}: ${d.reached ? "REACHED" : "refused/timeout"} (${d.detail})`);
      if (d.reached) targetReached += 1;
    }
    if (controlReached === 0) {
      console.log("RESULT INCONCLUSIVE: the probe never reached the open control, so it cannot prove a closed port");
      failed = true;
    } else if (targetReached > 0) {
      console.log(`RESULT FAIL: the outside probe reached the target's 1337 on ${targetReached} address(es)`);
      failed = true;
    } else {
      console.log(`RESULT PASS: probe reached the control on ${controlReached} address(es) and the target on none (${targetAddrs.length} tried)`);
    }
  } catch (error) {
    console.log(`ERROR ${String(error)}`);
    failed = true;
  } finally {
    for (const m of made) await deleteVm(m.vm, m.vmId, m.name, ledger);
    console.log(`LEDGER ${ledger.file}`);
  }
  return failed ? 1 : 0;
}

process.exit(await main());
