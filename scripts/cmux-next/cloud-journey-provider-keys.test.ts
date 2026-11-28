import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { PROVIDER_KEY_PATTERN, providerKeysProgram, providerKeysVerdict } from "./cloud-journey.ts";

const KEY = new RegExp(PROVIDER_KEY_PATTERN);

describe("no provider key on the machine", () => {
  test("matches each vendor's issued form, not placeholders or doc examples", () => {
    for (const k of [
      "sk-ant-api03-" + "a".repeat(95),
      "sk-ant-oat01-" + "B".repeat(95),
      "sk-proj-" + "x".repeat(20) + "T3BlbkFJ" + "y".repeat(20),
      "AIza" + "c".repeat(35),
      "sk-or-v1-" + "0".repeat(64),
      '"refresh_token": "' + "r".repeat(40) + '"',
    ])
      expect(KEY.test(k)).toBe(true);
    for (const k of ["cmux-vm-edge-placeholder", "cmux-secret://ANTHROPIC_API_KEY", "sk-ant-api03-...", "sk-ant-xxxx", "refresh_token is rotated"])
      expect(KEY.test(k)).toBe(false);
  });

  test("the guest program names where a key is and never prints it", () => {
    const key = "sk-ant-oat01-" + "Q".repeat(95);
    const home = mkdtempSync(path.join(tmpdir(), "provider-keys-"));
    mkdirSync(path.join(home, ".codex"));
    writeFileSync(path.join(home, ".codex", "auth.json"), JSON.stringify({ tokens: { refresh_token: "r".repeat(40) } }));
    // An installed library's own source names the field (authlib's grants); it is code, not a login.
    const lib = path.join(home, "python", "lib", "site-packages", "authlib");
    mkdirSync(lib, { recursive: true });
    writeFileSync(path.join(lib, "token.py"), `x = '"refresh_token": "${"r".repeat(40)}'\n`);
    writeFileSync(path.join(home, "notes.md"), "set ANTHROPIC_API_KEY=sk-ant-api03-... in settings\n");
    const r = spawnSync("bash", ["-c", providerKeysProgram([home]).replace("sudo -n true", "false")], {
      env: { ...process.env, JOURNEY_PROVIDER_KEY_TEST: key },
      encoding: "utf8",
      timeout: 50_000,
    });
    expect(r.stdout).not.toContain(key);
    const v = providerKeysVerdict(r.stdout);
    expect(v.done).toBe(true);
    expect(v.root).toBe(false);
    expect(v.procs).toBeGreaterThan(0);
    expect(v.hits.some((h) => h.startsWith("env pid ") && h.endsWith("anthropic-oat"))).toBe(true);
    expect(v.hits.filter((h) => h.startsWith("file "))).toEqual([`file ${path.join(home, ".codex", "auth.json")}: oauth-refresh-token`]);
  }, 60_000);
});
