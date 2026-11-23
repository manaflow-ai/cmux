// The save-time perf lint (dev-server/perfLint.ts) is idle work: a save hands Vite's hot update
// nothing to wait on. Before, `handleHotUpdate` spawned `vp lint` inline (about 20 ms of blocking
// spawn before the update went out), and the lint ran beside the swapped module's transform.
import { afterAll, expect, mock, test } from "bun:test";
import { EventEmitter } from "node:events";
import path from "node:path";
import { fileURLToPath } from "node:url";

const spawned: string[][] = [];
mock.module("node:child_process", () => ({
  spawn: (_command: string, args: string[]) => {
    spawned.push(args);
    const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), pid: undefined });
    queueMicrotask(() => child.emit("close", 0));
    return child;
  },
}));
afterAll(() => mock.restore());

const ROOT = fileURLToPath(new URL("..", import.meta.url));

test("a save spawns no lint inline; one lint runs after the file goes quiet", async () => {
  const { perfLintOnSave, LINT_IDLE_MS } = await import("../dev-server/perfLint");
  const plugin = perfLintOnSave();
  const handleHotUpdate = plugin.handleHotUpdate as (context: { file: string }) => void;
  const file = path.join(ROOT, "src/agent-session/acpmux/ComposerFoot.tsx");

  handleHotUpdate({ file });
  handleHotUpdate({ file });
  expect(spawned).toEqual([]);

  await Bun.sleep(LINT_IDLE_MS + 300);
  expect(spawned.length).toBe(1);
  expect(spawned[0].at(-1)).toBe(file);
});
