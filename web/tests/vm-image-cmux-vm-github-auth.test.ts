import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { daemonUnit, storeProfileScript } from "../scripts/cmux-vm-image/bake";
import { GH_SHIM, GITHUB_GITCONFIG, GITHUB_SHIM_DIR, ghShimScript, githubAuthFiles, githubGitconfig } from "../scripts/cmux-vm-image/github-auth";
import { bakedPrograms, CURRENT_BIN, readInputsLock } from "../scripts/cmux-vm-image/lock";
import { programProblems } from "../scripts/cmux-vm-image/smoke";
import { runChild } from "./helpers/run-child";

// The gh shim and the system git helper (plans/cmux-next/cloud-github-auth-DESIGN.md 3.1, 3.2),
// run with real sh and git against stand-ins for the store's cmux and gh.
const root = mkdtempSync(path.join(os.tmpdir(), "cmux-gh-auth-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

/** A stand-in program that records its argv, the env it was given and its stdin, then prints `out`. */
function recorder(name: string, out = ""): { bin: string; log: string } {
  const bin = path.join(root, `${name}-${Math.random().toString(36).slice(2)}`);
  const log = `${bin}.log`;
  writeFileSync(bin, `#!/bin/sh\n{ printf 'argv:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\nreal:%s\\n' "\${CMUX_GITHUB_GH_REAL-}"; cat; } >> ${log}\nprintf '%s' '${out}'\n`);
  chmodSync(bin, 0o755);
  return { bin, log };
}

async function listeningSocket(): Promise<{ path: string; close: () => void }> {
  const p = path.join(root, `agent-${Math.random().toString(36).slice(2)}.sock`);
  const server = net.createServer(() => {});
  await new Promise<void>((resolve) => server.listen(p, resolve));
  return { path: p, close: () => server.close() };
}

async function runShim(script: string, args: string[]) {
  const shim = path.join(root, `gh-shim-${Math.random().toString(36).slice(2)}`);
  writeFileSync(shim, script);
  chmodSync(shim, 0o755);
  return runChild(shim, args, { env: { PATH: "/usr/bin:/bin" }, input: "" });
}

describe("gh shim", () => {
  test("on a machine with the Cloud agent, gh goes through cmux github gh --auto with the real gh named", async () => {
    const sock = await listeningSocket();
    const cmux = recorder("cmux");
    const gh = recorder("gh");
    const r = await runShim(ghShimScript({ realGh: gh.bin, cmux: cmux.bin, socket: sock.path }), ["pr", "create", "--title", "a b"]);
    sock.close();
    expect(r.status).toBe(0);
    const log = readFileSync(cmux.log, "utf8");
    expect(log).toContain("argv: [github] [gh] [--auto] [--] [pr] [create] [--title] [a b]");
    expect(log).toContain(`real:${gh.bin}`);
  });

  test("without the agent socket (or without cmux), it is the real gh with the same argv", async () => {
    const gh = recorder("gh");
    const missing = path.join(root, "no-such-cmux");
    for (const opts of [{ socket: path.join(root, "absent.sock"), cmux: recorder("cmux").bin }, { socket: (await listeningSocket()).path, cmux: missing }]) {
      const r = await runShim(ghShimScript({ realGh: gh.bin, ...opts }), ["auth", "status"]);
      expect(r.status).toBe(0);
    }
    const log = readFileSync(gh.log, "utf8");
    expect(log.match(/argv: \[auth\] \[status\]/g)?.length).toBe(2);
  });

  test("the shim dir comes before the store on every PATH the machine hands out", () => {
    const unitPath = /Environment=PATH=([^\n]+)/.exec(daemonUnit())?.[1] ?? "";
    expect(unitPath.split(":").slice(0, 2)).toEqual([GITHUB_SHIM_DIR, CURRENT_BIN]);
    const profile = path.join(root, "profile.sh");
    writeFileSync(profile, storeProfileScript());
    return runChild("/bin/sh", ["-c", `. ${profile}; printf '%s' "$PATH"`], { env: { PATH: "/usr/bin:/bin" }, input: "" }).then((r) => {
      expect(r.stdout.split(":").slice(0, 2)).toEqual([GITHUB_SHIM_DIR, CURRENT_BIN]);
    });
  });

  test("the files land where the PATH points", () => {
    const files = githubAuthFiles();
    expect(files.find((f) => f.path === GH_SHIM)?.mode).toBe(0o755);
    expect(path.dirname(GH_SHIM)).toBe(GITHUB_SHIM_DIR);
    expect(files.find((f) => f.path === GITHUB_GITCONFIG)?.mode).toBe(0o644);
  });
});

describe("system git helper", () => {
  /** git with only a system config that includes the managed file (as /etc/gitconfig does on the image). */
  async function gitFill(helperCmux: string, input: string, extraGlobal = "") {
    const dir = mkdtempSync(path.join(root, "git-"));
    const managed = path.join(dir, "cmux-gitconfig");
    writeFileSync(managed, githubGitconfig(helperCmux));
    writeFileSync(path.join(dir, "system"), `[include]\n\tpath = ${managed}\n`);
    writeFileSync(path.join(dir, "global"), extraGlobal);
    mkdirSync(path.join(dir, "home"));
    return runChild("git", ["credential", "fill"], {
      env: { PATH: "/usr/bin:/bin", HOME: path.join(dir, "home"), GIT_CONFIG_SYSTEM: path.join(dir, "system"), GIT_CONFIG_GLOBAL: path.join(dir, "global"), GIT_TERMINAL_PROMPT: "0" },
      input,
    });
  }

  test("git asks cmux github credential for github.com with the repo path, and uses its answer", async () => {
    const cmux = recorder("cmux", "username=x-access-token\npassword=ghs_test\n");
    const r = await gitFill(cmux.bin, "protocol=https\nhost=github.com\npath=o/r.git\n\n");
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("password=ghs_test");
    const log = readFileSync(cmux.log, "utf8");
    expect(log).toContain("argv: [github] [credential] [get]");
    expect(log).toContain("path=o/r.git");
  });

  test("other hosts never reach the helper", async () => {
    const cmux = recorder("cmux", "username=x\npassword=y\n");
    await gitFill(cmux.bin, "protocol=https\nhost=gitlab.com\npath=o/r.git\n\n");
    expect(() => readFileSync(cmux.log, "utf8")).toThrow();
  });

  test("a person's own gh auth setup-git (an empty helper first) replaces it", async () => {
    const cmux = recorder("cmux", "username=x-access-token\npassword=ghs_test\n");
    const theirs = recorder("theirs", "username=me\npassword=gho_mine\n");
    const r = await gitFill(cmux.bin, "protocol=https\nhost=github.com\npath=o/r.git\n\n", `[credential "https://github.com"]\n\thelper =\n\thelper = !${theirs.bin}\n`);
    expect(r.stdout).toContain("password=gho_mine");
    expect(() => readFileSync(cmux.log, "utf8")).toThrow();
  });
});

describe("smoke programs-run", () => {
  const lock = readInputsLock();
  const answer = (gh: string) =>
    bakedPrograms(lock)
      .flatMap((p) => Object.keys(p.bin).map((c) => `${c} 0 ${c === "gh" ? gh : `${CURRENT_BIN}/${c}`} :: ${p.expect ?? "ok"}`))
      .join("\n");

  test("gh resolves to the shim, every other command to the store", () => {
    expect(programProblems(lock, answer(GH_SHIM))).toEqual([]);
  });

  test("gh anywhere else is a problem, the store's gh included", () => {
    expect(programProblems(lock, answer(`${CURRENT_BIN}/gh`)).join("\n")).toContain(`expected ${GH_SHIM}`);
    expect(programProblems(lock, answer("/usr/bin/gh")).join("\n")).toContain("gh: resolves to /usr/bin/gh");
  });
});
