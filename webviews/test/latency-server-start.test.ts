import { expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";
import { waitForServerReady } from "../scripts/latency/run";

function serverFixture() {
  return Object.assign(new EventEmitter(), {
    stdout: new EventEmitter(),
    stderr: new EventEmitter(),
  }) as unknown as ChildProcess;
}

function expectClean(server: ChildProcess) {
  expect(server.stdout!.listenerCount("data")).toBe(0);
  expect(server.stderr!.listenerCount("data")).toBe(0);
  expect(server.listenerCount("exit")).toBe(0);
  expect(server.listenerCount("error")).toBe(0);
}

test("server readiness matches a banner split across chunks and removes listeners", async () => {
  const server = serverFixture();
  const ready = waitForServerReady(server, 3210, 100);
  server.stdout!.emit("data", Buffer.from("Local: http://127.0."));
  server.stdout!.emit("data", Buffer.from("0.1:3210/"));
  await ready;
  expectClean(server);
});

test("server readiness matches a banner whose port is wrapped in colour escapes", async () => {
  const server = serverFixture();
  const ready = waitForServerReady(server, 3210, 100);
  const esc = String.fromCharCode(27);
  server.stdout!.emit("data", Buffer.from(`Local: http://127.0.0.1:${esc}[1m32`));
  server.stdout!.emit("data", Buffer.from(`10${esc}[22m/`));
  await ready;
  expectClean(server);
});

test("server without a banner times out and removes listeners", async () => {
  const server = serverFixture();
  await expect(waitForServerReady(server, 3210, 2)).rejects.toThrow("server startup timed out");
  expectClean(server);
});

test("server startup rejects an early exit and removes listeners", async () => {
  const server = serverFixture();
  const ready = waitForServerReady(server, 3210, 100);
  server.emit("exit", 2);
  await expect(ready).rejects.toThrow("server exited 2");
  expectClean(server);
});
