// Cloud browser prototype: one Freestyle VM that runs Chromium in Xvfb and the
// cmux-rd host, reached from this Mac through the Freestyle SSH gateway.
//
//   bun vm.ts create [--size 8x16]   create the VM (gpui snapshot: Rust + X11 libs), print its id
//   bun vm.ts ssh-login <vmId>       write a VM-scoped SSH login (user:token) to ~/.cache/cloud-browser/<id>.login (0600)
//   bun vm.ts exec <vmId> <cmd...>   run a command (5 min cap), print output
//   bun vm.ts state <vmId>
//   bun vm.ts delete <vmId>          delete the VM and the SSH identity
//
// Key: FREESTYLE_API_KEY / FREESTYLE_API_URL from ~/.secrets/freestyle-beta.env.
// Design: plans/cmux-next/cloud-browser-DESIGN.md.
import { Freestyle } from "freestyle";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const GPUI_SNAPSHOT = "sh-d1b02383c79d486ba6a8dc1caa0a0542";
const IDLE_TIMEOUT_SECONDS = 1800;
const STATE = join(homedir(), ".cache", "cloud-browser");
mkdirSync(STATE, { recursive: true, mode: 0o700 });

const f = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY, baseUrl: process.env.FREESTYLE_API_URL || undefined });
const [cmd, ...rest] = process.argv.slice(2);

async function waitRunning(id: string) {
  for (let i = 0; i < 120; i++) {
    const d: any = await f.vms.get(id);
    const s = d.state ?? d.data?.state;
    if (s === "running") return;
    await Bun.sleep(1000); // bounded poll of a remote control plane with no event stream
  }
  throw new Error(`${id} not running after 120 s`);
}

switch (cmd) {
  case "create": {
    const sizeArg = rest[rest.indexOf("--size") + 1];
    const [cpu, memGiB] = (rest.includes("--size") ? sizeArg : "8x16").split("x").map(Number);
    const { vmId, vm } = await f.vms.create({
      snapshotId: GPUI_SNAPSHOT,
      idleTimeoutSeconds: IDLE_TIMEOUT_SECONDS,
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
      displayName: "cloud-browser prototype",
      metadata: { purpose: "cloud-browser-prototype", owner: "chief-subagent" },
    } as any);
    await waitRunning(vmId);
    if (cpu > 4) await vm.resize({ cpu, memory: memGiB * 1024 } as any);
    writeFileSync(join(STATE, "vms.log"), `${new Date().toISOString()} create ${vmId} ${cpu}x${memGiB}\n`, { flag: "a" });
    console.log(vmId);
    break;
  }
  case "ssh-login": {
    const id = rest[0];
    const { identity } = await f.identities.create();
    await identity.permissions.vm.grant({ vmId: id } as any);
    const { token } = await identity.tokens.create();
    const file = join(STATE, `${id}.login`);
    writeFileSync(file, `${id}:${token}\n${identity.id}\n`, { mode: 0o600 });
    chmodSync(file, 0o600);
    console.log(file);
    break;
  }
  case "exec": {
    const id = rest[0];
    const r = await f.vms.ref(id).exec({ command: rest.slice(1).join(" "), timeoutMs: 300000 });
    if (r.stdout) process.stdout.write(r.stdout);
    if (r.stderr) process.stderr.write(r.stderr);
    process.exit(r.statusCode ?? 124);
  }
  case "state": {
    const d: any = await f.vms.get(rest[0]);
    console.log(JSON.stringify({ id: d.id, state: d.state, cpu: d.cpu ?? d.vcpu, memory: d.memory }, null, 1));
    break;
  }
  case "delete": {
    const id = rest[0];
    const file = join(STATE, `${id}.login`);
    if (existsSync(file)) {
      const identityId = readFileSync(file, "utf8").split("\n")[1];
      if (identityId) await f.identities.ref(identityId).delete().catch((e: unknown) => console.error("identity delete:", e));
      unlinkSync(file);
    }
    await f.vms.ref(id).delete();
    writeFileSync(join(STATE, "vms.log"), `${new Date().toISOString()} delete ${id}\n`, { flag: "a" });
    console.log(`${id} deleted`);
    break;
  }
  default:
    console.error("usage: bun vm.ts create|ssh-login|exec|state|delete ...");
    process.exit(2);
}
