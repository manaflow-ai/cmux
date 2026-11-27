import { expect, test } from "bun:test";
import { Effect } from "effect";
import { mkdtempSync, rmSync, writeFileSync, watch, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { setImmediate } from "node:timers/promises";
import { startPrivateLinkClient } from "../scripts/devbox-private-link-process";

// The fixture has bound a path, but has not announced readiness. The parent
// controls the actual readiness event with a signal, independently of time.
test("a socket path cannot substitute for the process readiness event", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-ready-test-"));
  const socket = path.join(root, "hub.sock");
  const booted = path.join(root, "booted");
  writeFileSync(socket, "stale path");
  const initialized = new Promise<void>((resolve) => {
    const watcher = watch(root, () => {
      if (existsSync(booted)) { watcher.close(); resolve(); }
    });
  });
  let settledBeforeEvent = false;
  try {
    await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
      const fixture = `
        const fs = require('node:fs');
        require('node:net').createServer().listen(${JSON.stringify(path.join(root, 'keepalive.sock'))});
        process.on('SIGUSR1', () => process.stdout.write(JSON.stringify({event:'hub-ready',socket:${JSON.stringify(socket)}})+'\\n'));
        fs.writeFileSync(${JSON.stringify(booted)}, 'ready for signal');
      `;
      const managed = yield* startPrivateLinkClient(process.execPath, ["-e", fixture], { event: "hub-ready", socket });
      yield* Effect.promise(() => initialized);
      let settled = false;
      const readiness = Effect.runPromise(managed.ready).then(() => { settled = true; });
      yield* Effect.promise(() => setImmediate());
      settledBeforeEvent = settled;
      managed.child.kill("SIGUSR1");
      yield* Effect.promise(() => readiness);
    })));
    expect(settledBeforeEvent).toBe(false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("child exit before readiness fails even if its old socket path exists", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-ready-exit-"));
  const socket = path.join(root, "link.sock");
  writeFileSync(socket, "stale path");
  try {
    const result = await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
      const managed = yield* startPrivateLinkClient(process.execPath, ["-e", "process.exit(1)"], { event: "connection-snapshot", socket });
      return yield* Effect.either(managed.ready);
    })));
    expect(result._tag).toBe("Left");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("shutdown escalates only after its deadline and waits for process close", async () => {
  const { Fiber, TestClock, TestContext } = await import("effect");
  const root = mkdtempSync(path.join(tmpdir(), "cmux-close-test-"));
  const stopped = path.join(root, "sigterm");
  const socket = path.join(root, "hub.sock");
  const receivedTerminate = new Promise<void>((resolve) => {
    const watcher = watch(root, () => {
      if (existsSync(stopped)) { watcher.close(); resolve(); }
    });
  });
  let closed = false;
  try {
    await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(Effect.scoped(Effect.gen(function* () {
        const fixture = `
          require('node:net').createServer().listen(${JSON.stringify(socket)});
          process.on('SIGTERM', () => require('node:fs').writeFileSync(${JSON.stringify(stopped)}, 'ignored'));
          process.stdout.write(JSON.stringify({event:'hub-ready',socket:${JSON.stringify(socket)}})+'\\n');
        `;
        const managed = yield* startPrivateLinkClient(process.execPath, ["-e", fixture], { event: "hub-ready", socket });
        managed.child.once("close", () => { closed = true; });
        yield* managed.ready;
      })));
      yield* Effect.promise(() => receivedTerminate);
      expect(closed).toBe(false);
      yield* TestClock.adjust("2 seconds");
      yield* Fiber.join(fiber);
    }).pipe(Effect.provide(TestContext.TestContext)));
    expect(closed).toBe(true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Trigger cancellation synchronously inside spawn's return path, before Node
// can emit its spawn event. acquireRelease must finish acquisition and reap it.
test("interruption before the spawn event still closes the acquired child", async () => {
  const childProcess = await import("node:child_process");
  const { spyOn } = await import("bun:test");
  const originalSpawn = childProcess.spawn;
  const controller = new AbortController();
  let closed = false;
  let spawned = false;
  const spy = spyOn(childProcess, "spawn").mockImplementation((...args: Parameters<typeof originalSpawn>) => {
    const child = originalSpawn(...args);
    child.once("spawn", () => { spawned = true; });
    child.once("close", () => { closed = true; });
    controller.abort();
    return child;
  });
  try {
    const result = await Effect.runPromiseExit(Effect.scoped(startPrivateLinkClient(
      process.execPath, ["-e", "process.stdin.resume()"], { event: "hub-ready", socket: "/unused" },
    )), { signal: controller.signal });
    expect(result._tag).toBe("Failure");
    expect(spawned).toBe(true);
    expect(closed).toBe(true);
  } finally { spy.mockRestore(); }
});
