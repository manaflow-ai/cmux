import { expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { readCuaProof, saveCuaProof, type CuaProofFiles } from "../scripts/devbox-cua-smoke";

test.each(["ECONNRESET", "EPIPE", "ETIMEDOUT"])("evidence survives an interrupted download (%s)", async (code) => {
  const screenshot = new Uint8Array([137, 80, 78, 71]);
  let attempts = 0;
  const result = await readCuaProof(async () => {
    if (++attempts === 1) throw Object.assign(new Error("interrupted response body"), { code });
    return screenshot;
  });
  expect(result).toEqual(screenshot);
  expect(attempts).toBe(2);
});

test("persistent connection failures fail evidence collection after three attempts", async () => {
  const failure = Object.assign(new Error("connection reset"), { code: "ECONNRESET" });
  let attempts = 0;
  await expect(readCuaProof(async () => { attempts++; throw failure; })).rejects.toBe(failure);
  expect(attempts).toBe(3);
});

test.each(["ENOENT", "EACCES", "NOT_FOUND"])("permanent evidence errors fail immediately (%s)", async (code) => {
  const failure = Object.assign(new Error("evidence unavailable"), { code });
  let attempts = 0;
  await expect(readCuaProof(async () => { attempts++; throw failure; })).rejects.toBe(failure);
  expect(attempts).toBe(1);
});

function proofFiles(entries: Record<string, Uint8Array> | Error): CuaProofFiles {
  return {
    async readDir() {
      if (entries instanceof Error) throw entries;
      return Object.keys(entries).map((name) => ({ name }));
    },
    async readFile(file: string) {
      if (entries instanceof Error) throw entries;
      return entries[path.basename(file)]!;
    },
  };
}

test("a failed smoke reports its own output even when the probe left no proof directory", async () => {
  const destination = mkdtempSync(path.join(tmpdir(), "cua-proof-"));
  try {
    const missing = Object.assign(new Error("no such directory"), { code: "ENOENT" });
    await expect(saveCuaProof({
      files: proofFiles(missing), guestDirectory: "/tmp/proof", destination,
      output: "AssertionError: login shell did not inherit the desktop", passed: false, label: "sm",
    })).rejects.toThrow("sm: computer-use smoke failed: AssertionError: login shell did not inherit the desktop");
    expect(readFileSync(path.join(destination, "probe.log"), "utf8")).toContain("did not inherit the desktop");
  } finally {
    rmSync(destination, { recursive: true, force: true });
  }
});

test("a passed smoke keeps its screenshots and fails when they cannot be read", async () => {
  const destination = mkdtempSync(path.join(tmpdir(), "cua-proof-"));
  try {
    await saveCuaProof({
      files: proofFiles({ "claude-before.png": new Uint8Array([137, 80]), "notes.txt": new Uint8Array([1]) }),
      guestDirectory: "/tmp/proof", destination, output: "CUA_SMOKE_PASS {}", passed: true, label: "sm",
    });
    expect(readdirSync(destination).sort()).toEqual(["claude-before.png", "probe.log"]);
    const missing = Object.assign(new Error("no such directory"), { code: "ENOENT" });
    await expect(saveCuaProof({
      files: proofFiles(missing), guestDirectory: "/tmp/proof", destination, output: "CUA_SMOKE_PASS {}", passed: true, label: "sm",
    })).rejects.toBe(missing);
  } finally {
    rmSync(destination, { recursive: true, force: true });
  }
});
