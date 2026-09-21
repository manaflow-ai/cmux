import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  DEVBOX_IDENTITY_RESIDUE_ROOTS,
  devboxHostsAliasRewriteCommand,
  devboxIdentityCheckCommand,
  devboxIdentityInstallCommand,
  devboxProviderResidueCommand,
  devboxSshHostKeyRegenerateCommand,
} from "../scripts/devbox-image-common";
import { shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";
import { freestyleNetworkAnnouncementCommand } from "../services/vms/drivers/freestyleNetworkAnnouncement";
import { DEVBOX_HOSTNAME, DEVBOX_HOSTNAME_LOOPBACK, DEVBOX_PROVIDER_HOSTNAME } from "../services/vms/images/identity";
import { devboxNetworkAnnounceCommand } from "../services/vms/images/network";

// The devbox identity contract (services/vms/images/identity.ts): a cmux Cloud
// machine is `cmux`, never the Freestyle base's `freestyle-vm`. The shell that
// renames it and the audit that hunts the old name run here against real
// files; the bake, verify, derive and boot-supervisor wiring is pinned so the
// contract cannot silently drop out of any of them. The live proof is
// verify-devbox-image.ts on a machine booted from the snapshot.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const scriptsDir = path.join(import.meta.dirname, "../scripts");
const readScript = (name: string) => readFileSync(path.join(scriptsDir, name), "utf8");
const devboxBoot = readFileSync(path.join(templateDir, "cmux-devbox-boot"), "utf8");
describe("devbox identity contract (services/vms/images/identity.ts)", () => {
  // /etc/hosts as a cmux Cloud machine on the pre-contract image carried it:
  // the base's alias line plus the block the Freestyle agent keeps for its
  // TLS edge. The rewrite may touch nothing but the alias.
  const providerHosts = [
    "127.0.0.1\tlocalhost",
    "127.0.1.1\tfreestyle-vm",
    "::1\tlocalhost ip6-localhost ip6-loopback",
    "ff02::1\tip6-allnodes",
    "ff02::2\tip6-allrouters",
    "",
    "# BEGIN freestyle-tls-egress",
    "10.32.0.28 coderouter.cmux.internal",
    "2602:f470:1::28 coderouter.cmux.internal",
    "# END freestyle-tls-egress",
    "",
  ].join("\n");
  const rewrite = (contents: string): string => {
    const dir = mkdtempSync(path.join(tmpdir(), "cmux-identity-"));
    try {
      const hosts = path.join(dir, "hosts");
      writeFileSync(hosts, contents);
      const run = spawnSync("bash", ["-c", devboxHostsAliasRewriteCommand(DEVBOX_HOSTNAME, hosts)], { encoding: "utf8" });
      expect({ status: run.status, stderr: run.stderr }).toEqual({ status: 0, stderr: "" });
      expect(existsSync(`${hosts}.cmux-identity`)).toBe(false);
      return readFileSync(hosts, "utf8");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  test("the machine is cmux; the provider's name is what the audit hunts", () => {
    expect(DEVBOX_HOSTNAME).toBe("cmux");
    expect(DEVBOX_PROVIDER_HOSTNAME).toBe("freestyle-vm");
    expect(DEVBOX_HOSTNAME_LOOPBACK).toBe("127.0.1.1");
    expect(DEVBOX_IDENTITY_RESIDUE_ROOTS).toEqual(["/etc", "/home", "/root", "/usr/local", "/opt"]);
  });

  test("the hosts rewrite renames only the loopback alias line", () => {
    expect(rewrite(providerHosts)).toBe(providerHosts.replace("127.0.1.1\tfreestyle-vm", "127.0.1.1\tcmux"));
  });

  test("the hosts rewrite is idempotent, keeps one alias, and adds a missing one", () => {
    const once = rewrite(providerHosts);
    expect(rewrite(once)).toBe(once);
    expect(rewrite("127.0.1.1 a\n127.0.0.1\tlocalhost\n127.0.1.1 b\n")).toBe("127.0.1.1\tcmux\n127.0.0.1\tlocalhost\n");
    expect(rewrite("127.0.0.1\tlocalhost\n")).toBe("127.0.0.1\tlocalhost\n127.0.1.1\tcmux\n");
  });

  test("the residue audit matches the base's name as a whole word, never the provider's platform naming", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "cmux-residue-"));
    try {
      // The provider's own naming and a package tree mentioning the name: allowed.
      writeFileSync(path.join(dir, "60-freestyle-vms.conf"), "# Written by freestyle-vms when this rootfs was built.\n");
      writeFileSync(path.join(dir, "agent.service"), "ExecStart=/sbin/freestyle-vms-agent\n");
      mkdirSync(path.join(dir, "node_modules"));
      writeFileSync(path.join(dir, "node_modules", "readme.md"), "tested on freestyle-vm\n");
      const clean = spawnSync("bash", ["-c", devboxProviderResidueCommand(DEVBOX_PROVIDER_HOSTNAME, [dir])], { encoding: "utf8" });
      expect({ status: clean.status, stdout: clean.stdout, stderr: clean.stderr }).toEqual({ status: 0, stdout: "", stderr: "" });
      // The base's name where the machine speaks for itself: residue, named.
      writeFileSync(path.join(dir, "ssh_host_ed25519_key.pub"), "ssh-ed25519 AAAA root@freestyle-vm\n");
      const dirty = spawnSync("bash", ["-c", devboxProviderResidueCommand(DEVBOX_PROVIDER_HOSTNAME, [dir])], { encoding: "utf8" });
      expect(dirty.status).toBe(1);
      expect(dirty.stdout).toContain("freestyle-vm residue:");
      expect(dirty.stdout).toContain("ssh_host_ed25519_key.pub");
      expect(dirty.stdout).not.toContain("60-freestyle-vms.conf");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the bake renames the machine first and re-checks last; verify and derive prove it on booted machines", () => {
    const install = devboxIdentityInstallCommand();
    expect(install).toContain("hostnamectl set-hostname cmux");
    expect(install).toContain("> /etc/hostname");
    expect(install).toContain(devboxHostsAliasRewriteCommand());
    expect(install).toContain(devboxSshHostKeyRegenerateCommand());
    expect(install).toContain(devboxIdentityCheckCommand());
    const check = devboxIdentityCheckCommand();
    expect(check).toContain('[ "$(hostname)" = cmux ]');
    expect(check).toContain('[ "$(cat /etc/hostname)" = cmux ]');
    expect(check).toContain("getent hosts cmux");
    expect(check).toContain("unable to resolve host");
    expect(check).toContain("= root@cmux ]");
    expect(check).toContain(devboxProviderResidueCommand());
    // Order in the bake: inventory, identity, every layer (the daemon included),
    // the re-check, the stamp; the cleanup starts the journal over.
    const bake = readScript("build-devbox-freestyle.ts");
    const inventory = bake.indexOf('"base-inventory"');
    const identity = bake.indexOf('await step("identity", devboxIdentityInstallCommand());');
    const daemon = bake.indexOf('await step("cmux-tui-install"');
    const final = bake.indexOf('await step("identity-final", devboxIdentityCheckCommand());');
    const stamp = bake.indexOf('"image-stamp"');
    expect(inventory).toBeGreaterThan(-1);
    expect(identity).toBeGreaterThan(inventory);
    expect(daemon).toBeGreaterThan(identity);
    expect(final).toBeGreaterThan(daemon);
    expect(stamp).toBeGreaterThan(final);
    expect(bake).toContain("${devboxJournalResetCommand}; sync; true");
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("devboxIdentityCheckCommand()");
    expect(verify).toContain("...IDENTITY_CHECKS");
    expect(verify).toContain("root-prompt-names-${DEVBOX_HOSTNAME}");
    // The pty probes synchronize on the shell's own readiness signal, not a fixed delay.
    expect(verify).toContain("PROMPT_COMMAND='tmux -L idroot wait-for -S prompt'");
    expect(verify).toContain("PROMPT_COMMAND='tmux -L iduser wait-for -S prompt'");
    expect(verify).toContain("user-prompt-names-${DEVBOX_HOSTNAME}");
    expect(verify).toContain("journal-host-${DEVBOX_HOSTNAME}");
    expect(verify).toContain("share one SSH host key");
    const derive = readScript("derive-devbox-sizes.ts");
    expect(derive).toContain("echo host=$(hostname)");
    expect(derive).toContain("assertIdentity(`master ${master}`, masterShape);");
    expect(derive).toContain("assertIdentity(`${name}: derived snapshot ${imageId}`, measured);");
  });

  test("the boot supervisor gives every clone its own SSH host keys, off the daemon's start path", () => {
    expect(devboxBoot).toContain("rekey_ssh_host() {");
    // Staged: the new keys exist before the old ones are replaced, a failed
    // generation keeps the previous keys and says so, sshd restarts last.
    expect(devboxBoot).toContain('ssh-keygen -A -f "$staging"');
    expect(devboxBoot).toContain('mv -f "$key.pub" /etc/ssh/ && mv -f "$key" /etc/ssh/');
    expect(devboxBoot).toContain("ssh host key generation failed; keeping the existing keys");
    expect(devboxBoot).not.toContain("rm -f /etc/ssh/ssh_host_*_key");
    expect(devboxBoot).toContain("systemctl try-restart ssh");
    const regenerate = devboxSshHostKeyRegenerateCommand();
    expect(regenerate).toContain('ssh-keygen -A -f "$staging"');
    expect(regenerate).toContain('mv -f "$key.pub" /etc/ssh/ && mv -f "$key" /etc/ssh/');
    expect(regenerate).not.toContain("rm -f /etc/ssh/ssh_host_*_key");
    // Detached: a subshell backgrounds the job and exits, so the loop never
    // waits on it, the daemon starts in the same tick, and no zombie is left.
    expect(devboxBoot).toContain("( rekey_ssh_host & )");
    const wipe = devboxBoot.indexOf('rm -rf "$REMOTE_STATE_DIR"');
    const rekey = devboxBoot.indexOf("( rekey_ssh_host & )");
    const bound = devboxBoot.indexOf(`printf '%s\\n' "$id" > "$BOUND_INSTANCE_FILE"`);
    expect(wipe).toBeGreaterThan(-1);
    expect(rekey).toBeGreaterThan(wipe);
    expect(bound).toBeGreaterThan(rekey);
  });
});

// The private-network announce (services/vms/images/network.ts): the VPC
// fabric forwards to a machine only after a frame from it, and a clone sends
// none by itself. The shell runs here against fake `ip` and `arping` binaries;
// the boot supervisor, the attach path, the image and its verify are pinned.
describe("devbox private-network announce (services/vms/images/network.ts)", () => {
  type FakeNet = {
    /** `ip -o -4 addr show scope global` output. */
    readonly v4?: string;
    /** `ip -o -6 addr show scope global` output. */
    readonly v6?: string;
    /** A fake python3 that records the script and the address list it was handed (default); false leaves PATH without one. */
    readonly python3?: boolean;
    /** PATH is the fixture dir alone (fakes only; the command must not need anything else). */
    readonly fakesOnly?: boolean;
  };
  type FakeNetLogs = { readonly arping: string; readonly python3: string; readonly script: string };
  const withFakeNet = (net: FakeNet, run: (env: NodeJS.ProcessEnv, logs: FakeNetLogs) => void) => {
    const dir = mkdtempSync(path.join(tmpdir(), "cmux-announce-"));
    try {
      const logs = { arping: path.join(dir, "arping.log"), python3: path.join(dir, "python3.log"), script: path.join(dir, "python3.script") };
      writeFileSync(path.join(dir, "ip"), [
        "#!/bin/sh",
        'case "$*" in',
        `  "-o -4 addr show scope global") /bin/cat <<'EOF'\n${net.v4 ?? ""}EOF\n;;`,
        `  "-o -6 addr show scope global") /bin/cat <<'EOF'\n${net.v6 ?? ""}EOF\n;;`,
        '  *) echo "unexpected ip $*" >&2; exit 2;;',
        "esac",
        "",
      ].join("\n"), { mode: 0o755 });
      writeFileSync(path.join(dir, "arping"), `#!/bin/sh\necho "$*" >> ${JSON.stringify(logs.arping)}\n`, { mode: 0o755 });
      if (net.python3 !== false) {
        writeFileSync(path.join(dir, "python3"), `#!/bin/sh\n[ "$1" = -c ] || exit 2\nprintf '%s' "$2" > ${JSON.stringify(logs.script)}\nprintf '%s\\n' "$3" >> ${JSON.stringify(logs.python3)}\n`, { mode: 0o755 });
      }
      run({ ...process.env, PATH: net.fakesOnly ? dir : `${dir}:${process.env.PATH ?? ""}` }, logs);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  const v4Addresses =
    "2: eth0    inet 169.254.77.2/30 scope global eth0\\       valid_lft forever\n" +
    "3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\\       valid_lft forever\n" +
    "4: veth1a2b    inet 172.18.0.2/16 scope global veth1a2b\\       valid_lft forever\n" +
    "5: eth0.164    inet 10.16.162.53/24 brd 10.16.162.255 scope global eth0.164\\       valid_lft forever\n" +
    "6: eth1    inet 10.16.163.7/24 scope global eth1\\       valid_lft forever\n";
  const v6Addresses =
    "2: eth0    inet6 2602:f470:1::28/64 scope global \\       valid_lft forever preferred_lft forever\n" +
    "3: docker0    inet6 fd12:3456:789a::1/64 scope global \\       valid_lft forever preferred_lft forever\n" +
    "4: veth1a2b    inet6 fd12:3456:789a::2/64 scope global \\       valid_lft forever preferred_lft forever\n" +
    "5: eth0.164    inet6 fd00:4::7/64 scope global \\       valid_lft forever preferred_lft forever\n";

  test("announces every global IPv4 on a real interface, two unsolicited probes each, and skips container bridges and the provider's link-local leg", () => {
    withFakeNet({ v4: v4Addresses }, (env, logs) => {
      const result = spawnSync("sh", ["-c", devboxNetworkAnnounceCommand()], { env, encoding: "utf8" });
      expect(result.status).toBe(0);
      expect(readFileSync(logs.arping, "utf8").trim().split("\n").sort()).toEqual([
        "-U -c 2 -w 2 -I eth0.164 10.16.162.53",
        "-U -c 2 -w 2 -I eth1 10.16.163.7",
      ]);
      // No IPv6 address, no neighbor advertisement.
      expect(existsSync(logs.python3)).toBe(false);
    });
  });

  test("announces every global IPv6 on a real interface with the attach path's own neighbor-advertisement script, skipping container interfaces", () => {
    // A private Freestyle network can assign either family (the Mac dials
    // whichever answers), and the fabric learns an IPv6 neighbor the same
    // way: only from a frame the guest sends. One unsolicited NA per
    // address, sent by the python raw-socket announcer the attach path
    // already runs (drivers/freestyleNetworkAnnouncement.ts): one
    // implementation, handed the addresses the supervisor found.
    withFakeNet({ v4: v4Addresses, v6: v6Addresses }, (env, logs) => {
      const result = spawnSync("sh", ["-c", devboxNetworkAnnounceCommand()], { env, encoding: "utf8" });
      expect({ status: result.status, stderr: result.stderr }).toEqual({ status: 0, stderr: "" });
      expect(readFileSync(logs.python3, "utf8")).toBe('["2602:f470:1::28","fd00:4::7"]\n');
      const script = readFileSync(logs.script, "utf8");
      expect(script).toContain("IPPROTO_ICMPV6");
      expect(freestyleNetworkAnnouncementCommand(["fd00:4::7"])).toBe(`python3 -c ${shellQuote(script)} ${shellQuote('["fd00:4::7"]')}`);
      // The IPv4 burst is unchanged next to it.
      expect(readFileSync(logs.arping, "utf8").trim().split("\n").sort()).toEqual([
        "-U -c 2 -w 2 -I eth0.164 10.16.162.53",
        "-U -c 2 -w 2 -I eth1 10.16.163.7",
      ]);
    });
  });

  test("the IPv6 announce is a successful no-op without python3, and the IPv4 burst still runs", () => {
    withFakeNet({ v4: v4Addresses, v6: v6Addresses, python3: false, fakesOnly: true }, (env, logs) => {
      // /bin/sh by absolute path: PATH holds only the fakes.
      const result = spawnSync("/bin/sh", ["-c", devboxNetworkAnnounceCommand()], { env, encoding: "utf8" });
      expect(result.status).toBe(0);
      expect(readFileSync(logs.arping, "utf8")).toContain("-U -c 2 -w 2 -I eth1 10.16.163.7");
      expect(existsSync(logs.python3)).toBe(false);
    });
  });

  test("is a successful no-op with no global address and without arping", () => {
    withFakeNet({}, (env, logs) => {
      const result = spawnSync("sh", ["-c", devboxNetworkAnnounceCommand()], { env, encoding: "utf8" });
      expect(result.status).toBe(0);
      expect(existsSync(logs.arping)).toBe(false);
      expect(existsSync(logs.python3)).toBe(false);
    });
    const empty = mkdtempSync(path.join(tmpdir(), "cmux-noarping-"));
    try {
      // PATH holds only the empty dir, so `command -v arping` cannot find a host
      // binary; /bin/sh is invoked by absolute path and needs no PATH.
      const result = spawnSync("/bin/sh", ["-c", devboxNetworkAnnounceCommand()], {
        env: { ...process.env, PATH: empty },
        encoding: "utf8",
      });
      expect(result.status).toBe(0);
    } finally {
      rmSync(empty, { recursive: true, force: true });
    }
  });

  test("the boot supervisor announces on every clone and keeps announcing for the life of the machine", () => {
    // The very command the attach path runs, so the two cannot drift.
    expect(devboxBoot).toContain(`announce_network() {\n  ${devboxNetworkAnnounceCommand()}\n}`);
    // Periodic: started once, before the supervisor loop, as a job of the
    // supervisor (not detached) so a restarted supervisor never doubles it.
    expect(devboxBoot).toContain("announce_loop() {\n  while true; do announce_network; sleep 30; done\n}");
    expect(devboxBoot.indexOf("\nannounce_loop &\n")).toBeGreaterThan(-1);
    expect(devboxBoot.indexOf("\nannounce_loop &\n")).toBeLessThan(devboxBoot.indexOf("\nwhile true; do\n"));
    // On a clone: detached, right after the SSH rekey, before the machine is bound.
    const rekey = devboxBoot.indexOf("( rekey_ssh_host & )");
    const announce = devboxBoot.indexOf("( announce_network & )");
    const bound = devboxBoot.indexOf(`printf '%s\\n' "$id" > "$BOUND_INSTANCE_FILE"`);
    expect(announce).toBeGreaterThan(rekey);
    expect(bound).toBeGreaterThan(announce);
  });

  test("the image installs arping and verify proves the announce loop on a booted machine", () => {
    expect(readFileSync(path.join(templateDir, "Dockerfile"), "utf8")).toContain("    iputils-arping \\\n");
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("command -v arping && pgrep -f 'cmux-devbox-[b]oot' >/dev/null && grep -q 'announce_loop &' /usr/local/bin/cmux-devbox-boot && echo network-announce-ok");
  });
});
