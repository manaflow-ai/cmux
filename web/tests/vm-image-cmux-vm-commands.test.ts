import { describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import path from "node:path";
import { cmuxTuiSourceFromLock, GUEST_DIR } from "../scripts/cmux-vm-image/bake";
import { CURRENT_BIN, profileCommand, programInstallCommand, readInputsLock, storeEntry } from "../scripts/cmux-vm-image/lock";
import { programChecksCommand, programProblems, secretScanCommand } from "../scripts/cmux-vm-image/smoke";
import { runChild } from "./helpers/run-child";

const lock = readInputsLock();

async function bashSyntax(script: string): Promise<void> {
  const result = await runChild("bash", ["-n"], { input: script, timeout: 20_000 });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
}

describe("cmux VM image guest commands", () => {
  test("every store install command parses and verifies digest and size", async () => {
    for (const program of lock.programs) {
      const command = programInstallCommand(program);
      expect(command).toContain(`printf '%s  %s\\n' ${program.sha256}`);
      expect(command).toContain(`= ${program.size}`);
      expect(command).toContain(`mv ${storeEntry(program.sha256)}.partial ${storeEntry(program.sha256)}`);
      await bashSyntax(command);
    }
    expect(programInstallCommand(lock.programs.find((p) => p.name === "coderouter")!)).toContain("grep -qx");
  });

  test("the profile links every command into generation 1 and flips current with one rename", async () => {
    const command = profileCommand(lock);
    expect(command).toContain("mv -T /opt/cmux/.current-new /opt/cmux/current");
    expect(command).toContain(`ln -s ${storeEntry(lock.programs.find((p) => p.name === "coderouter")!.sha256)}/coderouter /opt/cmux/profiles/1/bin/cr`);
    await bashSyntax(command);
  });

  test("smoke scans and program checks parse", async () => {
    await bashSyntax(secretScanCommand());
    await bashSyntax(programChecksCommand(lock));
  });

  test("program check parsing: exit code, store path and version", () => {
    const ok = lock.programs.flatMap((p) => Object.keys(p.bin).map((c) => `${c} 0 ${CURRENT_BIN}/${c} :: ${p.expect ?? "x"} ok`)).join("\n");
    expect(programProblems(lock, ok)).toEqual([]);
    const bad = ok.replace(`claude 0 ${CURRENT_BIN}/claude`, "claude 127 /usr/local/bin/claude");
    expect(programProblems(lock, bad)).toEqual([`claude: exit 127: ${lock.programs.find((p) => p.name === "claude")!.expect} ok`, `claude: resolves to /usr/local/bin/claude, expected ${CURRENT_BIN}/claude`]);
  });

  test("the daemon source comes from the lock, not a manifest fetch", () => {
    const source = cmuxTuiSourceFromLock(lock);
    expect(source.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(source.url).toContain(source.commit);
    expect(source.hookUrl).toContain(source.commit);
  });

  test("guest python helpers parse", async () => {
    for (const file of readdirSync(GUEST_DIR).filter((f) => f.endsWith(".py"))) {
      const result = await runChild("python3", ["-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())", path.join(GUEST_DIR, file)], { timeout: 20_000 });
      expect(result.status).toBe(0);
    }
  });
});

describe("Freestyle key by path", () => {
  test("FREESTYLE_API_KEY_FILE is read and trimmed; empty or absent fails closed", async () => {
    const { freestyleApiKey } = await import("../scripts/cmux-vm-image/guest");
    const { mkdtempSync, writeFileSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = mkdtempSync(join(tmpdir(), "fs-key-"));
    writeFileSync(join(dir, "k"), "fake-key-value\n");
    writeFileSync(join(dir, "empty"), "\n");
    expect(freestyleApiKey({ FREESTYLE_API_KEY_FILE: join(dir, "k") })).toBe("fake-key-value");
    expect(freestyleApiKey({ FREESTYLE_API_KEY: "direct", FREESTYLE_API_KEY_FILE: join(dir, "k") })).toBe("direct");
    expect(() => freestyleApiKey({ FREESTYLE_API_KEY_FILE: join(dir, "empty") })).toThrow(/empty/);
    expect(() => freestyleApiKey({})).toThrow(/FREESTYLE_API_KEY_FILE/);
  });
});
