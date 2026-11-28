import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { copyFileSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { parseInputsLock } from "../scripts/cmux-vm-image/lock";
import { runChild } from "./helpers/run-child";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const script = path.join(repoRoot, "images/cmux-vm/pin-cmux-tui.ts");
const TARGET = "x86_64-unknown-linux-musl";
const FILES = "https://files.cmux.com/cmux-tui";
const sha = (bytes: string) => createHash("sha256").update(bytes).digest("hex");

/** files.cmux.com as a map of path (under cmux-tui/) to body; anything else answers 404. */
async function serve(files: Record<string, string>): Promise<{ server: Server; port: number }> {
  const server = createServer((req, res) => {
    const key = new URL(req.url ?? "/", "http://127.0.0.1").pathname.replace(/^\//, "");
    const body = files[key];
    if (body === undefined) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, { "content-length": String(Buffer.byteLength(body)) });
    res.end(req.method === "HEAD" ? undefined : body);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, port: (server.address() as AddressInfo).port };
}

async function pin(files: Record<string, string>, commit: string) {
  const dir = mkdtempSync(path.join(tmpdir(), "pin-cmux-tui-"));
  const { server, port } = await serve(files);
  try {
    const lock = path.join(dir, "inputs.lock.json");
    copyFileSync(path.join(repoRoot, "images/cmux-vm/inputs.lock.json"), lock);
    // Async: a synchronous child would block this process's server.
    const { status, stderr } = await runChild("bun", [script, "--commit", commit, "--lock", lock, "--write"], {
      env: { ...process.env, CMUX_TUI_FILES: `http://127.0.0.1:${port}` },
      timeout: 25_000,
    });
    const programs = parseInputsLock(readFileSync(lock, "utf8")).programs.filter((p) => p.name.startsWith("cmux-tui"));
    return { status, stderr, programs };
  } finally {
    server.closeAllConnections();
    server.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

// MACHINE_BUILD (2026-11-27): feat-cmux-next commits after f7b548a5 had no cmux-tui/<commit>/manifest.json, only the
// Cloud machine channel's write-once cmux-tui/<commit>/machine/ files, so every push roll kept the lock's pin and the
// image lock fell 420 min behind (bound 120).
describe("pin-cmux-tui.ts --commit with no commit manifest", () => {
  const commit = "2982fd7159b1da0577ed2b9b4f717b53d88e7324";
  const bytes = { "cmux-tui": "tui bytes", "cmux-tui-hook": "hook bytes" } as const;
  const machine = Object.fromEntries(Object.entries(bytes).map(([name, body]) => [`${commit}/machine/${name}-${TARGET}`, body]));
  const channel = (named: string, hash = (b: string) => sha(b)) => ({
    "channels/cloud-machine.json": JSON.stringify({
      schema: 1,
      payload: Buffer.from(
        JSON.stringify({
          channel: "cloud-machine",
          purpose: "cmux-cloud-machine-update",
          commit: named,
          targets: {
            [TARGET]: Object.fromEntries(
              Object.entries(bytes).map(([name, body]) => [name, { sha256: hash(body), size: Buffer.byteLength(body), url: `${FILES}/${named}/machine/${name}-${TARGET}` }]),
            ),
          },
        }),
      ).toString("base64"),
      signatures: [],
    }),
  });

  test("pins the machine build, with the channel's sha256 when the channel names the commit", async () => {
    const got = await pin({ ...machine, ...channel(commit, () => "a".repeat(64)) }, commit);
    expect(got.status).toBe(0);
    for (const p of got.programs) {
      expect(p.version).toBe(commit);
      expect(p.url).toBe(`${FILES}/${commit}/machine/${p.name}-${TARGET}`);
      expect(p.sha256).toBe("a".repeat(64));
      expect(p.source).toMatch(/cloud-machine\.json \(signed/);
    }
  }, 30_000);

  test("hashes the write-once bytes once the channel has moved on", async () => {
    const got = await pin({ ...machine, ...channel("b".repeat(40)) }, commit);
    expect(got.status).toBe(0);
    for (const p of got.programs) {
      expect(p.url).toBe(`${FILES}/${commit}/machine/${p.name}-${TARGET}`);
      expect(p.sha256).toBe(sha(bytes[p.name as keyof typeof bytes]));
      expect(p.size).toBe(Buffer.byteLength(bytes[p.name as keyof typeof bytes]));
      expect(p.source).toMatch(/sha256 of the bytes/);
    }
  }, 30_000);

  test("a commit with neither a manifest nor a machine build answers non-zero and leaves the lock", async () => {
    const got = await pin(channel(commit), "c".repeat(40));
    expect(got.status).not.toBe(0);
    expect(got.stderr).toMatch(/machine\/cmux-tui-x86_64-unknown-linux-musl: HEAD 404/);
    for (const p of got.programs) expect(p.version).not.toBe("c".repeat(40));
  }, 30_000);

  test("a commit manifest still wins over the machine build", async () => {
    const manifest = {
      [`${commit}/manifest.json`]: JSON.stringify({ commit, binaries: Object.fromEntries(Object.entries(bytes).map(([name, body]) => [`${name}-${TARGET}`, sha(body)])) }),
      ...Object.fromEntries(Object.entries(bytes).map(([name, body]) => [`${commit}/${name}-${TARGET}`, body])),
    };
    const got = await pin({ ...manifest, ...machine, ...channel(commit, () => "a".repeat(64)) }, commit);
    expect(got.status).toBe(0);
    for (const p of got.programs) {
      expect(p.url).toBe(`${FILES}/${commit}/${p.name}-${TARGET}`);
      expect(p.sha256).toBe(sha(bytes[p.name as keyof typeof bytes]));
    }
  }, 30_000);
});
