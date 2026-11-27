import { afterAll, describe, expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Cloud VM shell defaults (web/services/vms/images/shell): the Chief VM bake
// (backend/chief-cc/bake.sh) and the retrofit of running VMs run
// shell-defaults.sh; the cmux-vm image bake installs the terminfo overlay and
// the TERM fallback. User report (2026-10-21): `htop` on a Chief dev VM failed
// with "Error opening terminal: xterm-ghostty" and the prompt read
// root@freestyle-vm.

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, "..");
const repo = path.resolve(web, "..");
const shellDir = path.join(web, "services/vms/images/shell");
const devboxDir = path.join(web, "services/vms/images/devbox");
const work = mkdtempSync(path.join(tmpdir(), "cmux-shell-defaults-"));
afterAll(() => rmSync(work, { recursive: true, force: true }));

const HOSTS = [
  "127.0.0.1\tlocalhost",
  "127.0.1.1\tfreestyle-vm",
  "::1\tlocalhost ip6-localhost ip6-loopback",
  "# BEGIN freestyle-tls-egress",
  "10.0.0.1\tapi.example.test",
  "# END freestyle-tls-egress",
  "",
].join("\n");

async function sh(command: string, env: Record<string, string> = {}, shell = "bash") {
  const r = await runChild(shell, ["-c", command], { env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...env } });
  return { code: r.status, out: `${r.stdout}${r.stderr}`, stdout: r.stdout };
}

/** A fake root shaped like a Freestyle Ubuntu guest, then shell-defaults.sh run over it. */
async function bakeFakeRoot(): Promise<{ root: string; out: string; code: number | null }> {
  const root = path.join(work, `root-${Math.random().toString(36).slice(2)}`);
  const src = path.join(root, "src");
  for (const d of ["etc/update-motd.d", "etc/skel", "root", "home/chief", "src"]) mkdirSync(path.join(root, d), { recursive: true });
  writeFileSync(path.join(root, "etc/hosts"), HOSTS);
  writeFileSync(path.join(root, "etc/hostname"), "freestyle-vm\n");
  writeFileSync(path.join(root, "etc/motd"), "  Ubuntu 24.04.5 LTS on Freestyle\n  Docs: https://docs.freestyle.sh\n");
  writeFileSync(path.join(root, "etc/update-motd.d/10-help-text"), "#!/bin/sh\necho help\n", { mode: 0o755 });
  writeFileSync(path.join(root, "etc/bash.bashrc"), "# system bashrc\n");
  writeFileSync(path.join(root, "etc/skel/.bashrc"), "PS1='\\u@\\h:\\w\\$ '\n");
  writeFileSync(path.join(root, "root/.bashrc"), "PS1='\\u@\\h:\\w\\$ '\n");
  writeFileSync(path.join(root, "home/chief/.bashrc"), "PS1='\\u@\\h:\\w\\$ '\n");
  mkdirSync(path.join(root, "etc/profile.d"), { recursive: true });
  writeFileSync(path.join(root, "etc/profile.d/nvm.sh"), 'export NVM_DIR=/usr/local/nvm\n[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n');
  for (const f of ["cmux-shell.sh", "nvm-lazy.sh"]) copyFileSync(path.join(shellDir, f), path.join(src, f));
  for (const f of ["cmux-terminfo.src", "cmux-terminfo.sh", "cmux-bashrc", "cmux-prompt.bash", "cmux-motd"]) {
    copyFileSync(path.join(devboxDir, f), path.join(src, f));
  }
  const r = await sh(`bash ${JSON.stringify(path.join(shellDir, "shell-defaults.sh"))} ${JSON.stringify(src)}`, { CMUX_SHELL_ROOT: root });
  return { root, out: r.out, code: r.code };
}

describe("cloud VM shell defaults (shell-defaults.sh)", () => {
  test("the script and the TERM-fallback profile exist", async () => {
    expect(existsSync(path.join(shellDir, "shell-defaults.sh"))).toBe(true);
    expect(existsSync(path.join(shellDir, "cmux-shell.sh"))).toBe(true);
  });

  test("installs xterm-ghostty terminfo, names the machine cmux, and drops the provider banner", async () => {
    const { root, out, code } = await bakeFakeRoot();
    expect(out).toContain("cmux-shell-defaults-ok name=cmux");
    expect(code).toBe(0);
    const ti = path.join(root, "etc/terminfo");
    for (const term of ["xterm-ghostty", "xterm-256color"]) {
      const r = await sh(`infocmp -x -A ${JSON.stringify(ti)} ${term}`);
      expect(r.code).toBe(0);
      expect(r.out).toContain("Tc");
    }
    expect(readFileSync(path.join(root, "etc/hostname"), "utf8")).toBe("cmux\n");
    const hosts = readFileSync(path.join(root, "etc/hosts"), "utf8");
    expect(hosts).toContain("127.0.1.1\tcmux\n");
    expect(hosts).not.toMatch(/(^|[^\w-])freestyle-vm([^\w-]|$)/m);
    expect(hosts).toContain("# BEGIN freestyle-tls-egress\n10.0.0.1\tapi.example.test\n# END freestyle-tls-egress\n");
    expect(readFileSync(path.join(root, "etc/motd"), "utf8")).toBe("");
    expect(statSync(path.join(root, "etc/update-motd.d/10-help-text")).mode & 0o111).toBe(0);
    const banner = (await sh(`sh ${JSON.stringify(path.join(root, "etc/update-motd.d/00-cmux"))}`)).out;
    expect(banner).toContain("cmux");
    expect(banner.toLowerCase()).not.toContain("freestyle");
    expect(readFileSync(path.join(root, "etc/cmux/vm-name"), "utf8")).toBe("cmux\n");
  });

  test("is idempotent: a second run adds no duplicate lines", async () => {
    const { root } = await bakeFakeRoot();
    const src = path.join(root, "src");
    const again = await sh(`bash ${JSON.stringify(path.join(shellDir, "shell-defaults.sh"))} ${JSON.stringify(src)}`, { CMUX_SHELL_ROOT: root });
    expect(again.code).toBe(0);
    for (const f of ["etc/bash.bashrc", "root/.bashrc", "home/chief/.bashrc", "etc/tmux.conf", "etc/hosts"]) {
      const lines = readFileSync(path.join(root, f), "utf8").split("\n").filter(Boolean);
      expect(new Set(lines).size).toBe(lines.length);
    }
    expect(readFileSync(path.join(root, "etc/bash.bashrc"), "utf8")).toContain(". /etc/cmux/bashrc");
    expect(readFileSync(path.join(root, "root/.bashrc"), "utf8")).toContain(". /etc/cmux/bashrc");
  });

  test("the profile sets UTF-8 and truecolor, and falls back to xterm-256color for an unknown TERM", async () => {
    const { root } = await bakeFakeRoot();
    const profile = path.join(root, "etc/profile.d/cmux-shell.sh");
    const ti = path.join(root, "etc/terminfo");
    const run = async (term: string) =>
      (await sh(`. ${JSON.stringify(profile)}; printf '%s|%s|%s' "$TERM" "$COLORTERM" "$LANG"`, { TERM: term, TERMINFO_DIRS: ti, HOME: root })).out;
    expect(await run("xterm-ghostty")).toBe("xterm-ghostty|truecolor|C.UTF-8");
    expect(await run("xterm-kitty-not-installed")).toBe("xterm-256color|truecolor|C.UTF-8");
    expect(await run("dumb")).toBe("dumb|truecolor|C.UTF-8");
    // POSIX sh too (dash sources /etc/profile.d for sh logins).
    const dash = await sh(`. ${JSON.stringify(profile)}; printf %s "$TERM"`, { TERM: "nope-term", TERMINFO_DIRS: ti, HOME: root }, "sh");
    expect(dash.stdout).toBe("xterm-256color");
  });

  test("the prompt reads user@cmux and runs no child process per prompt", async () => {
    const { root } = await bakeFakeRoot();
    const rc = path.join(root, "rc");
    // The fake root's prompt files, with the machine-name path pointed into it.
    const prompt = readFileSync(path.join(root, "etc/cmux/prompt.bash"), "utf8").replaceAll("/etc/cmux/vm-name", path.join(root, "etc/cmux/vm-name"));
    writeFileSync(path.join(root, "prompt.bash"), prompt);
    writeFileSync(rc, `. ${JSON.stringify(path.join(root, "prompt.bash"))}\n`);
    const r = await sh(`bash --noprofile --rcfile ${JSON.stringify(rc)} -i -c 'printf "%s" "\${PS1@P}"' 2>/dev/null`, { HOME: root, TERM: "xterm-256color" });
    // eslint-disable-next-line no-control-regex
    expect(r.out.replace(/[\u0001\u0002]|\u001b\[[0-9;]*m/g, "")).toMatch(/\w+@cmux in /);
    // No command substitution and no git scan in the prompt code (comments and $((arithmetic)) aside).
    const code = prompt.split("\n").filter((l) => !l.trimStart().startsWith("#")).join("\n").replaceAll("$((", "");
    expect(code).not.toMatch(/\$\(|`|\bgit\b/);
  });
});

describe("lazy nvm (nvm-lazy.sh)", () => {
  test("replaces the provider's eager loader, keeps it as .orig, and stays idempotent", async () => {
    const { root } = await bakeFakeRoot();
    const lazy = readFileSync(path.join(root, "etc/profile.d/nvm.sh"), "utf8");
    expect(lazy).toContain("loaded on first use");
    expect(readFileSync(path.join(root, "etc/cmux/nvm.sh.orig"), "utf8")).toContain('. "$NVM_DIR/nvm.sh"');
    const again = await sh(`bash ${JSON.stringify(path.join(shellDir, "shell-defaults.sh"))} ${JSON.stringify(path.join(root, "src"))}`, { CMUX_SHELL_ROOT: root });
    expect(again.code).toBe(0);
    expect(readFileSync(path.join(root, "etc/cmux/nvm.sh.orig"), "utf8")).toContain('. "$NVM_DIR/nvm.sh"');
  });

  test("a login shell gets node on PATH without loading nvm; the first nvm call loads it", async () => {
    const nvmDir = path.join(work, "nvm");
    mkdirSync(path.join(nvmDir, "versions/node/v24.1.0/bin"), { recursive: true });
    writeFileSync(path.join(nvmDir, "versions/node/v24.1.0/bin/node"), "#!/bin/sh\necho v24.1.0\n", { mode: 0o755 });
    // A fake nvm.sh that records it was loaded.
    writeFileSync(path.join(nvmDir, "nvm.sh"), 'NVM_LOADED=1\nnvm() { echo "real nvm $*"; }\n');
    const profile = path.join(shellDir, "nvm-lazy.sh");
    const r = await sh(`. ${JSON.stringify(profile)}; printf '%s|%s|' "$(node)" "\${NVM_LOADED:-0}"; nvm ls; printf '|%s' "\${NVM_LOADED:-0}"`, { NVM_DIR: nvmDir, PATH: "/usr/bin:/bin" });
    expect(r.out).toBe("v24.1.0|0|real nvm ls\n|1");
  });
});

describe("bakes wire the shell defaults", () => {
  test("the Chief VM bake runs shell-defaults.sh with the devbox files", async () => {
    const bake = readFileSync(path.join(repo, "backend/chief-cc/bake.sh"), "utf8");
    expect(bake).toContain("web/services/vms/images/shell");
    expect(bake).toContain("shell-defaults.sh");
    for (const f of ["cmux-terminfo.src", "cmux-terminfo.sh", "cmux-bashrc", "cmux-prompt.bash", "cmux-motd"]) expect(bake).toContain(f);
  });

  test("the cmux-vm image bake installs the terminfo overlay, the TERM fallback, and empties the provider motd", async () => {
    const bake = readFileSync(path.join(web, "scripts/cmux-vm-image/bake.ts"), "utf8");
    expect(bake).toContain('"/etc/cmux/terminfo.src"');
    expect(bake).toContain('"/etc/profile.d/cmux-shell.sh"');
    expect(bake).toContain("devboxTerminfoInstallCommand");
    expect(bake).toContain(": > /etc/motd");
  });
});
