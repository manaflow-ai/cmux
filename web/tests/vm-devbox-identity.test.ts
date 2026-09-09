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
import { DEVBOX_HOSTNAME, DEVBOX_HOSTNAME_LOOPBACK, DEVBOX_PROVIDER_HOSTNAME } from "../services/vms/images/identity";

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
