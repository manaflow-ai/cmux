import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { cmuxTuiFetchCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { runChild } from "./helpers/run-child";

// A raw HTTP/1.1 server, so the test controls exactly where a transfer breaks.
type Plan = (request: { range: number | null; index: number }) => "full" | "cut" | "ignore-range-cut";

const BODY = Buffer.from(Array.from({ length: 256 * 1024 }, (_, i) => (i * 31 + 7) % 251));
const servers: Server[] = [];
const dirs: string[] = [];

afterEach(() => {
  for (const server of servers.splice(0)) server.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

async function serve(plan: Plan): Promise<{ url: string; ranges: (number | null)[] }> {
  const ranges: (number | null)[] = [];
  const server = createServer((socket: Socket) => {
    let head = "";
    socket.on("data", (chunk) => {
      head += chunk.toString("latin1");
      if (!head.includes("\r\n\r\n")) return;
      const match = /\r\nrange: bytes=(\d+)-/i.exec(head);
      const range = match ? Number(match[1]) : null;
      const mode = plan({ range, index: ranges.length });
      ranges.push(range);
      const start = mode === "ignore-range-cut" ? 0 : (range ?? 0);
      const rest = BODY.subarray(start);
      const status = start > 0 ? "206 Partial Content" : "200 OK";
      const headers = [
        `HTTP/1.1 ${status}`,
        `Content-Length: ${rest.length}`,
        "Accept-Ranges: bytes",
        ...(start > 0 ? [`Content-Range: bytes ${start}-${BODY.length - 1}/${BODY.length}`] : []),
        "Connection: close",
        "",
        "",
      ].join("\r\n");
      socket.write(headers);
      if (mode === "full") {
        socket.end(rest);
      } else {
        // Send a third of what was promised, then drop the connection.
        socket.write(rest.subarray(0, Math.floor(rest.length / 3)), () => socket.destroy());
      }
    });
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no port");
  return { url: `http://127.0.0.1:${address.port}/cmux-tui`, ranges };
}

function scratchFile(): string {
  const dir = mkdtempSync(join(tmpdir(), "cmux-tui-fetch-"));
  dirs.push(dir);
  return join(dir, "cmux-tui.tmp");
}

// Async: the server answers on this process's event loop.
async function fetchTo(file: string, url: string): Promise<number | null> {
  const run = await runChild("sh", ["-c", cmuxTuiFetchCommand(`"${file}"`, url)], { timeout: 80_000 });
  return run.status;
}

describe("cmux-tui download", () => {
  test("resumes a dropped transfer from the bytes already received", async () => {
    const server = await serve(({ index }) => (index < 2 ? "cut" : "full"));
    const file = scratchFile();
    expect(await fetchTo(file, server.url)).toBe(0);
    expect(readFileSync(file).equals(BODY)).toBe(true);
    // Each attempt asks only for what is still missing.
    expect(server.ranges.length).toBe(3);
    expect(server.ranges[0]).toBeNull();
    expect(server.ranges[1]).toBeGreaterThan(0);
    expect(server.ranges[2]).toBeGreaterThan(server.ranges[1] ?? 0);
  }, 30_000);

  test("starts over when the server ignores the range", async () => {
    const server = await serve(({ index }) => (index === 0 ? "cut" : index === 1 ? "ignore-range-cut" : "full"));
    const file = scratchFile();
    expect(await fetchTo(file, server.url)).toBe(0);
    expect(readFileSync(file).equals(BODY)).toBe(true);
  }, 30_000);

  test("replaces a stale partial file left by an earlier install", async () => {
    const server = await serve(() => "full");
    const file = scratchFile();
    writeFileSync(file, "stale bytes");
    expect(await fetchTo(file, server.url)).toBe(0);
    expect(readFileSync(file).equals(BODY)).toBe(true);
    expect(server.ranges).toEqual([null]);
  }, 30_000);

  test("fails after the last attempt instead of reporting a partial file", async () => {
    const server = await serve(() => "cut");
    expect(await fetchTo(scratchFile(), server.url)).not.toBe(0);
  }, 90_000);
});
