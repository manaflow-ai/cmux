import { afterEach, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { runChild } from "./helpers/run-child";

// The devbox image's root-run sync keeps the machine's kind record (an
// informational record of the kind cmux assigned) current from the reflection
// route. It writes only an answer it fetched, so a failed fetch never replaces
// the record the Cloud backend wrote at create (services/vms/guestVmKind.ts).

type VmGuestKind = "owner" | "team";

const roots: string[] = [];
const holders: (() => void)[] = [];
afterEach(() => {
  for (const release of holders.splice(0)) release();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function guestRoot(): string {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-vm-kind-sync-"));
  roots.push(root);
  mkdirSync(path.join(root, "etc/cmux"), { recursive: true, mode: 0o755 });
  return root;
}

const kindDir = (root: string) => path.join(root, "etc/cmux");
const kindFile = (root: string) => path.join(kindDir(root), "vm-kind");
describe("the image's cmux-vm-kind-sync", () => {
  const SYNC = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-vm-kind-sync");

  /**
   * Runs the sync against root with a curl that answers `answer` (or fails
   * when null). `duringFetch` runs inside the fake curl, before it answers.
   */
  async function sync(
    root: string,
    answer: VmGuestKind | null,
    extraEnv: Record<string, string> = {},
    duringFetch = "",
  ) {
    const bin = path.join(root, "sync-bin");
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      path.join(bin, "curl"),
      answer ? `#!/bin/sh\n${duringFetch}\nprintf '{"kind":"${answer}"}'\n` : "#!/bin/sh\nexit 22\n",
    );
    chmodSync(path.join(bin, "curl"), 0o755);
    const env = path.join(root, "model-plane.env");
    writeFileSync(env, "export CMUX_CODEROUTER_URL='https://cmux.example'\n");
    const result = await runChild("/bin/sh", [SYNC], {
      env: { PATH: `${bin}:${process.env.PATH}`, CMUX_VM_KIND_FILE: kindFile(root), CMUX_VM_MODEL_ENV_FILE: env, ...extraEnv },
    });
    expect(result.status).toBe(0);
  }

  test("a failed fetch keeps the record the create wrote", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    await sync(root, null);
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
  });

  test("a failed fetch writes nothing where there is no record", async () => {
    const root = guestRoot();
    await sync(root, null);
    expect(readdirSync(kindDir(root)).filter((name) => name.startsWith(".vm-kind") || name === "vm-kind")).toEqual([]);
  });

  test("an answer replaces the record", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "team\n");
    await sync(root, "owner");
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
  });

  test("the boot's clone reset writes team without fetching", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    await sync(root, "owner", { CMUX_VM_KIND_RESET: "team" });
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    const boot = readFileSync(path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-devbox-boot"), "utf8");
    expect(boot).toContain("CMUX_VM_KIND_RESET=team /usr/local/bin/cmux-vm-kind-sync");
  });

  const BOOT = readFileSync(path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-devbox-boot"), "utf8");
  const lockFile = (root: string) => `${kindFile(root)}.lock`;
  const generation = (root: string) => readFileSync(lockFile(root), "utf8").trim();

  /** Holds root's lock until released (or the test ends); resolves once flock has it. */
  async function holdLock(root: string): Promise<() => void> {
    const ready = path.join(root, "lock-held");
    const holder = spawn("flock", [lockFile(root), "sh", "-c", `: > '${ready}'; exec sleep 120`], {
      detached: true,
      stdio: "ignore",
    });
    let released = false;
    const release = () => {
      if (released || holder.pid === undefined) return;
      released = true;
      try {
        process.kill(-holder.pid, "SIGKILL");
      } catch {
        // already gone
      }
    };
    holders.push(release);
    await waitFor(ready);
    return release;
  }

  /**
   * Runs the boot's mark_vm_kind_shared against root, then the step after it.
   * `shims` are commands put first on PATH.
   */
  async function bootReset(root: string, env: Record<string, string> = {}, shims: Record<string, string> = {}) {
    const bin = path.join(root, "boot-bin");
    mkdirSync(bin, { recursive: true });
    for (const [name, body] of Object.entries(shims)) {
      writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`);
      chmodSync(path.join(bin, name), 0o755);
    }
    // The boot runs the installed (executable) copy.
    const installed = path.join(root, "cmux-vm-kind-sync");
    writeFileSync(installed, readFileSync(SYNC));
    chmodSync(installed, 0o755);
    const start = BOOT.indexOf("mark_vm_kind_shared() {");
    const fn = BOOT.slice(start, BOOT.indexOf("\n}\n", start) + 3).replaceAll("/usr/local/bin/cmux-vm-kind-sync", installed);
    const script = `vm_kind_sync_at=5\n${fn}\nmark_vm_kind_shared\necho "daemon start reached, next sync at $vm_kind_sync_at"\n`;
    const began = Date.now();
    const result = await runChild("/bin/sh", ["-c", script], {
      env: { PATH: `${bin}:${process.env.PATH}`, CMUX_VM_KIND_FILE: kindFile(root), ...env },
      timeout: 20_000,
    });
    return { ...result, seconds: (Date.now() - began) / 1000 };
  }

  test("a clone reset waits for a briefly held lock, then writes team; a sync that cannot take it writes nothing", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    const release = await holdLock(root);
    const reset = runChild("/bin/sh", [SYNC], {
      env: { PATH: process.env.PATH, CMUX_VM_KIND_FILE: kindFile(root), CMUX_VM_KIND_RESET: "team" },
      timeout: 20_000,
    });
    await sync(root, "team", { CMUX_VM_KIND_LOCK_WAIT: "1" });
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
    release();
    expect((await reset).status).toBe(0);
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    expect(generation(root)).toBe("1");
  });

  test("a lock that is never released: the boot's reset ends within its bound, records team, and the daemon start is reached", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    writeFileSync(lockFile(root), "7\n");
    await holdLock(root);
    const boot = await bootReset(root, { CMUX_VM_KIND_LOCK_WAIT: "2" });
    expect(boot.status).toBe(0);
    expect(boot.seconds).toBeLessThan(10);
    expect(boot.stdout).toContain("daemon start reached, next sync at 0");
    expect(boot.stderr).toContain("vm-kind reset failed; recording team without the lock");
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    // A new generation, so a sync that began before the reset writes nothing.
    expect(generation(root)).toBe("8");
    expect(readdirSync(kindDir(root)).filter((name) => name.startsWith(".vm-kind"))).toEqual([]);
  }, 30_000);

  test("a reset that cannot take the lock or cannot write falls back to team, and boot goes on", async () => {
    const shims: Record<string, string> = {
      flock: "exit 1",
      // The first temp file (the locked reset's write) fails; later ones work.
      mktemp: 'if [ ! -e "$SHIM_STATE" ]; then : > "$SHIM_STATE"; exit 1; fi\nPATH="${PATH#*:}" exec mktemp "$@"',
    };
    for (const [name, body] of Object.entries(shims)) {
      const root = guestRoot();
      writeFileSync(kindFile(root), "owner\n");
      const boot = await bootReset(root, { SHIM_STATE: path.join(root, "shim-state") }, { [name]: body });
      expect({ name, stdout: boot.stdout, kind: readFileSync(kindFile(root), "utf8") }).toEqual({
        name,
        stdout: "daemon start reached, next sync at 0\n",
        kind: "team\n",
      });
      expect(boot.stderr).toContain("vm-kind reset failed; recording team without the lock");
      expect(generation(root)).toMatch(/^[1-9][0-9]{0,8}$/);
    }
  });

  test("a generation past nine digits is corrupt: a sync writes nothing until a reset replaces it", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    writeFileSync(lockFile(root), `${"9".repeat(32)}\n`);
    await sync(root, "team");
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
    const boot = await bootReset(root);
    expect(boot.status).toBe(0);
    expect(boot.stderr).toBe("");
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    expect(generation(root)).toMatch(/^[1-9][0-9]{0,8}$/);
    await sync(root, "owner");
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
  });

  /** Waits until `file` exists (10 s at most). */
  async function waitFor(file: string) {
    const deadline = Date.now() + 10_000;
    while (!existsSync(file)) {
      if (Date.now() > deadline) throw new Error(`${file} never appeared`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }

  test("a sync past its check when the boot's fallback runs ends team, not its stale answer", async () => {
    // The sync's rename is held (a PATH shim on mv) after its generation
    // check; the fallback swaps the lock and writes team; then the rename runs.
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    writeFileSync(lockFile(root), "7\n");
    const bin = path.join(root, "sync-bin");
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      path.join(bin, "mv"),
      `#!/bin/sh
if [ -n "\${HOLD_DIR:-}" ] && [ ! -e "$HOLD_DIR/held" ]; then
  : > "$HOLD_DIR/held"
  i=0
  while [ ! -e "$HOLD_DIR/release" ]; do
    # Never rename late: a timeout fails the test instead of hiding a regression.
    [ $i -lt 400 ] || { : > "$HOLD_DIR/timed-out"; exit 1; }
    sleep 0.05
    i=$((i + 1))
  done
fi
PATH="\${PATH#*:}" exec mv "$@"
`,
    );
    chmodSync(path.join(bin, "mv"), 0o755);
    const late = sync(root, "owner", { HOLD_DIR: root });
    await waitFor(path.join(root, "held"));
    const fallback = await runChild("/bin/sh", [SYNC], {
      env: { PATH: process.env.PATH, CMUX_VM_KIND_FILE: kindFile(root), CMUX_VM_KIND_RESET: "team-unlocked" },
    });
    expect(fallback.status).toBe(0);
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    writeFileSync(path.join(root, "release"), "");
    await late;
    expect(existsSync(path.join(root, "timed-out"))).toBe(false);
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    expect(generation(root)).toBe("8");
  });

  test("a generation file that is not 1 to 9 digits and one newline is corrupt", async () => {
    for (const raw of ["1\n2", "7 \n", "7\n\n", "7\r\n", "7\u0000", "\u0000"]) {
      const root = guestRoot();
      writeFileSync(kindFile(root), "owner\n");
      writeFileSync(lockFile(root), raw);
      await sync(root, "team");
      expect({ raw, kind: readFileSync(kindFile(root), "utf8") }).toEqual({ raw, kind: "owner\n" });
    }
    for (const raw of ["", "7", "7\n", "007\n"]) {
      const root = guestRoot();
      writeFileSync(kindFile(root), "owner\n");
      writeFileSync(lockFile(root), raw);
      await sync(root, "team");
      expect({ raw, kind: readFileSync(kindFile(root), "utf8") }).toEqual({ raw, kind: "team\n" });
    }
  });

  test("an answer with several JSON values writes nothing", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    await sync(root, "team", {}, `printf '{"kind":"owner"}'`);
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
  });

  test("a clone reset during a running sync's fetch keeps team, and the next sync writes its answer", async () => {
    // The clone carries its source's `owner`; a sync started before the reset
    // answers `owner` after it. That stale answer must not undo the reset.
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    await sync(root, "owner", { SYNC_UNDER_TEST: SYNC }, 'CMUX_VM_KIND_RESET=team /bin/sh "$SYNC_UNDER_TEST" || exit 1');
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    await sync(root, "owner");
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
    expect(readdirSync(kindDir(root)).filter((name) => name.startsWith(".vm-kind"))).toEqual([]);
  });
});
