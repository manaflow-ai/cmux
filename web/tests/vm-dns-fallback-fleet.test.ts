import { afterEach, describe, expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DEVBOX_DNS_PATH, DEVBOX_DNS_UNITS } from "../scripts/devbox-image-common";
import {
  dnsFallbackInstallCommand,
  dnsFallbackResult,
  dnsFallbackUninstallCommand,
  parseFleetArgs,
  parseMachineIds,
  restoreResolvConfCommand,
  runInBatches,
} from "../scripts/cloud-vm/dns-fallback-fleet";

// cmux issue 26640: new machines get the DNS fallback from the image, but a
// running machine keeps resolving straight through the failing platform
// resolver until the fallback is installed in place, on a customer's machine,
// so a failed install must put back exactly what was there.
const script = readFileSync(path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-dns"), "utf8");
const FILES = [DEVBOX_DNS_PATH, ...Object.keys(DEVBOX_DNS_UNITS)];

/** What the platform writes on a machine with TLS rules (seen on a production machine, 2026-10-29). */
const PLATFORM_RESOLV_CONF = "# freestyle-tls forwarding resolver\noptions timeout:1 attempts:2\nnameserver 10.32.0.28\n";

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function fixture(): string {
  const directory = mkdtempSync(path.join(tmpdir(), "cmux-dns-fleet-"));
  directories.push(directory);
  return directory;
}

/** Loads a cmux-dns copy and runs its `guard` on `file`, as cmux-dns-guard.service does. */
const GUARD_PY = String.raw`
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("cmux_dns", sys.argv[1])
spec = importlib.util.spec_from_loader("cmux_dns", loader)
dns = importlib.util.module_from_spec(spec); loader.exec_module(dns)
print(dns.guard(sys.argv[2]))
`;

async function guard(file: string): Promise<void> {
  const scriptFile = path.join(path.dirname(file), "cmux-dns");
  writeFileSync(scriptFile, script);
  const result = await runChild("python3", ["-c", GUARD_PY, scriptFile, file]);
  expect(result.stderr).toBe("");
  expect(result.stdout.trim()).toBe("True");
}

/**
 * A machine under a temporary root: the command's absolute paths move under
 * it, and `systemctl`, `getent`, `sleep` and the stub's `probe` are fakes on
 * PATH. The stub answers while `state/dns-up` exists; `guard` is the real one.
 * `systemctl` keeps each unit's enabled and active state in `state/`, and the
 * FAKE_* variables make a new stub crash, a restart fail, or a disable fail.
 */
const FAKE_SYSTEMCTL = String.raw`#!/bin/sh
s="$FAKE_ROOT/state"; echo "$*" >> "$s/calls"
start_unit() {
  if [ "$1" = cmux-dns-guard.service ]; then python3 "$FAKE_ROOT/bin/guard.py" "$FAKE_ROOT/usr/local/bin/cmux-dns" "$FAKE_ROOT/etc/resolv.conf" >/dev/null; return 0; fi
  if [ "$1" = cmux-dns.service ] && [ -n "$FAKE_STUB_CRASH" ] && ! grep -q '# previous version' "$FAKE_ROOT/usr/local/bin/cmux-dns"; then rm -f "$s/$1.active"; return 1; fi
  touch "$s/$1.active"
}
cmd=$1; shift
now=; if [ "$1" = --now ]; then now=1; shift; fi
rc=0
for u in "$@"; do
  case "$cmd" in
    is-active) if [ -e "$s/$u.active" ]; then echo active; else echo inactive; rc=3; fi ;;
    is-enabled) if [ -e "$s/$u.enabled" ]; then echo enabled; else echo disabled; rc=1; fi ;;
    enable) touch "$s/$u.enabled"; if [ -n "$now" ]; then start_unit "$u" || rc=1; fi ;;
    disable) if [ -n "$FAKE_DISABLE_FAIL" ]; then rc=1; continue; fi; rm -f "$s/$u.enabled"; if [ -n "$now" ]; then rm -f "$s/$u.active"; fi ;;
    start) start_unit "$u" || rc=1 ;;
    restart) if [ -n "$FAKE_RESTART_FAIL" ]; then rc=1; continue; fi; start_unit "$u" || rc=1 ;;
    try-restart) if [ -e "$s/$u.active" ]; then start_unit "$u" || rc=1; fi ;;
    stop) rm -f "$s/$u.active" ;;
  esac
done
exit $rc`;

/** `realFlock` keeps the host's flock (Linux) instead of the fake, which is busy while `state/locked` exists. */
function fakeMachine(options: { realFlock?: boolean } = {}) {
  const root = fixture();
  for (const dir of ["bin", "state", "run/systemd/system", "etc/systemd/system", "usr/local/bin", "usr/bin"]) {
    mkdirSync(path.join(root, dir), { recursive: true });
  }
  writeFileSync(path.join(root, "etc/resolv.conf"), PLATFORM_RESOLV_CONF);
  writeFileSync(path.join(root, "bin/guard.py"), GUARD_PY);
  const fakes: Record<string, string> = {
    "bin/systemctl": FAKE_SYSTEMCTL,
    "bin/getent": `#!/bin/sh\n[ -e "$FAKE_ROOT/state/dns-up" ]`,
    "bin/sleep": "#!/bin/sh\nexit 0",
    "usr/bin/python3": `#!/bin/sh\nif [ "$2" = probe ]; then [ -e "$FAKE_ROOT/state/dns-up" ]; exit; fi\nexec python3 "$@"`,
    ...(options.realFlock ? {} : { "bin/flock": `#!/bin/sh\n[ ! -e "$FAKE_ROOT/state/locked" ]` }),
  };
  for (const [file, body] of Object.entries(fakes)) {
    writeFileSync(path.join(root, file), `${body}\n`);
    chmodSync(path.join(root, file), 0o755);
  }
  const at = (file: string) => path.join(root, file);
  return {
    at,
    dns: (up: boolean) => (up ? writeFileSync(at("state/dns-up"), "") : rmSync(at("state/dns-up"), { force: true })),
    active: (unit: string) => existsSync(at(`state/${unit}.active`)),
    enabled: (unit: string) => existsSync(at(`state/${unit}.enabled`)),
    calls: () => (existsSync(at("state/calls")) ? readFileSync(at("state/calls"), "utf8") : ""),
    async run(command: string, env: Record<string, string> = {}): Promise<string> {
      const rooted = command.replace(/\/usr\/local\/bin\/cmux-dns|\/etc\/|\/run\/|\/usr\/bin\/python3/g, (match) => root + match);
      const result = await runChild("sh", ["-c", rooted], {
        env: { ...process.env, ...env, FAKE_ROOT: root, PATH: `${at("bin")}:${process.env.PATH ?? ""}` },
      });
      expect(result.status).toBe(0);
      return dnsFallbackResult(result.stdout, result.stderr);
    },
  };
}

const PREVIOUS = `${script}\n# previous version\n`;
/** The real-lock case needs the host's flock (Linux CI); macOS has none. */
const flockTest = ["/usr/bin/flock", "/bin/flock"].some((file) => existsSync(file)) ? test : test.skip;
const BACKUPS = [...FILES, "/etc/resolv.conf"].map((file) => `${file}.cmux-old`);

describe("installing the DNS fallback on a running machine", () => {
  test("a machine without it gets the stub and units byte for byte, and resolv.conf points at the stub", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    expect(await machine.run(dnsFallbackInstallCommand(script))).toBe("OK installed");
    expect(readFileSync(machine.at(DEVBOX_DNS_PATH), "utf8")).toBe(script);
    for (const [file, unit] of Object.entries(DEVBOX_DNS_UNITS)) expect(readFileSync(machine.at(file), "utf8")).toBe(unit);
    expect(readFileSync(machine.at("etc/resolv.conf"), "utf8")).toStartWith("# cmux-dns\n");
    expect(machine.active("cmux-dns.service")).toBe(true);
    for (const file of BACKUPS) expect(existsSync(machine.at(file))).toBe(false);
  });

  test("a machine that already runs this version is left alone", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    await machine.run(dnsFallbackInstallCommand(script));
    writeFileSync(machine.at("state/calls"), "");
    expect(await machine.run(dnsFallbackInstallCommand(script))).toBe("SKIP current");
    expect(machine.calls()).not.toContain("try-restart");
  });

  test("a failed upgrade puts the previous fallback back and starts it again, even when the new stub had stopped", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    await machine.run(dnsFallbackInstallCommand(PREVIOUS));
    expect(await machine.run(dnsFallbackInstallCommand(script), { FAKE_STUB_CRASH: "1" })).toEndWith("(restored the previous fallback)");
    expect(readFileSync(machine.at(DEVBOX_DNS_PATH), "utf8")).toBe(PREVIOUS);
    expect(machine.active("cmux-dns.service")).toBe(true);
    expect(machine.enabled("cmux-dns.service")).toBe(true);
    for (const file of BACKUPS) expect(existsSync(machine.at(file))).toBe(false);
  });

  test("a rollback that cannot start the previous stub says so instead of claiming it worked", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    await machine.run(dnsFallbackInstallCommand(PREVIOUS));
    const result = await machine.run(dnsFallbackInstallCommand(script), { FAKE_STUB_CRASH: "1", FAKE_RESTART_FAIL: "1" });
    expect(result).toStartWith("FAIL ");
    expect(result).toContain("(rollback incomplete");
  });

  test("a failed check on the current version rewrites nothing and restarts nothing", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    await machine.run(dnsFallbackInstallCommand(script));
    machine.dns(false);
    writeFileSync(machine.at("state/calls"), "");
    expect(await machine.run(dnsFallbackInstallCommand(script))).toEndWith("(left the installed fallback in place)");
    expect(readFileSync(machine.at(DEVBOX_DNS_PATH), "utf8")).toBe(script);
    expect(machine.calls()).not.toContain("try-restart");
  });

  test("a failed first install leaves the machine exactly as it was: no files, no units, the same resolv.conf", async () => {
    const machine = fakeMachine();
    machine.dns(false);
    expect(await machine.run(dnsFallbackInstallCommand(script))).toEndWith("(rolled back)");
    for (const file of [...FILES, ...BACKUPS]) expect(existsSync(machine.at(file))).toBe(false);
    for (const unit of ["cmux-dns.service", "cmux-dns-guard.path", "cmux-dns-guard.service"]) {
      expect(machine.active(unit)).toBe(false);
      expect(machine.enabled(unit)).toBe(false);
    }
    expect(readFileSync(machine.at("etc/resolv.conf"), "utf8")).toBe(PLATFORM_RESOLV_CONF);
  });

  test("a resolv.conf the platform did not write is not touched: a VPN, Tailscale or the user owns DNS", async () => {
    const custom = "# resolv.conf(5) file generated by tailscale\nnameserver 100.100.100.100\n";
    const machine = fakeMachine();
    machine.dns(true);
    writeFileSync(machine.at("etc/resolv.conf"), custom);
    expect(await machine.run(dnsFallbackInstallCommand(script))).toBe("SKIP custom-resolv-conf");
    expect(existsSync(machine.at(DEVBOX_DNS_PATH))).toBe(false);
    expect(readFileSync(machine.at("etc/resolv.conf"), "utf8")).toBe(custom);

    const linked = fakeMachine();
    linked.dns(true);
    writeFileSync(linked.at("etc/stub-resolv.conf"), PLATFORM_RESOLV_CONF);
    rmSync(linked.at("etc/resolv.conf"));
    symlinkSync(linked.at("etc/stub-resolv.conf"), linked.at("etc/resolv.conf"));
    expect(await linked.run(dnsFallbackInstallCommand(script))).toBe("SKIP custom-resolv-conf");
    expect(lstatSync(linked.at("etc/resolv.conf")).isSymbolicLink()).toBe(true);
  });

  test("a second run on the same machine waits its turn", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    writeFileSync(machine.at("state/locked"), "");
    expect(await machine.run(dnsFallbackInstallCommand(script))).toBe("SKIP busy");
    expect(existsSync(machine.at(DEVBOX_DNS_PATH))).toBe(false);
    rmSync(machine.at("state/locked"));
    expect(await machine.run(dnsFallbackInstallCommand(script))).toBe("OK installed");
  });

  flockTest("the kernel lock: a run holding it makes the next one wait, and its exit frees it", async () => {
    const machine = fakeMachine({ realFlock: true });
    machine.dns(true);
    const install = dnsFallbackInstallCommand(script);
    const holder = `exec 8>/run/cmux-dns-fleet.lock && flock -n 8 && sh -c ${shellQuote(install)}`;
    expect(await machine.run(holder)).toBe("SKIP busy");
    expect(await machine.run(install)).toBe("OK installed");
  });

  test("--remove takes it off again", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    await machine.run(dnsFallbackInstallCommand(script));
    expect(await machine.run(dnsFallbackUninstallCommand())).toBe("OK removed");
    for (const file of FILES) expect(existsSync(machine.at(file))).toBe(false);
    expect(machine.active("cmux-dns.service")).toBe(false);
    expect(readFileSync(machine.at("etc/resolv.conf"), "utf8")).toBe("options timeout:1 attempts:2\nnameserver 10.32.0.28\n");
  });

  test("--remove that cannot stop the stub says so", async () => {
    const machine = fakeMachine();
    machine.dns(true);
    await machine.run(dnsFallbackInstallCommand(script));
    expect(await machine.run(dnsFallbackUninstallCommand(), { FAKE_DISABLE_FAIL: "1" })).toStartWith("FAIL remove incomplete");
  });

  test("a guest without systemd (a container image) is not touched", async () => {
    const machine = fakeMachine();
    rmSync(machine.at("run/systemd"), { recursive: true });
    expect(await machine.run(dnsFallbackInstallCommand(script))).toBe("SKIP no-systemd");
    expect(existsSync(machine.at(DEVBOX_DNS_PATH))).toBe(false);
    expect(readFileSync(machine.at("etc/resolv.conf"), "utf8")).toBe(PLATFORM_RESOLV_CONF);
  });
});

describe("giving resolv.conf back to the platform", () => {
  test("every recorded resolver, the search line and other options come back", async () => {
    const file = path.join(fixture(), "resolv.conf");
    writeFileSync(file, "search internal\noptions edns0 trust-ad timeout:1 attempts:2\nnameserver 10.32.0.28\nnameserver 2606:4700:4700::1111\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n");
    await guard(file);
    expect(readFileSync(file, "utf8")).toStartWith("# cmux-dns\n");
    expect((await runChild("sh", ["-c", restoreResolvConfCommand(file)])).status).toBe(0);
    expect(readFileSync(file, "utf8")).toBe(
      "search internal\noptions edns0 trust-ad timeout:1 attempts:2\nnameserver 10.32.0.28\nnameserver 2606:4700:4700::1111\nnameserver 8.8.8.8\n",
    );
  });

  test("a resolv.conf the guard never wrote is left alone", async () => {
    const file = path.join(fixture(), "resolv.conf");
    writeFileSync(file, PLATFORM_RESOLV_CONF);
    expect((await runChild("sh", ["-c", restoreResolvConfCommand(file)])).status).toBe(0);
    expect(readFileSync(file, "utf8")).toBe(PLATFORM_RESOLV_CONF);
  });
});

describe("the runner's inputs and results", () => {
  test("a warning on stderr never hides the result line, and no result line is a failure", () => {
    expect(dnsFallbackResult("OK installed\n", "sudo: unable to resolve host\n")).toBe("OK installed");
    expect(dnsFallbackResult("noise\nSKIP current\n")).toBe("SKIP current");
    expect(dnsFallbackResult("", "sudo: a password is required")).toBe("FAIL sudo: a password is required");
    expect(dnsFallbackResult("")).toBe("FAIL no output");
  });

  test("the run stops after a batch with a failure and names the machines it did not start", async () => {
    const ids = ["a", "b", "c", "d", "e"];
    const started: string[] = [];
    const lines: string[] = [];
    const outcome = await runInBatches(ids, async (id) => {
      started.push(id);
      return id === "c" ? "FAIL probe" : "OK installed";
    }, 2, (id, line) => lines.push(`${id} ${line}`));
    expect(started).toEqual(["a", "b", "c", "d"]);
    expect(outcome).toEqual({ failed: 1, notRun: ["e"] });
    expect(lines).toContain("c FAIL probe");
  });

  test("a mistyped machine id or flag stops the run instead of changing what it does", () => {
    const id = `vm-${"a".repeat(32)}`;
    expect(parseMachineIds([id, ` ${id} `, ""])).toEqual([id]);
    expect(() => parseMachineIds([id, "vm-123"])).toThrow("not machine ids: vm-123");
    expect(() => parseMachineIds([])).toThrow("no machines");
    expect(parseFleetArgs(["--vm", id, "--remove"])).toEqual({ vms: [id], vmsFile: undefined, remove: true, dryRun: false });
    expect(() => parseFleetArgs(["--vm", id, "--rollback"])).toThrow("unknown argument: --rollback");
    expect(() => parseFleetArgs(["--vm", "--dry-run"])).toThrow("--vm needs a value");
  });
});
