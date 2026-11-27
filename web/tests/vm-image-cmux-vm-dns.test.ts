import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DNS_SCOPE_PATH, DNS_SMOKE_COMMAND, dnsCheckProblems, dnsScopeUnits, MACHINE_HEALTH_DIR, resolverBakeCommand } from "../scripts/cmux-vm-image/dns";
import { runChild } from "./helpers/run-child";

// cmux-dns-check runs against stubs of systemctl, journalctl, getent and tailscale on PATH and a
// resolv.conf in a temp dir (CMUX_DNS_RESOLV_CONF, CMUX_DNS_STUB); the smoke runs it for real.
const SCRIPT = path.join(MACHINE_HEALTH_DIR, "cmux-dns-check");
const dirs: string[] = [];
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

// The system tools the script may call, minus the machine's own tailscale: on a host that has it
// (a fleet runner, a lane VM, both on the tailnet) /usr/bin/tailscale answered for a machine
// stubbed without it, and "tailscale is not installed" never printed.
let systemBin: string | undefined;
function systemPath(): string {
  if (systemBin) return systemBin;
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-dns-check-sys-"));
  dirs.push(dir);
  // Names already linked, not existsSync: that follows the link, so a dangling one in /usr/bin (a
  // CI runner's rust-lld) reads as absent and the /bin pass then fails with EEXIST.
  const linked = new Set<string>();
  for (const from of ["/usr/bin", "/bin"]) {
    if (!existsSync(from)) continue;
    for (const name of readdirSync(from)) {
      if (name === "tailscale" || name === "tailscaled" || linked.has(name)) continue;
      linked.add(name);
      symlinkSync(path.join(from, name), path.join(dir, name));
    }
  }
  systemBin = dir;
  return dir;
}

type Machine = {
  link?: boolean;
  resolvedActive?: boolean;
  readlinkFails?: boolean;
  resolves?: string[];
  /** status "fail": `tailscale status --json` exits 1. */
  /** started: tailscaled's ExecMainStartTimestamp; unset, systemctl prints nothing. */
  tailscale?: { status: unknown; dnsLog?: string; journalFails?: boolean; stopped?: boolean; started?: string };
};

function stub(dir: string, name: string, body: string): void {
  const file = path.join(dir, "bin", name);
  writeFileSync(file, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(file, 0o755);
}

async function check(machine: Machine, args: string[] = []) {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-dns-check-"));
  dirs.push(dir);
  mkdirSync(path.join(dir, "bin"));
  const stubFile = path.join(dir, "stub-resolv.conf");
  writeFileSync(stubFile, "nameserver 127.0.0.53\n");
  const resolv = path.join(dir, "resolv.conf");
  if (machine.link ?? true) symlinkSync(stubFile, resolv);
  else writeFileSync(resolv, "# written by tailscale\n");
  const log = path.join(dir, "calls");
  if (machine.readlinkFails) stub(dir, "readlink", "exit 127");
  const ts = machine.tailscale;
  stub(dir, "systemctl", [
    `echo "systemctl $*" >> ${log}`,
    'case "$1" in',
    `  cat) [ "$2" = tailscaled.service ] && ${ts ? "exit 0" : "exit 1"} ;;`,
    "  restart) exit 0 ;;",
    `  is-active) case "$3" in tailscaled.service) ${ts?.stopped ? "exit 3" : "exit 0"} ;; esac; ${machine.resolvedActive ?? true ? "exit 0" : "exit 3"} ;;`,
    `  show) case "$*" in *ExecMainStartTimestamp*) echo ${JSON.stringify(ts?.started ?? "")} ;; *) echo inv-1 ;; esac; exit 0 ;;`,
    "esac",
    "exit 1",
  ].join("\n"));
  stub(dir, "journalctl", ts?.journalFails ? "exit 1" : [
    `echo "journalctl $*" >> ${log}`,
    'for a; do [ "$a" = _SYSTEMD_INVOCATION_ID=inv-1 ] && hit=1; done',
    `[ -n "$hit" ] && printf '%b\\n' ${JSON.stringify(ts?.dnsLog ?? "")}`,
  ].join("\n"));
  stub(dir, "getent", `for n in ${(machine.resolves ?? ["github.com"]).join(" ")}; do [ "$2" = "$n" ] && { echo "140.82.112.3 STREAM $n"; exit 0; }; done; exit 2`);
  if (ts) {
    writeFileSync(path.join(dir, "status.json"), JSON.stringify(ts.status));
    stub(dir, "tailscale", ts.status === "fail" ? "exit 1" : `[ "$1 $2" = "status --json" ] && cat ${path.join(dir, "status.json")}`);
  }
  const result = await runChild("bash", [SCRIPT, "--timeout", "0", ...args], {
    env: { PATH: `${path.join(dir, "bin")}:${systemPath()}`, CMUX_DNS_RESOLV_CONF: resolv, CMUX_DNS_STUB: stubFile },
    timeout: 30_000,
  });
  let calls: string[] = [];
  try {
    calls = readFileSync(log, "utf8").trim().split("\n");
  } catch {
    calls = [];
  }
  return { code: result.status, lines: result.stdout.trim().split("\n"), stdout: result.stdout, calls };
}

const LOGGED_IN = {
  BackendState: "Running",
  MagicDNSSuffix: "tail1234.ts.net",
  CurrentTailnet: { MagicDNSEnabled: true },
  Self: { DNSName: "huge-blue.tail1234.ts.net." },
};
const RESOLVED_MODE = "dns: [rc=resolved resolved=file nm=no ret=systemd-resolved]";

describe("cmux-dns-check", () => {
  test("parses, and the bake command parses", async () => {
    expect((await runChild("bash", ["-n", SCRIPT])).status).toBe(0);
    expect((await runChild("bash", ["-n"], { input: resolverBakeCommand() })).status).toBe(0);
    expect(DNS_SMOKE_COMMAND).toBe("/usr/local/sbin/cmux-dns-check --restart");
    // An inactive resolved on the base is started, not a failed bake.
    expect(resolverBakeCommand()).toStartWith("systemctl enable --now systemd-resolved.service");
  });

  test("a resolved machine without tailscale passes and skips the tailnet name with the reason", async () => {
    const r = await check({});
    expect(r.code).toBe(0);
    expect(r.lines.some((l) => l.startsWith("PASS resolv.conf: "))).toBe(true);
    expect(r.lines).toContain("PASS systemd-resolved: active");
    expect(r.lines).toContain("PASS resolve github.com: 140.82.112.3");
    expect(r.lines).toContain("SKIP resolve tailnet name: tailscale is not installed");
    expect(dnsCheckProblems(r.code!, r.stdout)).toEqual([]);
  });

  test("--restart restarts resolved, then tailscaled, and resolves the machine's own MagicDNS name", async () => {
    const r = await check({ resolves: ["github.com", "huge-blue.tail1234.ts.net"], tailscale: { status: LOGGED_IN, dnsLog: RESOLVED_MODE } }, ["--restart"]);
    expect(r.code).toBe(0);
    const restarts = r.calls.filter((c) => c.startsWith("systemctl restart"));
    expect(restarts).toEqual(["systemctl restart systemd-resolved.service", "systemctl restart tailscaled.service"]);
    expect(r.lines).toContain("PASS tailscale DNS mode: systemd-resolved");
    expect(r.lines).toContain("PASS resolve tailnet name huge-blue.tail1234.ts.net: 140.82.112.3");
    expect(dnsCheckProblems(r.code!, r.stdout)).toEqual([]);
  });

  test("without tailscaled --restart restarts only resolved and says why", async () => {
    const r = await check({}, ["--restart"]);
    expect(r.code).toBe(0);
    expect(r.calls.filter((c) => c.startsWith("systemctl restart"))).toEqual(["systemctl restart systemd-resolved.service"]);
    expect(r.lines).toContain("SKIP restart tailscaled: tailscaled is not installed");
  });

  test("the huge-blue breakage fails: a plain resolv.conf, tailscale in direct mode, nothing resolving", async () => {
    const r = await check({ link: false, resolves: [], tailscale: { status: LOGGED_IN, dnsLog: "dns: [rc=unknown ret=direct]" } });
    expect(r.code).toBe(1);
    const problems = dnsCheckProblems(r.code!, r.stdout);
    expect(problems.some((p) => /^resolv\.conf: .*resolv\.conf is not a link to .*stub-resolv\.conf$/.test(p))).toBe(true);
    expect(problems).toContain("tailscale DNS mode: direct (tailscaled writes resolv.conf itself instead of using systemd-resolved)");
    expect(problems).toContain("resolve github.com: no address within 0s");
    expect(problems).toContain("resolve tailnet name huge-blue.tail1234.ts.net: no address within 0s");
    expect(problems).toContain("no PASS for the resolv.conf link");
  });

  test("a stopped resolved fails; a logged-out or MagicDNS-off tailnet only skips its name", async () => {
    expect((await check({ resolvedActive: false })).lines).toContain("FAIL systemd-resolved: not active");
    const out = await check({ tailscale: { status: { BackendState: "NeedsLogin" }, dnsLog: RESOLVED_MODE } });
    expect(out.code).toBe(0);
    expect(out.lines).toContain("SKIP resolve tailnet name: not logged in to a tailnet (BackendState NeedsLogin)");
    const off = await check({ tailscale: { status: { ...LOGGED_IN, CurrentTailnet: { MagicDNSEnabled: false } }, dnsLog: RESOLVED_MODE } });
    expect(off.lines).toContain("SKIP resolve tailnet name: MagicDNS is off on this tailnet");
    const quiet = await check({ tailscale: { status: { BackendState: "Stopped" } } });
    expect(quiet.lines).toContain("SKIP tailscale DNS mode: this tailscaled run logged no DNS mode");
  });

  test("a tailscale status or journal it cannot read fails instead of skipping", async () => {
    const status = await check({ tailscale: { status: "fail", dnsLog: RESOLVED_MODE } });
    expect(status.code).toBe(1);
    expect(status.lines).toContain("FAIL resolve tailnet name: tailscale status --json failed");
    const garbage = await check({ tailscale: { status: [1, 2], dnsLog: RESOLVED_MODE } });
    expect(garbage.lines).toContain("FAIL resolve tailnet name: tailscale status --json gave no status object");
    const journal = await check({ tailscale: { status: LOGGED_IN, journalFails: true }, resolves: ["github.com", "huge-blue.tail1234.ts.net"] });
    expect(journal.lines).toContain("FAIL tailscale DNS mode: could not read the tailscaled journal");
  });

  test("an installed but stopped tailscaled skips its mode and the tailnet name", async () => {
    const r = await check({ tailscale: { status: "fail", stopped: true } });
    expect(r.code).toBe(0);
    expect(r.lines).toContain("SKIP tailscale DNS mode: tailscaled is installed but not running");
    expect(r.lines).toContain("SKIP resolve tailnet name: tailscaled is installed but not running");
  });

  test("the last DNS mode line of the run wins", async () => {
    const r = await check({ resolves: ["github.com", "huge-blue.tail1234.ts.net"], tailscale: { status: LOGGED_IN, dnsLog: "dns: [rc=unknown ret=direct]\\nother line\\n" + RESOLVED_MODE } });
    expect(r.lines).toContain("PASS tailscale DNS mode: systemd-resolved");
  });

  test("only the first 10 minutes of a long tailscaled run are read, where it logs its DNS mode", async () => {
    // huge-blue, 8 h into a run: the whole run's journal (380k lines) outlasted the 10 s read.
    const started = "Sun 2026-10-25 20:41:14 UTC";
    const at = Math.floor(Date.parse("2026-10-25T20:41:14Z") / 1000);
    const r = await check({ resolves: ["github.com", "huge-blue.tail1234.ts.net"], tailscale: { status: LOGGED_IN, dnsLog: RESOLVED_MODE, started } });
    expect(r.lines).toContain("PASS tailscale DNS mode: systemd-resolved");
    expect(r.calls).toContain(`journalctl -q -o cat --since @${at - 5} --until @${at + 600} _SYSTEMD_INVOCATION_ID=inv-1`);
    // No start time (systemctl prints nothing): the whole run is read, as before.
    const unbounded = await check({ resolves: ["github.com", "huge-blue.tail1234.ts.net"], tailscale: { status: LOGGED_IN, dnsLog: RESOLVED_MODE } });
    expect(unbounded.lines).toContain("PASS tailscale DNS mode: systemd-resolved");
    expect(unbounded.calls).toContain("journalctl -q -o cat _SYSTEMD_INVOCATION_ID=inv-1");
  });

  test("a starting tailscaled fails after the deadline; an unknown or missing state fails", async () => {
    const starting = await check({ tailscale: { status: { BackendState: "Starting" }, dnsLog: RESOLVED_MODE } });
    expect(starting.code).toBe(1);
    expect(starting.lines).toContain("FAIL resolve tailnet name: tailscaled is still starting (BackendState Starting)");
    const unknown = await check({ tailscale: { status: { BackendState: "Weird" }, dnsLog: RESOLVED_MODE } });
    expect(unknown.lines).toContain("FAIL resolve tailnet name: unknown BackendState 'Weird'");
    const missing = await check({ tailscale: { status: {}, dnsLog: RESOLVED_MODE } });
    expect(missing.lines).toContain("FAIL resolve tailnet name: unknown BackendState None");
    const machineAuth = await check({ tailscale: { status: { BackendState: "NeedsMachineAuth" }, dnsLog: RESOLVED_MODE } });
    expect(machineAuth.code).toBe(0);
  });

  test("a timeout with a leading zero is decimal", async () => {
    const r = await check({}, ["--timeout", "08"]);
    expect(r.code).toBe(0);
  });

  test("a readlink that fails never passes the link check", async () => {
    const r = await check({ readlinkFails: true });
    expect(r.code).toBe(1);
    expect(r.lines.some((l) => l.startsWith("FAIL resolv.conf: "))).toBe(true);
  });

  test("bad usage exits 2", async () => {
    expect((await runChild("bash", [SCRIPT, "--bogus"])).status).toBe(2);
    expect((await runChild("bash", [SCRIPT, "--timeout", "x"])).status).toBe(2);
  });
});

// cmux-dns-scope against a temp resolved.conf.d, run dir and resolv.conf, with systemctl, resolvectl and ip
// stubbed (resolvectl keeps its link state in a file, as resolved does until it restarts).
const SCOPE = path.join(MACHINE_HEALTH_DIR, "cmux-dns-scope");
const EDGE_DROPIN = "[Resolve]\nDNS=\nDNS=10.32.0.28\nDomains=~.\n";
const PUBLIC_DROPIN = "[Resolve]\nDNS=2606:4700:4700::1111 2001:4860:4860::8888 8.8.8.8 8.8.4.4\n";
const FOREIGN_RESOLV = "options timeout:1 attempts:2\nnameserver 10.32.0.28\n";

type Guest = { dir: string; conf: string; run: string; resolv: string; stub: string; log: string };

function scopeGuest(opts: { edge?: boolean; resolv?: string } = {}): Guest {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-dns-scope-"));
  dirs.push(dir);
  const g = { dir, conf: path.join(dir, "conf.d"), run: path.join(dir, "run.d"), resolv: path.join(dir, "resolv.conf"), stub: path.join(dir, "stub-resolv.conf"), log: path.join(dir, "calls") };
  mkdirSync(g.conf);
  mkdirSync(path.join(dir, "bin"));
  writeFileSync(path.join(g.conf, "60-freestyle-vms.conf"), PUBLIC_DROPIN);
  if (opts.edge ?? true) writeFileSync(path.join(g.conf, "61-freestyle-tls.conf"), EDGE_DROPIN);
  writeFileSync(g.stub, "nameserver 127.0.0.53\noptions edns0 trust-ad\n");
  if (opts.resolv === undefined) writeFileSync(g.resolv, FOREIGN_RESOLV);
  else if (opts.resolv === "link") symlinkSync(g.stub, g.resolv);
  else writeFileSync(g.resolv, opts.resolv);
  stub(dir, "systemctl", `echo "systemctl $*" >> ${g.log}; rm -f ${dir}/link-dns ${dir}/link-domain`);
  stub(dir, "ip", `[ "$2" = -4 ] && echo "default via 169.254.77.1 dev eth0 "`);
  stub(dir, "resolvectl", [
    `echo "resolvectl $*" >> ${g.log}`,
    'f=""; case "$1" in dns) f=link-dns ;; domain) f=link-domain ;; default-route) exit 0 ;; esac',
    `if [ $# -gt 2 ]; then shift 2; echo "$*" > ${dir}/$f; else echo "Link 3 ($2): $(cat ${dir}/$f 2>/dev/null)"; fi`,
  ].join("\n"));
  return g;
}

async function scope(g: Guest) {
  writeFileSync(g.log, "");
  const r = await runChild("bash", [SCOPE], {
    env: { PATH: `${path.join(g.dir, "bin")}:${systemPath()}`, CMUX_DNS_CONF_DIR: g.conf, CMUX_DNS_RUN_DIR: g.run, CMUX_DNS_RESOLV_CONF: g.resolv, CMUX_DNS_STUB: g.stub },
    timeout: 30_000,
  });
  return { code: r.status, stdout: r.stdout, calls: readFileSync(g.log, "utf8").trim().split("\n").filter(Boolean) };
}

describe("cmux-dns-scope", () => {
  test("parses; the units run it from the provider's drop-in, resolv.conf and the stub", async () => {
    expect((await runChild("bash", ["-n", SCOPE])).status).toBe(0);
    const units = dnsScopeUnits();
    expect(units["/etc/systemd/system/cmux-dns-scope.service"]).toContain(`ExecStart=${DNS_SCOPE_PATH}`);
    const pathUnit = units["/etc/systemd/system/cmux-dns-scope.path"];
    for (const watched of ["/etc/systemd/resolved.conf.d/61-freestyle-tls.conf", "/etc/resolv.conf", "/run/systemd/resolve/stub-resolv.conf"]) {
      expect(pathUnit).toContain(`PathChanged=${watched}`);
    }
    expect(resolverBakeCommand()).toContain("systemctl enable --now cmux-dns-scope.path");
  });

  test("the image roll's edge-rule clone (runs 45779971043, 45774103440): public resolvers behind the edge one", async () => {
    const g = scopeGuest();
    const r = await scope(g);
    expect(r.code).toBe(0);
    // The edge resolver stays first for every name; the public ones answer when it does not.
    const ours = readFileSync(path.join(g.run, "62-cmux-dns-scope.conf"), "utf8");
    expect(ours).toContain("[Resolve]\nDNS=\nDNS=10.32.0.28 2606:4700:4700::1111 2001:4860:4860::8888 8.8.8.8 8.8.4.4\nDomains=~.\n");
    expect(r.calls).toContain("systemctl restart systemd-resolved.service");
    // *.cmux.internal only ever goes to the edge resolver, on the default-route link.
    expect(r.calls).toContain("resolvectl dns eth0 10.32.0.28");
    expect(r.calls).toContain("resolvectl domain eth0 ~cmux.internal");
    expect(r.calls).toContain("resolvectl default-route eth0 false");
    // The provider's plain resolv.conf goes back to the stub, so every program asks resolved.
    expect(readlinkSync(g.resolv)).toBe(g.stub);
  });

  test("a second pass with everything in place changes nothing; a resolved restart gets the link back", async () => {
    const g = scopeGuest();
    await scope(g);
    const quiet = await scope(g);
    expect(quiet.calls).toEqual(["resolvectl dns eth0", "resolvectl domain eth0"]);
    expect(quiet.stdout).toBe("");
    // A restart of resolved (cmux-dns-check --restart, machine-health's heal) forgets runtime link settings;
    // it rewrites the stub, the path unit runs the script, and the link comes back without another restart.
    rmSync(path.join(g.dir, "link-dns"));
    rmSync(path.join(g.dir, "link-domain"));
    const again = await scope(g);
    expect(again.calls).toEqual(["resolvectl dns eth0", "resolvectl domain eth0", "resolvectl dns eth0 10.32.0.28", "resolvectl domain eth0 ~cmux.internal", "resolvectl default-route eth0 false"]);
  });

  test("a machine without the provider's TLS drop-in is left alone, and loses a stale drop-in of ours", async () => {
    const g = scopeGuest({ edge: false, resolv: "link" });
    const r = await scope(g);
    expect(r.code).toBe(0);
    expect(r.calls).toEqual([]);
    expect(existsSync(path.join(g.run, "62-cmux-dns-scope.conf"))).toBe(false);
    mkdirSync(g.run);
    writeFileSync(path.join(g.run, "62-cmux-dns-scope.conf"), "stale\n");
    const stale = await scope(g);
    expect(existsSync(path.join(g.run, "62-cmux-dns-scope.conf"))).toBe(false);
    expect(stale.calls).toEqual(["systemctl try-reload-or-restart systemd-resolved.service"]);
  });

  test("a stub resolved is still rewriting after the restart is waited for, then linked (roll 45939027983)", async () => {
    const g = scopeGuest();
    rmSync(g.stub);
    // The restart rewrites the stub a moment later, as resolved does.
    stub(g.dir, "systemctl", `echo "systemctl $*" >> ${g.log}; rm -f ${g.dir}/link-dns ${g.dir}/link-domain; ( sleep 1; printf 'nameserver 127.0.0.53\\n' > ${g.stub} ) >/dev/null 2>&1 &`);
    const r = await scope(g);
    expect(r.calls).toContain("systemctl restart systemd-resolved.service");
    expect(lstatSync(g.resolv).isSymbolicLink()).toBe(true);
    expect(r.stdout).toContain(`linked ${g.resolv} to ${g.stub}`);
  });

  test("a stub that never names a nameserver leaves the plain file, within the bound", async () => {
    const g = scopeGuest();
    writeFileSync(g.stub, "");
    const started = Date.now();
    const r = await runChild("bash", [SCOPE], {
      env: { PATH: `${path.join(g.dir, "bin")}:${systemPath()}`, CMUX_DNS_CONF_DIR: g.conf, CMUX_DNS_RUN_DIR: g.run, CMUX_DNS_RESOLV_CONF: g.resolv, CMUX_DNS_STUB: g.stub, CMUX_DNS_STUB_WAIT_S: "2" },
      timeout: 30_000,
    });
    expect(r.status).toBe(0);
    expect(Date.now() - started).toBeLessThan(10_000);
    expect(readFileSync(g.resolv, "utf8")).toBe(FOREIGN_RESOLV);
  });

  test("a resolv.conf that names any other server is not replaced", async () => {
    const g = scopeGuest({ resolv: "nameserver 10.32.0.28\nnameserver 192.0.2.53\n" });
    await scope(g);
    expect(readFileSync(g.resolv, "utf8")).toBe("nameserver 10.32.0.28\nnameserver 192.0.2.53\n");
  });
});
