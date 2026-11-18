import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";
import {
  DEVBOX_EDGE_RESOLVER_PATH_UNIT,
  DEVBOX_EDGE_RESOLVER_SCRIPT,
  DEVBOX_EDGE_RESOLVER_SERVICE,
  DEVBOX_RESOLVER_FALLBACK_DROP_IN,
  FREESTYLE_EDGE_IPV4,
  FREESTYLE_EDGE_IPV6,
  FREESTYLE_TLS_RESOLVER_DROP_IN,
  devboxEdgeResolverCheckCommand,
  devboxEdgeResolverInstallCommand,
  devboxEdgeResolverPathUnit,
  devboxEdgeResolverScript,
  devboxEdgeResolverServiceUnit,
} from "../services/vms/images/dns";
import { freestyleEdgeAddresses } from "../services/vms/drivers/freestyleNetworkPolicy";

// manaflow-ai/cmux#46670: with a TLS rule, the Freestyle agent points the
// guest at the edge's forwarding resolver by its IPv4 address only, and IPv4
// port 53 to it went unanswered on most of the fleet while the same resolver
// answered on IPv6. These tests run the guest fixer against scratch copies of
// the agent's files (byte for byte as seen on vm-a9c9b81f… and a fresh clone,
// 2026-11-18) and pin the bake and verify wiring. The live proof is a machine
// booted from the image (verify-devbox-image.ts).

const BASE_DROP_IN = [
  "# Written by freestyle-vms when this rootfs was built.",
  "[Resolve]",
  "DNS=2606:4700:4700::1111 2001:4860:4860::8888 8.8.8.8 8.8.4.4",
  "",
].join("\n");

const AGENT_TLS_DROP_IN = ["# freestyle-tls forwarding resolver", "[Resolve]", "DNS=", `DNS=${FREESTYLE_EDGE_IPV4}`, "Domains=~.", ""].join("\n");

const AGENT_RESOLV_CONF = ["# freestyle-tls forwarding resolver", "options timeout:1 attempts:2", `nameserver ${FREESTYLE_EDGE_IPV4}`, ""].join("\n");

const FIXED_RESOLV_CONF = [
  "# freestyle-tls forwarding resolver",
  "options timeout:2 attempts:2",
  `nameserver ${FREESTYLE_EDGE_IPV6}`,
  `nameserver ${FREESTYLE_EDGE_IPV4}`,
  "",
].join("\n");

/** The base's resolv.conf the agent restores when the last TLS rule goes. */
const PUBLIC_RESOLV_CONF = "nameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n";

/**
 * systemd-resolved's global server list from a drop-in directory:
 * resolved.conf(5) reads drop-ins in lexical filename order, each `DNS=` line
 * appends its addresses, and an empty `DNS=` clears the list built so far.
 */
function resolvedGlobalServers(dir: string): string[] {
  let servers: string[] = [];
  for (const name of readdirSync(dir).filter((file) => file.endsWith(".conf")).sort()) {
    let section = "";
    for (const raw of readFileSync(path.join(dir, name), "utf8").split("\n")) {
      const line = raw.trim();
      if (line.startsWith("#") || line === "") continue;
      if (line.startsWith("[")) {
        section = line;
        continue;
      }
      if (section !== "[Resolve]" || !line.startsWith("DNS=")) continue;
      const value = line.slice("DNS=".length).trim();
      servers = value === "" ? [] : [...servers, ...value.split(/\s+/)];
    }
  }
  return servers;
}

type Guest = {
  readonly root: string;
  readonly resolv: string;
  readonly dropIns: string;
  /** Runs the fixer; returns how many times it asked resolved to reload. */
  readonly run: () => Promise<number>;
  readonly reloads: () => number;
};

async function withGuest(setup: (guest: Guest) => void, body: (guest: Guest) => Promise<void>): Promise<void> {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-edge-resolver-"));
  const script = path.join(root, "cmux-edge-resolver");
  const dropIns = path.join(root, "resolved.conf.d");
  const resolv = path.join(root, "resolv.conf");
  const reloadLog = path.join(root, "reloads");
  writeFileSync(script, devboxEdgeResolverScript(), { mode: 0o755 });
  writeFileSync(reloadLog, "");
  const reloadScript = path.join(root, "reload");
  writeFileSync(reloadScript, `#!/bin/sh\necho reload >> '${reloadLog}'\n`, { mode: 0o755 });
  mkdirSync(dropIns);
  const reloads = () => readFileSync(reloadLog, "utf8").split("\n").filter(Boolean).length;
  const guest: Guest = {
    root,
    resolv,
    dropIns,
    reloads,
    run: async () => {
      const before = reloads();
      const result = await runChild("sh", [script], {
        env: { ...process.env, CMUX_RESOLV_CONF: resolv, CMUX_RESOLVED_DROP_IN_DIR: dropIns, CMUX_RESOLVED_RELOAD: reloadScript },
      });
      expect({ status: result.status, stderr: result.stderr }).toEqual({ status: 0, stderr: "" });
      expect(readdirSync(root).concat(readdirSync(dropIns)).filter((name) => name.endsWith(".cmux-tmp"))).toEqual([]);
      return reloads() - before;
    },
  };
  try {
    setup(guest);
    await body(guest);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const tlsMachine = (guest: Guest) => {
  writeFileSync(path.join(guest.dropIns, "60-freestyle-vms.conf"), BASE_DROP_IN);
  writeFileSync(path.join(guest.dropIns, FREESTYLE_TLS_RESOLVER_DROP_IN), AGENT_TLS_DROP_IN);
  writeFileSync(guest.resolv, AGENT_RESOLV_CONF);
};

describe("cmux-edge-resolver (services/vms/images/dns.ts)", () => {
  test("the script is valid POSIX sh", async () => {
    const run = await runChild("sh", ["-n", "-c", devboxEdgeResolverScript()]);
    expect({ status: run.status, stderr: run.stderr }).toEqual({ status: 0, stderr: "" });
  });

  test("a TLS-rule machine: glibc and resolved both get the IPv6 listener first, the agent's IPv4 second", async () => {
    await withGuest(tlsMachine, async (guest) => {
      // The reported failure: one IPv4 server in both places.
      expect(resolvedGlobalServers(guest.dropIns)).toEqual([FREESTYLE_EDGE_IPV4]);
      expect(await guest.run()).toBe(1);
      expect(readFileSync(guest.resolv, "utf8")).toBe(FIXED_RESOLV_CONF);
      expect(statSync(guest.resolv).mode & 0o777).toBe(0o644);
      expect(resolvedGlobalServers(guest.dropIns)).toEqual([FREESTYLE_EDGE_IPV6, FREESTYLE_EDGE_IPV4]);
      expect(readdirSync(guest.dropIns).sort()).toEqual(["60-freestyle-vms.conf", FREESTYLE_TLS_RESOLVER_DROP_IN, DEVBOX_RESOLVER_FALLBACK_DROP_IN]);
    });
  });

  test("a second run changes nothing and does not reload resolved (the path unit re-fires on its own write)", async () => {
    await withGuest(tlsMachine, async (guest) => {
      await guest.run();
      const resolvMtime = statSync(guest.resolv).mtimeMs;
      const ours = path.join(guest.dropIns, DEVBOX_RESOLVER_FALLBACK_DROP_IN);
      const oursMtime = statSync(ours).mtimeMs;
      await new Promise((resolve) => setTimeout(resolve, 20));
      expect(await guest.run()).toBe(0);
      expect(statSync(guest.resolv).mtimeMs).toBe(resolvMtime);
      expect(statSync(ours).mtimeMs).toBe(oursMtime);
    });
  });

  test("the agent rewriting its files puts the fix back on the next run", async () => {
    await withGuest(tlsMachine, async (guest) => {
      await guest.run();
      writeFileSync(guest.resolv, AGENT_RESOLV_CONF);
      writeFileSync(path.join(guest.dropIns, FREESTYLE_TLS_RESOLVER_DROP_IN), AGENT_TLS_DROP_IN);
      expect(await guest.run()).toBe(0);
      expect(readFileSync(guest.resolv, "utf8")).toBe(FIXED_RESOLV_CONF);
      expect(resolvedGlobalServers(guest.dropIns)).toEqual([FREESTYLE_EDGE_IPV6, FREESTYLE_EDGE_IPV4]);
    });
  });

  test("a resolv.conf that already lists the IPv6 listener only gets the timeout raised, never a duplicate", async () => {
    await withGuest((guest) => {
      tlsMachine(guest);
      writeFileSync(guest.resolv, AGENT_RESOLV_CONF + `nameserver ${FREESTYLE_EDGE_IPV6}\n`);
    }, async (guest) => {
      await guest.run();
      const text = readFileSync(guest.resolv, "utf8");
      expect(text.split("\n").filter((line) => line === `nameserver ${FREESTYLE_EDGE_IPV6}`)).toHaveLength(1);
      expect(text).toContain("options timeout:2 attempts:2\n");
    });
  });

  test("the last TLS rule removed: cmux's drop-in goes too and the base's public resolvers apply", async () => {
    await withGuest(tlsMachine, async (guest) => {
      await guest.run();
      rmSync(path.join(guest.dropIns, FREESTYLE_TLS_RESOLVER_DROP_IN));
      writeFileSync(guest.resolv, PUBLIC_RESOLV_CONF);
      expect(await guest.run()).toBe(1);
      expect(readdirSync(guest.dropIns)).toEqual(["60-freestyle-vms.conf"]);
      expect(resolvedGlobalServers(guest.dropIns)).toEqual(["2606:4700:4700::1111", "2001:4860:4860::8888", "8.8.8.8", "8.8.4.4"]);
      expect(readFileSync(guest.resolv, "utf8")).toBe(PUBLIC_RESOLV_CONF);
    });
  });

  test("a machine with no TLS rule is left exactly as it is", async () => {
    await withGuest((guest) => {
      writeFileSync(path.join(guest.dropIns, "60-freestyle-vms.conf"), BASE_DROP_IN);
      writeFileSync(guest.resolv, PUBLIC_RESOLV_CONF);
    }, async (guest) => {
      expect(await guest.run()).toBe(0);
      expect(readdirSync(guest.dropIns)).toEqual(["60-freestyle-vms.conf"]);
      expect(readFileSync(guest.resolv, "utf8")).toBe(PUBLIC_RESOLV_CONF);
    });
  });

  test("a resolv.conf that is not the agent's (a user's, a VPN's, a stub symlink) is never touched", async () => {
    const own = `# mine\noptions timeout:1\nnameserver ${FREESTYLE_EDGE_IPV4}\n`;
    await withGuest((guest) => {
      tlsMachine(guest);
      writeFileSync(guest.resolv, own);
    }, async (guest) => {
      await guest.run();
      expect(readFileSync(guest.resolv, "utf8")).toBe(own);
    });
    await withGuest((guest) => {
      tlsMachine(guest);
      rmSync(guest.resolv);
      writeFileSync(path.join(guest.root, "stub-resolv.conf"), AGENT_RESOLV_CONF);
      symlinkSync(path.join(guest.root, "stub-resolv.conf"), guest.resolv);
    }, async (guest) => {
      await guest.run();
      expect(readFileSync(path.join(guest.root, "stub-resolv.conf"), "utf8")).toBe(AGENT_RESOLV_CONF);
      // resolved still gets the fallback through its drop-in.
      expect(resolvedGlobalServers(guest.dropIns)).toEqual([FREESTYLE_EDGE_IPV6, FREESTYLE_EDGE_IPV4]);
    });
  });

  test("a user's later drop-in that resets DNS still wins", async () => {
    await withGuest((guest) => {
      tlsMachine(guest);
      writeFileSync(path.join(guest.dropIns, "70-user-dns.conf"), "[Resolve]\nDNS=\nDNS=1.1.1.1\n");
    }, async (guest) => {
      await guest.run();
      expect(resolvedGlobalServers(guest.dropIns)).toEqual(["1.1.1.1"]);
    });
  });

  test("the units: the path unit watches both agent files; the oneshot also runs at boot and is never rate-limited", () => {
    const pathUnit = devboxEdgeResolverPathUnit();
    expect(pathUnit).toContain("PathChanged=/etc/resolv.conf\n");
    expect(pathUnit).toContain(`PathChanged=/etc/systemd/resolved.conf.d/${FREESTYLE_TLS_RESOLVER_DROP_IN}\n`);
    expect(pathUnit).toContain(`Unit=${DEVBOX_EDGE_RESOLVER_SERVICE}\n`);
    expect(pathUnit).toContain("WantedBy=paths.target\n");
    const service = devboxEdgeResolverServiceUnit();
    expect(service).toContain("Type=oneshot\n");
    expect(service).toContain(`ExecStart=${DEVBOX_EDGE_RESOLVER_SCRIPT}\n`);
    expect(service).toContain("StartLimitIntervalSec=0\n");
    expect(service).toContain("WantedBy=multi-user.target\n");
  });

  test("install writes all three files, enables both units, and runs the fixer once; the check proves it", () => {
    const install = devboxEdgeResolverInstallCommand();
    expect(install).toContain(`mv -f '${DEVBOX_EDGE_RESOLVER_SCRIPT}.cmux-tmp' '${DEVBOX_EDGE_RESOLVER_SCRIPT}'`);
    expect(install).toContain(`'/etc/systemd/system/${DEVBOX_EDGE_RESOLVER_SERVICE}'`);
    expect(install).toContain(`'/etc/systemd/system/${DEVBOX_EDGE_RESOLVER_PATH_UNIT}'`);
    expect(install).toContain(`systemctl enable --now ${DEVBOX_EDGE_RESOLVER_PATH_UNIT}`);
    expect(install.endsWith(`systemctl start ${DEVBOX_EDGE_RESOLVER_SERVICE}`)).toBe(true);
    const check = devboxEdgeResolverCheckCommand();
    expect(check).toContain(`systemctl is-active --quiet ${DEVBOX_EDGE_RESOLVER_PATH_UNIT}`);
    expect(check).toContain(`grep -qxF 'nameserver ${FREESTYLE_EDGE_IPV6}' /etc/resolv.conf`);
    expect(check.endsWith("echo edge-resolver-ipv6-ok")).toBe(true);
  });

  test("install writes the script and both units byte for byte, then enables and starts them", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-edge-install-"));
    try {
      const bin = path.join(root, "bin");
      mkdirSync(bin);
      const calls = path.join(root, "systemctl.calls");
      writeFileSync(path.join(bin, "systemctl"), `#!/bin/sh\necho "$*" >> ${calls}\n`, { mode: 0o755 });
      const install = devboxEdgeResolverInstallCommand()
        .replaceAll("/usr/local/libexec", `${root}/libexec`)
        .replaceAll("/etc/systemd/system", `${root}/system`);
      const run = await runChild("bash", ["-c", install], { env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` } });
      expect({ status: run.status, stderr: run.stderr }).toEqual({ status: 0, stderr: "" });
      const script = path.join(root, "libexec", "cmux-edge-resolver");
      expect(readFileSync(script, "utf8")).toBe(devboxEdgeResolverScript());
      expect(statSync(script).mode & 0o777).toBe(0o755);
      expect(readFileSync(path.join(root, "system", DEVBOX_EDGE_RESOLVER_SERVICE), "utf8"))
        .toBe(devboxEdgeResolverServiceUnit().replace("/usr/local/libexec", `${root}/libexec`));
      expect(readFileSync(path.join(root, "system", DEVBOX_EDGE_RESOLVER_PATH_UNIT), "utf8")).toBe(devboxEdgeResolverPathUnit());
      expect(readdirSync(path.join(root, "system")).filter((name) => name.endsWith(".cmux-tmp"))).toEqual([]);
      expect(readFileSync(calls, "utf8").trim().split("\n")).toEqual([
        "daemon-reload",
        `enable ${DEVBOX_EDGE_RESOLVER_SERVICE}`,
        `enable --now ${DEVBOX_EDGE_RESOLVER_PATH_UNIT}`,
        `start ${DEVBOX_EDGE_RESOLVER_SERVICE}`,
      ]);
      expect(existsSync(`${script}.cmux-tmp`)).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the firewall's edge grant and the guest's resolver name the same edge", () => {
    expect(freestyleEdgeAddresses({} as NodeJS.ProcessEnv)).toEqual([`${FREESTYLE_EDGE_IPV6}/128`, `${FREESTYLE_EDGE_IPV4}/32`]);
  });

  test("the bake installs and checks it before the stamp; the verifier proves it on a booted clone", () => {
    const bake = readFileSync(path.join(import.meta.dirname, "../scripts/build-devbox-freestyle.ts"), "utf8");
    expect(bake).toContain('await step("edge-resolver-ipv6", `${devboxEdgeResolverInstallCommand()} && ${devboxEdgeResolverCheckCommand()}`);');
    expect(bake.indexOf('step("edge-resolver-ipv6"')).toBeGreaterThan(bake.indexOf('step("identity"'));
    expect(bake.indexOf('step("edge-resolver-ipv6"')).toBeLessThan(bake.indexOf('"image-stamp",'));
    const verify = readFileSync(path.join(import.meta.dirname, "../scripts/verify-devbox-image.ts"), "utf8");
    expect(verify).toContain("devboxEdgeResolverCheckCommand(),");
    expect(verify).toContain("...RESOLVER_CHECKS,");
  });
});
