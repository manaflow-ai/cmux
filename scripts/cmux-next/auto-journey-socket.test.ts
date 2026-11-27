import { describe, expect, test } from "bun:test";
import { createServer, type Server, type Socket as NetSocket } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Socket } from "./auto-journey.ts";

async function openSocket(run: (socket: Socket, peer: NetSocket) => Promise<void>) {
  const dir = mkdtempSync(path.join(tmpdir(), "auto-journey-socket-"));
  const socketPath = path.join(dir, "daemon.sock");
  let peer: NetSocket | undefined;
  const server: Server = createServer(connection => {
    peer = connection;
    connection.on("error", () => undefined);
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
  const socket = await Socket.open(socketPath);
  try {
    expect(peer).toBeDefined();
    await run(socket, peer!);
  } finally {
    socket.close();
    peer?.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("Auto journey socket waits", () => {
  test("does not lose a notification that arrives between the read and wait", async () => {
    await openSocket(async (socket, peer) => {
      let reads = 0;
      const found = await socket.waitUntil(async () => {
        reads += 1;
        if (reads === 1) setImmediate(() => {
          // The notification is the wake source; the predicate reads the parsed note.
          peer.write('{"jsonrpc":"2.0","method":"test/changed","params":{}}\n');
        });
        return socket.notes.some(note => note.method === "test/changed");
      }, 500);
      expect(found).toBe(true);
      expect(reads).toBeGreaterThanOrEqual(2);
    });
  });

  test("rejects promptly when the daemon socket closes", async () => {
    await openSocket(async socket => {
      const waiting = socket.waitUntil(async () => {
        setImmediate(() => socket.close());
        await new Promise(() => {});
        return false;
      }, 500);
      await expect(waiting).rejects.toThrow("socket closed");
    });
  });

  test("returns false when the predicate never resolves", async () => {
    await openSocket(async socket => {
      const started = Date.now();
      const found = await socket.waitUntil(async () => {
        await new Promise(() => {});
        return true;
      }, 10);
      expect(found).toBe(false);
      expect(Date.now() - started).toBeLessThan(1000);
    });
  });

  test("enforces one total deadline, including a slow predicate read", async () => {
    await openSocket(async socket => {
      const started = Date.now();
      const found = await socket.waitUntil(async () => {
        await new Promise(resolve => setTimeout(resolve, 40));
        return true;
      }, 10);
      expect(found).toBe(false);
      expect(Date.now() - started).toBeLessThan(1000);
    });
  });
});
