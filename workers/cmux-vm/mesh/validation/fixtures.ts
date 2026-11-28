// Fixtures shared by the question scripts: a VPC with VMs that run a small
// test server, tunnels created with a locally generated key, and a driver for
// the userspace WireGuard probe (wgprobe, run on the same host as the script).
import { spawn, type Subprocess } from "bun";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  api,
  createRule,
  createTunnel,
  createVm,
  createVpc,
  exec,
  OUT_DIR,
  PREFIX,
  sleep,
  vmVpcIpv4,
  waitRunning,
  wgKeypair,
  type Keypair,
} from "./lib";

export const WGPROBE = process.env.WGPROBE ?? join(import.meta.dir, "wgprobe", "wgprobe");
const KEY_DIR = join(OUT_DIR, "keys");

// Test server on the VM: 8080 answers "pong <line>" and logs the peer address,
// 5201 is a throughput sink/source, UDP 9999 echoes.
export const VM_SERVER = String.raw`
import socket, threading, time, sys
log = open('/tmp/vmserver.log', 'a', buffering=1)
def readline(c):
    b = b''
    while not b.endswith(b'\n'):
        x = c.recv(1)
        if not x: break
        b += x
    return b.decode().strip()
def pong(c, a):
    log.write('%d accept8080 %s\n' % (time.time()*1000, a[0]))
    try:
        c.settimeout(10)
        c.sendall(('pong %s %s\n' % (readline(c), a[0])).encode())
    except Exception: pass
    c.close()
def hold(c, a):
    log.write('%d accept8081 %s\n' % (time.time()*1000, a[0]))
    try:
        while True:
            line = readline(c)
            if not line: break
            c.sendall(('pong %s\n' % line).encode())
    except Exception: pass
    c.close()
def tput(c, a):
    try:
        line = readline(c)
        if line.startswith('DOWN'):
            end = time.time() + float(line.split()[1]); buf = b'\0' * 65536
            while time.time() < end: c.sendall(buf)
        else:
            tot = 0
            while True:
                x = c.recv(262144)
                if not x: break
                tot += len(x)
            c.sendall(('%d\n' % tot).encode())
    except Exception as e: log.write('tput err %s\n' % e)
    c.close()
def serve(port, fn):
    for fam, addr in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if fam == socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind((addr, port)); s.listen(128)
        threading.Thread(target=lambda s=s: [threading.Thread(target=fn, args=s.accept(), daemon=True).start() for _ in iter(int, 1)], daemon=True).start()
def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 9999))
    while True:
        d, a = s.recvfrom(65535); log.write('%d udp %s\n' % (time.time()*1000, a[0])); s.sendto(d, a)
serve(8080, pong); serve(8081, hold); serve(5201, tput)
threading.Thread(target=udp, daemon=True).start()
while True: time.sleep(3600)
`;

export type MeshVm = { id: string; ip: string; ipv6?: string; raw: any };

export async function meshVpc(name: string, extra: Record<string, unknown> = {}) {
  return createVpc(name, extra);
}

export async function meshVm(name: string, vpcId: string, opts: { egress?: boolean; server?: boolean; idle?: number } = {}): Promise<MeshVm> {
  const rules = opts.egress === false ? [] : [{ action: "allow", source: {}, destination: { public: true } }];
  const vm = await createVm(name, {
    vpcs: [{ vpc: vpcId }],
    firewall: { rules },
    idleTimeoutSeconds: opts.idle ?? 300,
  });
  const got = await waitRunning(vm.id);
  const ip = vmVpcIpv4(got)!;
  const ipv6 = (got.vpcs ?? got.networks ?? [])[0]?.ipv6;
  if (opts.server !== false) await startServer(vm.id);
  return { id: vm.id, ip, ipv6, raw: got };
}

export async function startServer(vmId: string) {
  const b64 = Buffer.from(VM_SERVER).toString("base64");
  const r = await exec(
    vmId,
    `echo ${b64} | base64 -d > /tmp/vmserver.py && sudo setsid python3 /tmp/vmserver.py </dev/null >/tmp/vmserver.out 2>&1 & sleep 1; ss -ltn | grep -E ':(8080|8081|5201) ' | wc -l`,
  );
  if (!String(r.stdout ?? "").trim().startsWith("6")) throw new Error(`vm server did not start on ${vmId}: ${JSON.stringify(r).slice(0, 400)}`);
}

export type MeshTunnel = {
  id: string;
  kp: Keypair;
  raw: any;
  attach4?: string;
  attach6?: string;
  endpoint: string;
  serverPublicKey: string;
  clientAddrs: string[];
};

export async function meshTunnel(name: string, vpc: any, opts: { kp?: Keypair; vpcAttach?: Record<string, unknown>; routes?: string[]; allow?: number[] } = {}): Promise<MeshTunnel> {
  const kp = opts.kp ?? wgKeypair();
  const body: Record<string, unknown> = {
    clientPublicKey: kp.pub,
    routes: opts.routes ?? [vpc.cidr, vpc.cidrV6].filter(Boolean),
    vpcs: vpc ? [{ vpc: vpc.id, ...(opts.vpcAttach ?? {}) }] : [],
  };
  const t = await createTunnel(name, body, { allow: opts.allow });
  if (t._status >= 400) return t;
  return fromTunnel(t, kp);
}

export function fromTunnel(t: any, kp: Keypair): MeshTunnel {
  const att = (t.attachments ?? [])[0] ?? {};
  const cfg = String(t.clientConfig ?? "");
  const addrLine = cfg.match(/^\s*Address\s*=\s*(.+)$/m)?.[1] ?? `${t.clientAddressV4}, ${t.clientAddressV6}`;
  return {
    id: t.tunnelId ?? t.id,
    kp,
    raw: t,
    attach4: att.ipv4 ?? undefined,
    attach6: att.ipv6 ?? undefined,
    endpoint: `${t.endpointHost}:${t.endpointPort}`,
    serverPublicKey: t.serverPublicKey,
    clientAddrs: addrLine.split(",").map((s: string) => s.trim()).filter(Boolean),
  };
}

// ---- wgprobe driver ----

let seq = 0;
export class Probe {
  up: any;
  private waiters = new Map<string, (m: any) => void>();
  private events: any[] = [];
  private buf = "";
  private confPath: string;
  constructor(public name: string, private proc: Subprocess<"pipe", "pipe", "inherit">, confPath: string) {
    this.confPath = confPath;
    this.pump();
  }
  static async start(name: string, t: MeshTunnel, opts: { keepalive?: number; mtu?: number; routes?: string[] } = {}) {
    mkdirSync(KEY_DIR, { recursive: true, mode: 0o700 });
    const confPath = join(KEY_DIR, `${PREFIX}-${name}-${Date.now()}.json`);
    const routes = opts.routes ?? (String(t.raw.clientConfig ?? "").match(/^\s*AllowedIPs\s*=\s*(.+)$/m)?.[1] ?? "").split(",").map((s) => s.trim()).filter(Boolean);
    writeFileSync(
      confPath,
      JSON.stringify({ priv: t.kp.priv, peerPub: t.serverPublicKey, endpoint: t.endpoint, addrs: t.clientAddrs, mtu: opts.mtu ?? 1280, keepalive: opts.keepalive ?? 0, routes }),
      { mode: 0o600 },
    );
    const proc = spawn([WGPROBE, "-conf", confPath], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
    const p = new Probe(name, proc, confPath);
    p.up = await p.waitEvent((m) => m.event === "up", 10000);
    return p;
  }
  private async pump() {
    const reader = this.proc.stdout.getReader();
    const dec = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      this.buf += dec.decode(value);
      let i;
      while ((i = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, i);
        this.buf = this.buf.slice(i + 1);
        if (!line.trim()) continue;
        let m: any;
        try {
          m = JSON.parse(line);
        } catch {
          console.error(`[${this.name}] ${line}`);
          continue;
        }
        this.events.push(m);
        if (m.id && this.waiters.has(m.id) && m.event !== "armed" && m.event !== "accept") {
          const w = this.waiters.get(m.id)!;
          this.waiters.delete(m.id);
          w(m);
        }
      }
    }
  }
  waitEvent(pred: (m: any) => boolean, timeoutMs: number): Promise<any> {
    const t0 = Date.now();
    return new Promise((resolve, reject) => {
      const tick = () => {
        const i = this.events.findIndex(pred);
        if (i >= 0) return resolve(this.events.splice(i, 1)[0]);
        if (Date.now() - t0 > timeoutMs) return reject(new Error(`${this.name}: event timeout`));
        setTimeout(tick, 5);
      };
      tick();
    });
  }
  // Send a command; resolve with its final answer.
  cmd(c: Record<string, unknown>, timeoutMs = 120_000): Promise<any> {
    const id = `${this.name}-${++seq}`;
    const p = new Promise<any>((resolve, reject) => {
      this.waiters.set(id, resolve);
      setTimeout(() => {
        if (this.waiters.delete(id)) reject(new Error(`${this.name}: ${c.op} timed out`));
      }, timeoutMs);
    });
    this.proc.stdin.write(JSON.stringify({ id, ...c }) + "\n");
    this.proc.stdin.flush();
    return p;
  }
  // Start a watch and resolve once it is armed. The answer promise is wrapped
  // in an object: an async function returning a bare promise would flatten it
  // and make the caller wait for the whole watch.
  async watch(c: Record<string, unknown>): Promise<{ done: Promise<any> }> {
    const id = `${this.name}-${++seq}`;
    const done = new Promise<any>((resolve) => this.waiters.set(id, resolve));
    this.proc.stdin.write(JSON.stringify({ id, op: "watch", ...c }) + "\n");
    this.proc.stdin.flush();
    await this.waitEvent((m) => m.id === id && m.event === "armed", 5000);
    return { done };
  }
  accepts() {
    return this.events.filter((m) => m.event === "accept");
  }
  ping(dst: string, count = 1, timeoutMs = 1000, size = 0, intervalMs = 0) {
    return this.cmd({ op: "ping", dst, count, timeoutMs, size, intervalMs });
  }
  tcp(dst: string, timeoutMs = 1000) {
    return this.cmd({ op: "tcp", dst, timeoutMs });
  }
  echo(dst: string, payload = "hi", timeoutMs = 3000) {
    return this.cmd({ op: "echo", dst, payload, timeoutMs });
  }
  stats() {
    return this.cmd({ op: "stats" });
  }
  async stop() {
    try {
      this.proc.stdin.write(JSON.stringify({ op: "exit" }) + "\n");
      this.proc.stdin.flush();
    } catch {}
    await Promise.race([this.proc.exited, sleep(1000)]);
    try {
      this.proc.kill();
    } catch {}
    rmSync(this.confPath, { force: true });
  }
}

// Wait for the tunnel to pass traffic: TCP to the VM server, retried.
export async function warm(p: Probe, dst: string, maxMs = 30_000) {
  const t0 = Date.now();
  for (;;) {
    const r = await p.tcp(dst, 1000);
    if (r.ok) return Date.now() - t0;
    if (Date.now() - t0 > maxMs) throw new Error(`${p.name}: ${dst} not reachable after ${maxMs} ms`);
  }
}

export async function ruleTunnelToVm(name: string, tunnelId: string, vmId: string, port?: number, protocol = "tcp") {
  return createRule(name, { tunnelId }, port ? { vmId, port, protocol } : protocol === "icmp" ? { vmId, protocol: "icmp" } : { vmId });
}

export { api, sleep };
