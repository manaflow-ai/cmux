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
  devboxParkDaemonCommand,
  devboxPrepareTemplateTerminalCommand,
  devboxSshHostKeyRegenerateCommand,
  devboxWipeDaemonStateKeepingTemplateCommand,
} from "../scripts/devbox-image-common";
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
    const rekey = devboxBoot.indexOf("( rekey_ssh_host & )");
    const bound = devboxBoot.indexOf(`printf '%s\\n' "$id" > "$BOUND_INSTANCE_FILE"`);
    const daemonStart = devboxBoot.indexOf("start_daemon", bound);
    expect(bound).toBeGreaterThan(-1);
    // The daemon starts before key generation competes for the clone's CPU,
    // and key generation runs at the lowest CPU and I/O priority.
    expect(daemonStart).toBeGreaterThan(bound);
    expect(rekey).toBeGreaterThan(daemonStart);
    expect(devboxBoot).toContain('low="nice -n 19"');
  });
});

// The private-network announce (services/vms/images/network.ts): the VPC
// fabric forwards to a machine only after a frame from it, and a clone sends
// none by itself. The shell runs here against fake `ip` and `arping` binaries;
// the boot supervisor, the attach path, the image and its verify are pinned.
describe("devbox private-network announce (services/vms/images/network.ts)", () => {
  const withFakeNet = (addrs: string, run: (env: NodeJS.ProcessEnv, log: string) => void) => {
    const dir = mkdtempSync(path.join(tmpdir(), "cmux-announce-"));
    try {
      const log = path.join(dir, "arping.log");
      writeFileSync(path.join(dir, "ip"), `#!/bin/sh\n[ "$*" = "-o -4 addr show scope global" ] || { echo "unexpected ip $*" >&2; exit 2; }\ncat <<'EOF'\n${addrs}EOF\n`, { mode: 0o755 });
      writeFileSync(path.join(dir, "arping"), `#!/bin/sh\necho "$*" >> ${JSON.stringify(log)}\n`, { mode: 0o755 });
      run({ ...process.env, PATH: `${dir}:${process.env.PATH ?? ""}` }, log);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  test("announces every global IPv4 on a real interface, two unsolicited probes each, and skips container bridges and the provider's link-local leg", () => {
    withFakeNet(
      "2: eth0    inet 169.254.77.2/30 scope global eth0\\       valid_lft forever\n" +
        "3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\\       valid_lft forever\n" +
        "4: veth1a2b    inet 172.18.0.2/16 scope global veth1a2b\\       valid_lft forever\n" +
        "5: eth0.164    inet 10.16.162.53/24 brd 10.16.162.255 scope global eth0.164\\       valid_lft forever\n" +
        "6: eth1    inet 10.16.163.7/24 scope global eth1\\       valid_lft forever\n",
      (env, log) => {
        const result = spawnSync("sh", ["-c", devboxNetworkAnnounceCommand()], { env, encoding: "utf8" });
        expect(result.status).toBe(0);
        expect(readFileSync(log, "utf8").trim().split("\n").sort()).toEqual([
          "-U -c 2 -w 2 -I eth0.164 10.16.162.53",
          "-U -c 2 -w 2 -I eth1 10.16.163.7",
        ]);
      },
    );
  });

  test("is a successful no-op with no global address and without arping", () => {
    withFakeNet("", (env, log) => {
      const result = spawnSync("sh", ["-c", devboxNetworkAnnounceCommand()], { env, encoding: "utf8" });
      expect(result.status).toBe(0);
      expect(existsSync(log)).toBe(false);
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
    // On a clone: the very first action, detached, before the daemon stop,
    // the state refresh, the SSH rekey, and the bind. The Mac is already
    // dialing; the fabric drops its SYNs until this frame goes out.
    const cloneBranch = devboxBoot.indexOf('if [ -n "$id" ] && [ "$id" != "$(cat "$BOUND_INSTANCE_FILE" 2>/dev/null)" ]; then');
    const announce = devboxBoot.indexOf("( announce_network & )");
    const stop = devboxBoot.indexOf("stop_daemon", cloneBranch);
    const rekey = devboxBoot.indexOf("( rekey_ssh_host & )");
    const bound = devboxBoot.indexOf(`printf '%s\\n' "$id" > "$BOUND_INSTANCE_FILE"`);
    expect(cloneBranch).toBeGreaterThan(-1);
    expect(announce).toBeGreaterThan(cloneBranch);
    expect(stop).toBeGreaterThan(announce);
    expect(bound).toBeGreaterThan(stop);
    expect(rekey).toBeGreaterThan(bound);
  });

  test("a parked supervisor ticks fast so a clone is noticed within ~50 ms of resume", () => {
    expect(devboxBoot).toContain("PARKED_TICK=0.05");
    expect(devboxBoot).toContain('sleep "$tick"');
    // The parked branch and the failed-first-read branch keep the fast tick;
    // a bound machine goes back to one second.
    expect(devboxBoot.match(/tick=\$PARKED_TICK/g)?.length).toBe(2);
    expect(devboxBoot).toContain("  tick=1\n");
    expect(devboxBoot).toContain('elif [ -z "$id" ] && [ -n "$parked" ]; then');
  });

  test("resume housekeeping timers are parked with the daemon and re-armed off the critical path", () => {
    for (const timer of ["logrotate.timer", "man-db.timer", "fstrim.timer", "dpkg-db-backup.timer", "systemd-tmpfiles-clean.timer", "apt-daily.timer"]) {
      expect(devboxBoot).toContain(timer);
    }
    expect(devboxBoot).toContain("systemctl stop cmux-housekeeping-rearm.timer cmux-housekeeping-rearm.service $HOUSEKEEPING_TIMERS");
    // Service watchdogs are runtime state: off while parked (so the clock jump
    // kills nothing on resume), back on with the delayed re-arm.
    expect(devboxBoot).toContain("  systemd-analyze service-watchdogs no >/dev/null 2>&1 || true\n");
    expect(devboxBoot).toContain('--on-active="$HOUSEKEEPING_DELAY"');
    expect(devboxBoot).toContain('/bin/sh -c "systemd-analyze service-watchdogs yes; systemctl start $HOUSEKEEPING_TIMERS"');
    const bound = devboxBoot.indexOf(`printf '%s\\n' "$id" > "$BOUND_INSTANCE_FILE"`);
    expect(devboxBoot.indexOf('[ -n "$parked" ] && { rearm_housekeeping; parked=""; }')).toBeGreaterThan(bound);
  });

  test("the image installs arping and verify proves the announce loop on a booted machine", () => {
    expect(readFileSync(path.join(templateDir, "Dockerfile"), "utf8")).toContain("    iputils-arping \\\n");
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("command -v arping && pgrep -f 'cmux-devbox-[b]oot' >/dev/null && grep -q 'announce_loop &' /usr/local/bin/cmux-devbox-boot && echo network-announce-ok");
  });
});

// Warm template terminal (devboxPrepareTemplateTerminalCommand and
// devboxParkDaemonCommand): the snapshot keeps the first terminal's host and
// shell, never the daemon's per-machine state. The wipe runs with a scratch
// working directory so a regression can never touch the checkout.
describe("devbox warm template terminal", () => {
  function wipe(root: string, stateRoot: string) {
    return spawnSync("sh", ["-c", `${devboxWipeDaemonStateKeepingTemplateCommand(stateRoot)} && echo "$cmux_keep"`], {
      encoding: "utf8",
      cwd: root,
      timeout: 5_000,
    });
  }

  test("the park wipe keeps only the terminal host records and removes every identity file", () => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-template-wipe-"));
    try {
      const state = path.join(root, "cmux-tui");
      const sessions = path.join(state, "sessions");
      const hosts = path.join(sessions, "terminal-hosts-abc");
      const session = path.join(sessions, "cloud");
      mkdirSync(hosts, { recursive: true });
      mkdirSync(session, { recursive: true });
      writeFileSync(path.join(hosts, "0123.json"), "{}");
      writeFileSync(path.join(sessions, "machine-id"), "machine_builder\n");
      writeFileSync(path.join(sessions, "resource-effect-pepper"), "secret");
      writeFileSync(path.join(session, "workspace-registry.sqlite3"), "db");
      writeFileSync(path.join(session, "workspace-registry.sqlite3-wal"), "wal");
      writeFileSync(path.join(state, "stray.lock"), "");
      writeFileSync(path.join(root, "sentinel"), "");
      const result = wipe(root, `'${state}'`);
      expect(result.stderr).toBe("");
      expect(result.status).toBe(0);
      expect(result.stdout.trim()).toBe(hosts);
      expect(existsSync(path.join(hosts, "0123.json"))).toBe(true);
      for (const gone of ["machine-id", "resource-effect-pepper", "cloud"]) {
        expect(existsSync(path.join(sessions, gone))).toBe(false);
      }
      expect(existsSync(path.join(state, "stray.lock"))).toBe(false);
      expect(existsSync(path.join(root, "sentinel"))).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the park wipe fails without deleting anything when there is no template host", () => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-template-wipe-"));
    try {
      const state = path.join(root, "state");
      mkdirSync(path.join(state, "sessions"), { recursive: true });
      writeFileSync(path.join(state, "sessions", "machine-id"), "m");
      writeFileSync(path.join(root, "sentinel"), "");
      for (const stateRoot of [`'${state}'`, "''", "relative"]) {
        const result = wipe(root, stateRoot);
        expect(result.status).not.toBe(0);
      }
      expect(existsSync(path.join(state, "sessions", "machine-id"))).toBe(true);
      expect(existsSync(path.join(root, "sentinel"))).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a clone reseeds the kernel RNG and starts the shell's bounded wait before its daemon starts", () => {
    expect(devboxBoot).toContain("export CMUX_TUI_ADOPT_TEMPLATE_TERMINAL=1");
    expect(devboxBoot).toContain('export CMUX_TUI_TEMPLATE_BOUND_FILE="$TEMPLATE_RUN_DIR/bound"');
    const cloneBranch = devboxBoot.indexOf('if [ -n "$id" ] && [ "$id" != "$(cat "$BOUND_INSTANCE_FILE" 2>/dev/null)" ]; then');
    const announce = devboxBoot.indexOf("( announce_network & )", cloneBranch);
    const cloneStarted = devboxBoot.indexOf('"$TEMPLATE_RUN_DIR/clone-started"', cloneBranch);
    const reseed = devboxBoot.indexOf('reseed_kernel_rng "$id"', cloneBranch);
    const daemon = devboxBoot.indexOf("start_daemon", reseed);
    const rekey = devboxBoot.indexOf("( rekey_ssh_host & )", cloneBranch);
    expect(announce).toBeGreaterThan(cloneBranch);
    expect(cloneStarted).toBeGreaterThan(announce);
    expect(reseed).toBeGreaterThan(cloneStarted);
    expect(daemon).toBeGreaterThan(reseed);
    expect(rekey).toBeGreaterThan(reseed);
  });

  test("the RNG reseed runs cleanly as a shell function", () => {
    const start = devboxBoot.indexOf("reseed_kernel_rng() {");
    const fn = devboxBoot.slice(start, devboxBoot.indexOf("\n}\n", start) + 3);
    const result = spawnSync("sh", ["-c", `${fn}\nreseed_kernel_rng vm-test && echo ok`], { encoding: "utf8", timeout: 5_000 });
    expect(result.stdout.trim()).toBe("ok");
  });

  test("the bake and every derived size prepare a fresh template terminal before parking", () => {
    const build = readFileSync(path.join(import.meta.dirname, "../scripts/build-devbox-freestyle.ts"), "utf8");
    const derive = readFileSync(path.join(import.meta.dirname, "../scripts/derive-devbox-sizes.ts"), "utf8");
    for (const script of [build, derive]) {
      const prepare = script.indexOf("devboxPrepareTemplateTerminalCommand()");
      const park = script.indexOf("devboxParkDaemonCommand()", prepare);
      expect(prepare).toBeGreaterThan(-1);
      expect(park).toBeGreaterThan(prepare);
    }
    const prepare = devboxPrepareTemplateTerminalCommand();
    expect(prepare.indexOf("template-arm")).toBeLessThan(prepare.indexOf("workspace create --name Cloud"));
    expect(prepare).toContain("test -e /run/cmux/template-shell-ready");
    expect(prepare).toContain("test ! -e /run/cmux/template-arm");
    const park = devboxParkDaemonCommand();
    expect(park).toContain("pgrep -f '[_]_terminal-host'");
    expect(park).toContain("rm -f /run/cmux/bound /run/cmux/clone-started /run/cmux/first-prompt-named");
  });
});

