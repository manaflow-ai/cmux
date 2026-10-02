import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AcpmuxClient } from "../src/index.ts";

const cleanups: (() => void)[] = [];
afterEach(() => cleanups.splice(0).forEach((f) => f()));

/** A fake daemon: answers requests by method, and pushes a notification after watch. */
function fakeDaemon(
  handlers: Record<string, (params: Record<string, unknown>) => unknown>,
): string {
  const dir = mkdtempSync(join(tmpdir(), "acpmux-fake-"));
  const path = join(dir, "s.sock");
  const server: Server = createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      for (let i = buffer.indexOf("\n"); i >= 0; i = buffer.indexOf("\n")) {
        const message = JSON.parse(buffer.slice(0, i));
        buffer = buffer.slice(i + 1);
        const handler = handlers[message.method];
        if (message.id === undefined) continue;
        if (message.method === "drop") {
          socket.destroy();
          return;
        }
        // Split one reply across two writes to exercise buffering.
        const reply = handler
          ? JSON.stringify({ jsonrpc: "2.0", id: message.id, result: handler(message.params) })
          : JSON.stringify({
              jsonrpc: "2.0",
              id: message.id,
              error: { message: "Method not found" },
            });
        socket.write(reply.slice(0, 7));
        socket.write(`${reply.slice(7)}\n`);
        if (message.method === "_acpmux/watch") {
          socket.write(
            `${JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { sessionId: "s1", kind: "status" } })}\n`,
          );
        }
      }
    });
  });
  server.listen(path);
  cleanups.push(() => {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  });
  return path;
}

test("requests resolve by id across split writes; errors reject; notifications arrive after watch", async () => {
  const path = fakeDaemon({
    initialize: () => ({ protocolVersion: 1 }),
    "_acpmux/sessions": () => ({ sessions: [{ sessionId: "s1", name: "a" }] }),
    "_acpmux/watch": () => ({}),
  });
  const client = await AcpmuxClient.connect(path);
  cleanups.push(() => client.close());
  expect((await client.sessions()).map((s) => s.name)).toEqual(["a"]);
  expect(await client.request("nope").catch((e: Error) => e.message)).toContain("Method not found");
  const seen = new Promise((resolve) => client.onNotification(resolve));
  await client.watch();
  expect(await seen).toEqual({
    method: "_acpmux/session_changed",
    params: { sessionId: "s1", kind: "status" },
  });
});

test("pending requests fail when the daemon goes away", async () => {
  const path = fakeDaemon({ initialize: () => ({}) });
  const client = await AcpmuxClient.connect(path);
  const closed = new Promise<void>((resolve) => client.onClose(resolve));
  const pending = client.request("drop").catch((e: Error) => e.message);
  expect(await pending).toBe("acpmux connection closed during drop");
  await closed;
});
