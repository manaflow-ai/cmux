/**
 * The cmux dev tree (`bake.ts --dev-tree`, measured by first-build.ts): the public cmux checkout at
 * the bake's commit with the ghostty-next submodule, bindgen's libclang, the Rust toolchain from the
 * checkout's cmux-tui/rust-toolchain.toml, the Zig from its scripts/install-zig-ci.sh, and the warm
 * caches the first build leaves (cargo registry and git, the Zig package cache, cmux-tui/target).
 * The guest side is images/cmux-vm/guest/dev-tree.sh. A guest exec ends after 5 minutes (guest.ts),
 * so every phase runs as a transient systemd unit that this side polls.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { run, sleep, type Vm } from "./guest";
import { type DevTreeLock, type InputsLock, sq } from "./lock";

const SCRIPT_SOURCE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/guest/dev-tree.sh");
export const DEV_TREE_SCRIPT = "/root/cmux-dev-tree.sh";
const MINUTE = 60_000;

/** What a developer runs first on a Linux machine (cmux-tui/README.md, Build): the daemon, from cmux-tui/. */
export const FIRST_BUILD = ["cargo", "build", "-p", "cmux-tui"] as const;

export function devTreeLock(lock: InputsLock): DevTreeLock {
  if (!lock.devTree) throw new Error("inputs.lock.json has no devTree");
  return lock.devTree;
}

/**
 * The work user's paths the dev tree fills. The secret scan, the file manifest and the SBOM skip
 * them: their content is the recorded commit, public crates and toolchains, and a test fixture in
 * them would read as a secret. devTreeCredentialCheckCommand checks the checkout instead.
 */
export function devTreeUserPaths(tree: DevTreeLock): string[] {
  return [tree.dir, "/home/cmux/.cargo", "/home/cmux/.rustup", "/home/cmux/.cache/zig"];
}

const CREDENTIAL_FILES = ["/home/cmux/.git-credentials", "/home/cmux/.cargo/credentials", "/home/cmux/.cargo/credentials.toml"];

/** No git or cargo credential file in the work home: each path is checked on its own. Runs with or without the tree. */
export const CREDENTIAL_FILES_CHECK = CREDENTIAL_FILES.map((f) => `{ test ! -e ${sq(f)} || { echo 'credential file: ${f}'; false; }; }`).join(" && ");

/** The checkout fetches from the public URL with no credential, and holds no identity. */
export function devTreeCredentialCheckCommand(tree: DevTreeLock): string {
  const git = `runuser -u cmux -- git -C ${sq(tree.dir)}`;
  return [
    `test "$(${git} remote get-url origin)" = ${sq(tree.repo)}`,
    `! ${git} config --local --get-regexp '^(credential\\.|http\\..*extraheader|url\\..*insteadof|user\\.)'`,
    CREDENTIAL_FILES_CHECK,
    "echo dev-tree-no-credentials",
  ].join(" && ");
}

export async function uploadDevTreeScript(vm: Vm): Promise<void> {
  await vm.fs.writeFile(DEV_TREE_SCRIPT, readFileSync(SCRIPT_SOURCE), { mode: 0o755 });
  const r = await run(vm, `chown root:root ${DEV_TREE_SCRIPT} && bash -n ${DEV_TREE_SCRIPT}`);
  if (r.code !== 0) throw new Error(`dev-tree.sh upload: ${r.stderr.slice(-300)}`);
}

export function devTreeCommand(args: readonly string[]): string {
  return `bash ${DEV_TREE_SCRIPT} ${args.map(sq).join(" ")}`;
}

/**
 * Runs `command` as the transient unit cmux-dev-tree-<label> and waits for it. The unit records
 * its exit status and its own duration (ms). While it runs, one request to github.com a minute
 * keeps the VM from looking network-idle: a harness VM pauses after 300 s of that (guest.ts), and
 * a cold build compiles for far longer without network.
 */
export async function devTreePhase(vm: Vm, label: string, command: string, budgetMs: number): Promise<{ ms: number; out: string }> {
  const base = `/var/tmp/cmux-dev-tree-${label}`;
  const body = [
    "t0=$(date +%s%3N)",
    "( while sleep 60; do curl -fsS -o /dev/null -m 20 https://github.com/ || true; done ) & ka=$!",
    `( ${command} ) > ${base}.log 2>&1; rc=$?`,
    "kill $ka 2>/dev/null; wait $ka 2>/dev/null",
    `echo "$rc $(( $(date +%s%3N) - t0 ))" > ${base}.rc`,
  ].join("; ");
  // The body goes in a file: systemd would expand `$` and `%` in a unit's command line.
  const start = await run(vm, `rm -f ${base}.rc ${base}.log && printf '%s\\n' ${sq(body)} > ${base}.sh && systemd-run --quiet --collect --unit=cmux-dev-tree-${label} /bin/bash ${base}.sh`);
  if (start.code !== 0) throw new Error(`dev tree ${label}: systemd-run: ${start.stderr.slice(-300)}`);
  const deadline = Date.now() + budgetMs;
  let wait = 1000;
  let failures = 0;
  for (;;) {
    await sleep(wait);
    wait = Math.min(wait * 2, 15_000);
    let done: string;
    try {
      done = (await run(vm, `cat ${base}.rc 2>/dev/null || true`, MINUTE)).stdout.trim();
      failures = 0;
    } catch (error) {
      if (++failures > 5) throw error;
      continue;
    }
    const m = /^(\d+) (\d+)$/.exec(done);
    if (m) {
      const out = (await run(vm, `tail -c 4000 ${base}.log; rm -f ${base}.rc ${base}.log ${base}.sh`)).stdout;
      if (m[1] !== "0") throw new Error(`dev tree ${label} exited ${m[1]}:\n${out}`);
      return { ms: Number(m[2]), out };
    }
    if (Date.now() > deadline) {
      await run(vm, `systemctl stop cmux-dev-tree-${label} 2>/dev/null; tail -c 2000 ${base}.log`).catch(() => undefined);
      throw new Error(`dev tree ${label}: still running after ${budgetMs / MINUTE} min`);
    }
  }
}

export type Phases = Record<string, number>;
type Log = (line: string) => void;

async function phase(vm: Vm, phases: Phases, log: Log, label: string, command: string, budgetMs: number): Promise<string> {
  const { ms, out } = await devTreePhase(vm, label, command, budgetMs);
  phases[label] = ms;
  log(`ok [dev-tree-${label}] ${(ms / 1000).toFixed(1)}s :: ${out.trim().split("\n").at(-1) ?? ""}`);
  return out.trim().split("\n").at(-1) ?? "";
}

/**
 * Checkout, Zig, Rust and the first build: the bake runs this to warm the image, and first-build.ts
 * runs it on a machine of an image without the tree (after `aptRoots` from the live mirror).
 * `ref` is the commit to check out; empty means the branch head. Returns the checked-out commit.
 */
export async function setUpDevTree(vm: Vm, tree: DevTreeLock, ref: string, phases: Phases, log: Log): Promise<string> {
  const head = await phase(vm, phases, log, "clone", devTreeCommand(["clone", tree.repo, tree.branch, ref, tree.dir, ...tree.submodules]), 20 * MINUTE);
  await phase(vm, phases, log, "zig", devTreeCommand(["zig", tree.dir]), 15 * MINUTE);
  const rust = tree.rustupInit;
  await phase(vm, phases, log, "rust", devTreeCommand(["rust", tree.dir, rust.url, rust.sha256, String(rust.size)]), 15 * MINUTE);
  await firstBuild(vm, tree, phases, log);
  return head;
}

/** On a machine of an image with the tree: fetch, fast-forward to `ref` (empty: the branch head), then the first build. Returns the commit. */
export async function updateDevTree(vm: Vm, tree: DevTreeLock, ref: string, phases: Phases, log: Log): Promise<string> {
  const head = await phase(vm, phases, log, "update", devTreeCommand(["update", tree.dir, ref, ...tree.submodules]), 15 * MINUTE);
  await firstBuild(vm, tree, phases, log);
  return head;
}

async function firstBuild(vm: Vm, tree: DevTreeLock, phases: Phases, log: Log): Promise<void> {
  await phase(vm, phases, log, "build", devTreeCommand(["build", tree.dir, ...FIRST_BUILD]), 100 * MINUTE);
}

/** Bytes per part of the tree (dev-tree.sh sizes), and the root file system's used bytes as `root-used`. */
export async function devTreeSizes(vm: Vm, tree: DevTreeLock): Promise<Record<string, number>> {
  const r = await run(vm, devTreeCommand(["sizes", tree.dir]), 4 * MINUTE);
  if (r.code !== 0) throw new Error(`dev-tree.sh sizes: ${r.stderr.slice(-300)}`);
  return Object.fromEntries(
    r.stdout
      .trim()
      .split("\n")
      .map((line) => line.split("\t"))
      .filter(([, bytes]) => /^\d+$/.test(bytes ?? ""))
      .map(([part, bytes]) => [part, Number(bytes)]),
  );
}
