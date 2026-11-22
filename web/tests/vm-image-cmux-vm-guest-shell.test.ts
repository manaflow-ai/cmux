import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bakeScriptClosure } from "../scripts/cmux-vm-image/layers";
import { guestShellProblems, outsideSingleQuotes } from "../scripts/cmux-vm-image/shell-check";
import { StepLog } from "../scripts/cmux-vm-image/guest";
import { tmpdir } from "node:os";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (file: string) => {
  try {
    return readFileSync(path.join(repoRoot, file), "utf8");
  } catch {
    return undefined;
  }
};

describe("a bake step runs under the guest's /bin/sh (dash)", () => {
  test("pipefail and syntax errors are refused; a bash -c payload in single quotes is not", () => {
    expect(guestShellProblems("set -euo pipefail\necho hi").refused).toEqual(["bash-only for /bin/sh: set -o pipefail"]);
    expect(guestShellProblems("set -eu\necho hi")).toEqual({ refused: [], suspect: [] });
    expect(guestShellProblems("if then fi").refused.length).toBe(1);
    expect(guestShellProblems("runuser -u cmux -- bash -lc 'set -o pipefail; [[ -n x ]] && source ~/.profile'")).toEqual({ refused: [], suspect: [] });
    expect(guestShellProblems("[[ -n x ]] && echo y").suspect).toEqual(["bash-only for /bin/sh: [[ ]]"]);
    expect(outsideSingleQuotes("a 'b c' d \\' e")).toBe("a    d \\' e");
  });

  test("StepLog refuses a step the guest's sh would refuse, before anything reaches the guest", async () => {
    const L = new StepLog(path.join(tmpdir(), `guest-shell-${process.pid}`, "bake.log"));
    let execs = 0;
    const vm = { exec: async () => { execs++; return { statusCode: 0, stdout: "", stderr: "" }; } } as unknown as Parameters<StepLog["step"]>[0];
    await expect(L.step(vm, "bad", "set -euo pipefail; true")).rejects.toThrow("not /bin/sh");
    expect(execs).toBe(0);
    await L.step(vm, "good", "set -eu; true");
    expect(execs).toBe(1);
  });

  test("every command builder the bake and the smoke use parses under the guest's sh, with no pipefail", async () => {
    // Every exported *Command / *_COMMAND the bake's own scripts (bakeScriptClosure) and the smoke export.
    const files = [...bakeScriptClosure(read)].filter((f) => f.startsWith("web/scripts/cmux-vm-image/") && read(f) !== undefined);
    files.push("web/scripts/cmux-vm-image/smoke.ts", "web/scripts/cmux-vm-image/probes.ts", "web/scripts/cmux-vm-image/daemon-uptime.ts", "web/scripts/devbox-image-common.ts");
    const checked: string[] = [];
    const problems: string[] = [];
    for (const file of files) {
      const mod = (await import(path.join(repoRoot, file))) as Record<string, unknown>;
      for (const [name, value] of Object.entries(mod)) {
        if (!/(Command|_COMMAND)$/.test(name)) continue;
        // Builders that need arguments are covered where their callers are; a zero-argument one is the whole step.
        const command = typeof value === "string" ? value : typeof value === "function" && value.length === 0 ? (() => { try { return (value as () => unknown)(); } catch { return undefined; } })() : undefined;
        if (typeof command !== "string") continue;
        checked.push(`${path.basename(file)}:${name}`);
        for (const p of guestShellProblems(command).refused) problems.push(`${path.basename(file)}:${name}: ${p}`);
      }
    }
    expect(checked).toContain("dep-cache.ts:npmCachePrefillCommand");
    expect(checked.length).toBeGreaterThan(20);
    expect(problems).toEqual([]);
  });
});
