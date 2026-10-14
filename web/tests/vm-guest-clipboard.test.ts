import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CLIPBOARD_WRITER } from "../services/vms/guestClipboard";
import { runChild } from "./helpers/run-child";

async function writer(name: string, args: readonly string[], input: string) {
  const directory = mkdtempSync(join(tmpdir(), "guest-clipboard-"));
  try {
    const path = join(directory, name);
    writeFileSync(path, GUEST_CLIPBOARD_WRITER);
    chmodSync(path, 0o755);
    return await runChild(path, args, { input, env: { PATH: process.env.PATH } });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

describe("guest clipboard writers", () => {
  test.each<[string, string[]]>([
    ["xclip", ["-selection", "clipboard"]],
    ["xclip", ["-i", "-selection", "c"]],
    ["xsel", ["--clipboard", "--input"]],
    ["wl-copy", ["--type", "text/plain"]],
  ])("%s emits a write-only OSC 52 payload", async (name, args) => {
    const result = await writer(name, args, "device code ✓\n");
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("\x1b]52;c;ZGV2aWNlIGNvZGUg4pyTCg==\x07");
    expect(result.stderr).toBe("");
  });

  test.each<[string, string[]]>([
    ["xclip", ["-o"]],
    ["xsel", ["--output"]],
    ["wl-copy", ["--get"]],
  ])("%s rejects clipboard reads", async (name, args) => {
    const result = await writer(name, args, "secret");
    expect(result.status).toBe(2);
    expect(result.stdout).toBe("");
  });

  test("rejects an oversized write before emitting terminal data", async () => {
    const result = await writer("wl-copy", [], "x".repeat(1024 * 1024 + 1));
    expect(result.status).toBe(2);
    expect(result.stdout).toBe("");
  });
});
