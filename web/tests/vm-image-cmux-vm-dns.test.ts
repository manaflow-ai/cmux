import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DNS_SMOKE_COMMAND, dnsCheckProblems, EDGE_RESOLVER_ARM_COMMAND, EDGE_RESOLVER_DROP_IN, edgeResolverFiles, edgeResolverPathUnit, edgeResolverScript, FREESTYLE_TLS_DROP_IN, MACHINE_HEALTH_DIR, resolverBakeCommand } from "../scripts/cmux-vm-image/dns";
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
  for (const from of ["/usr/bin", "/bin"]) {
    if (!existsSync(from)) continue;
    for (const name of readdirSync(from)) {
      if (name === "tailscale" || name === "tailscaled" || existsSync(path.join(dir, name))) continue;
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

// cmux-edge-resolver runs with /bin/sh against a scratch resolv.conf and drop-in dir; the reload is a stub
// that records each call. The edge-rule smoke clone proves it on a real Freestyle clone with a TLS rule.
const AGENT_RESOLV = "# freestyle-tls forwarding resolver\noptions timeout:1 attempts:2\nnameserver 10.32.0.28\n";
const AGENT_DROP_IN = "[Resolve]\nDNS=\nDNS=10.32.0.28\nDomains=~.\n";

async function edgeRun(setup: { resolv?: string; link?: boolean; agentDropIn?: string; ours?: string; reloadFails?: boolean }) {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-edge-resolver-"));
  dirs.push(dir);
  const script = path.join(dir, "cmux-edge-resolver");
  writeFileSync(script, edgeResolverScript());
  chmodSync(script, 0o755);
  const resolv = path.join(dir, "resolv.conf");
  const dropIns = path.join(dir, "resolved.conf.d");
  mkdirSync(dropIns);
  if (setup.link) {
    writeFileSync(path.join(dir, "stub-resolv.conf"), "nameserver 127.0.0.53\n");
    symlinkSync(path.join(dir, "stub-resolv.conf"), resolv);
  } else if (setup.resolv !== undefined) writeFileSync(resolv, setup.resolv);
  if (setup.agentDropIn !== undefined) writeFileSync(path.join(dropIns, FREESTYLE_TLS_DROP_IN), setup.agentDropIn);
  if (setup.ours !== undefined) writeFileSync(path.join(dropIns, EDGE_RESOLVER_DROP_IN), setup.ours);
  const reloads = path.join(dir, "reloads");
  const reload = path.join(dir, "reload");
  writeFileSync(reload, `#!/bin/sh\necho reload >> '${reloads}'\n`);
  chmodSync(reload, 0o755);
  const result = await runChild("/bin/sh", [script], {
    env: {
      PATH: "/usr/bin:/bin",
      CMUX_RESOLV_CONF: resolv,
      CMUX_RESOLVED_DROP_IN_DIR: dropIns,
      CMUX_RESOLVED_RELOAD: setup.reloadFails ? "false" : reload,
      CMUX_RESOLVED_RELOAD_PENDING: path.join(dir, "pending"),
    },
    timeout: 30_000,
  });
  const read = (f: string) => {
    try {
      return readFileSync(f, "utf8");
    } catch {
      return undefined;
    }
  };
  return { code: result.status, stderr: result.stderr, resolv: read(resolv), ours: read(path.join(dropIns, EDGE_RESOLVER_DROP_IN)), reloads: (read(reloads) ?? "").trim().split("\n").filter(Boolean).length, pending: read(path.join(dir, "pending")) !== undefined };
}

describe("cmux-edge-resolver", () => {
  test("parses, and the bake writes it with both units", async () => {
    expect((await runChild("sh", ["-n"], { input: edgeResolverScript() })).status).toBe(0);
    expect((await runChild("bash", ["-n"], { input: EDGE_RESOLVER_ARM_COMMAND })).status).toBe(0);
    expect(edgeResolverFiles().map(([f]) => f)).toEqual(["/usr/local/sbin/cmux-edge-resolver", "/etc/systemd/system/cmux-edge-resolver.service", "/etc/systemd/system/cmux-edge-resolver.path"]);
    expect(edgeResolverPathUnit()).toContain("PathChanged=/etc/resolv.conf\nPathChanged=/etc/systemd/resolved.conf.d/61-freestyle-tls.conf");
  });

  test("the agent's files get the IPv6 listener first, with a 2 s try, and resolved is reloaded once", async () => {
    const r = await edgeRun({ resolv: AGENT_RESOLV, agentDropIn: AGENT_DROP_IN });
    expect(r.code).toBe(0);
    expect(r.resolv).toBe("# freestyle-tls forwarding resolver\noptions timeout:2 attempts:2\nnameserver 2602:f470:1::28\nnameserver 10.32.0.28\n");
    expect(r.ours).toBe("# Written by cmux-edge-resolver.\n[Resolve]\nDNS=\nDNS=2602:f470:1::28 10.32.0.28\n");
    expect(r.reloads).toBe(1);
    expect(r.pending).toBe(false);
  });

  test("a second run changes nothing and does not reload", async () => {
    const first = await edgeRun({ resolv: AGENT_RESOLV, agentDropIn: AGENT_DROP_IN });
    const again = await edgeRun({ resolv: first.resolv, agentDropIn: AGENT_DROP_IN, ours: first.ours });
    expect(again.code).toBe(0);
    expect(again.resolv).toBe(first.resolv);
    expect(again.reloads).toBe(0);
  });

  test("the image's stub link and a resolv.conf without the edge resolver are left alone", async () => {
    const linked = await edgeRun({ link: true });
    expect(linked.code).toBe(0);
    expect(linked.resolv).toBe("nameserver 127.0.0.53\n");
    expect(linked.ours).toBeUndefined();
    const own = "options timeout:1\nnameserver 1.1.1.1\n";
    expect((await edgeRun({ resolv: own })).resolv).toBe(own);
  });

  test("its drop-in goes when the agent's does, and a failed reload stays pending and fails the run", async () => {
    const gone = await edgeRun({ link: true, ours: "stale" });
    expect(gone.ours).toBeUndefined();
    expect(gone.reloads).toBe(1);
    const failed = await edgeRun({ resolv: AGENT_RESOLV, agentDropIn: AGENT_DROP_IN, reloadFails: true });
    expect(failed.code).toBe(1);
    expect(failed.pending).toBe(true);
  });
});
