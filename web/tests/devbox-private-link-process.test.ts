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
        process.stdin.resume();
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
