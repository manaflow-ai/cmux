import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FileMemoryStore } from "../src/file-store.ts";
import { compactUntilDone, takeLock } from "../src/compactor.ts";
import {
  lastAssistantText,
  sessionStart,
  stop,
  userPromptSubmit,
  type HookContext,
} from "../src/hooks.ts";
import { muxPaths } from "../src/paths.ts";

const dirs: string[] = [];
function setup(budget = 96): HookContext {
  const home = mkdtempSync(join(tmpdir(), "mux-cli-"));
  dirs.push(home);
  const paths = muxPaths(home);
  return {
    store: new FileMemoryStore(paths.memory),
    sessionsDir: paths.sessions,
    budget,
    now: new Date("2026-10-01T10:00:00Z"),
  };
}
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

test("a session sees its memory at start, and only other sessions' news on later prompts", async () => {
  const ctx = setup();
  await ctx.store.append(["2026-09-30T09:00 note: build box is cmux14"]);
  const start = await sessionStart(ctx, { session_id: "aaaaaaaa-1" });
  expect(start.hookSpecificOutput.additionalContext).toContain(
    "#0 2026-09-30T09:00 note: build box is cmux14",
  );

  // My own prompt and reply never come back to me as news.
  expect(await userPromptSubmit(ctx, { session_id: "aaaaaaaa-1", prompt: "hi" })).toBeUndefined();
  await stop(ctx, { session_id: "aaaaaaaa-1", last_assistant_message: "hello" });
  expect(
    await userPromptSubmit(ctx, { session_id: "aaaaaaaa-1", prompt: "again" }),
  ).toBeUndefined();

  // Another session writes; the first sees exactly that on its next prompt.
  await sessionStart(ctx, { session_id: "bbbbbbbb-2" });
  await userPromptSubmit(ctx, { session_id: "bbbbbbbb-2", prompt: "deploy to staging" });
  const update = await userPromptSubmit(ctx, { session_id: "aaaaaaaa-1", prompt: "status?" });
  expect(update?.hookSpecificOutput.additionalContext).toContain(
    "[bbbbbbbb] user: deploy to staging",
  );
  expect(update?.hookSpecificOutput.additionalContext).not.toContain("[aaaaaaaa]");

  const log = await ctx.store.read(0, 100);
  expect(log.filter((l) => l.includes("[aaaaaaaa] user:"))).toHaveLength(3);
  expect(log.some((l) => l.includes("[aaaaaaaa] mux: hello"))).toBe(true);
});

test("stop reads the reply from the transcript when the hook input lacks it, and asks for compaction when due", async () => {
  const ctx = setup(4);
  const transcript = join(dirs[0], "t.jsonl");
  writeFileSync(
    transcript,
    [
      JSON.stringify({ type: "user", message: { content: "q" } }),
      JSON.stringify({
        type: "assistant",
        message: { content: [{ type: "text", text: "the answer" }] },
      }),
      JSON.stringify({
        type: "assistant",
        message: { content: [{ type: "tool_use", name: "Bash" }] },
      }),
    ].join("\n"),
  );
  expect(lastAssistantText(transcript)).toBe("the answer");
  await ctx.store.append(Array.from({ length: 20 }, (_, i) => `fact ${i}`));
  expect(await stop(ctx, { session_id: "cccccccc-3", transcript_path: transcript })).toEqual({
    compact: true,
  });
});

test("compaction builds every summary the view needs, then the view fits the budget", async () => {
  const ctx = setup(6);
  await ctx.store.append(Array.from({ length: 40 }, (_, i) => `fact ${i}`));
  const written = await compactUntilDone(
    ctx.store,
    6,
    async ({ left, right }) => `${left.slice(0, 12)}|${right.slice(0, 12)}`,
  );
  expect(written).toBeGreaterThan(0);
  const start = await sessionStart(ctx, { session_id: "dddddddd-4" });
  const body = start.hookSpecificOutput.additionalContext
    .split("\n")
    .filter((l) => l.startsWith("#"));
  expect(body.length).toBeLessThanOrEqual(6);
  expect(body.at(-1)).toBe("#39 fact 39");
});

test("only one compactor holds the lock; a dead owner's lock is taken over", () => {
  const ctx = setup();
  const lock = join(dirs[0], "state", "compact.lock");
  const release = takeLock(lock);
  expect(release).toBeDefined();
  expect(takeLock(lock)).toBeUndefined();
  release?.();
  writeFileSync(lock, "999999");
  const again = takeLock(lock);
  expect(again).toBeDefined();
  again?.();
  void ctx;
});
