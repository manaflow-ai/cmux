// Typing in a new chat (a New Tab page or a chat with no session yet) warms the agent its Enter
// starts, so the first answer comes with no harness start (newChatPrewarm.ts).
import { expect, test } from "bun:test";
import { NewChatPrewarm, PREWARM_REFRESH_MS, RELEASE_AFTER_MS, type PrewarmTarget } from "./newChatPrewarm";

function harness(supported = true) {
  let now = 0;
  const timers: { at: number; run: () => void; live: boolean }[] = [];
  const calls: string[] = [];
  const name = (target: PrewarmTarget) => `${target.harness ?? "default"}@${target.cwd}`;
  const prewarm = new NewChatPrewarm(
    {
      supported: () => supported,
      prewarm: (target) => calls.push(`warm ${name(target)}`),
      release: (target) => calls.push(`release ${name(target)}`),
    },
    {
      now: () => now,
      schedule(run, ms) {
        const timer = { at: now + ms, run, live: true };
        timers.push(timer);
        return () => (timer.live = false);
      },
    },
  );
  const advance = (ms: number) => {
    now += ms;
    for (const timer of timers.filter((t) => t.live && t.at <= now)) {
      timer.live = false;
      timer.run();
    }
  };
  return { prewarm, calls, advance };
}

const here = { harness: "claude", cwd: "/work/app" };

test("the first typed character warms the agent once; more keys do not ask again", () => {
  const { prewarm, calls, advance } = harness();
  prewarm.typed("h", here);
  prewarm.typed("he", here);
  advance(1_000);
  prewarm.typed("hello", here);
  expect(calls).toEqual(["warm claude@/work/app"]);
});

test("a person still typing after the refresh interval keeps the agent warm", () => {
  const { prewarm, calls, advance } = harness();
  prewarm.typed("a", here);
  advance(PREWARM_REFRESH_MS);
  prewarm.typed("ab", here);
  expect(calls).toEqual(["warm claude@/work/app", "warm claude@/work/app"]);
});

test("Enter keeps the warm agent for the chat it starts", () => {
  const { prewarm, calls, advance } = harness();
  prewarm.typed("fix the bug", here);
  prewarm.sent();
  // The composer empties after the send; nothing is released.
  prewarm.typed("", here);
  prewarm.abandon();
  advance(RELEASE_AFTER_MS * 2);
  expect(calls).toEqual(["warm claude@/work/app"]);
});

test("a cleared prompt releases the warm agent unless the person types again", () => {
  const { prewarm, calls, advance } = harness();
  prewarm.typed("x", here);
  prewarm.typed("", here);
  advance(RELEASE_AFTER_MS - 1);
  prewarm.typed("y", here);
  advance(RELEASE_AFTER_MS);
  expect(calls).toEqual(["warm claude@/work/app"]);
  prewarm.typed("", here);
  advance(RELEASE_AFTER_MS);
  expect(calls).toEqual(["warm claude@/work/app", "release claude@/work/app"]);
});

test("closing the tab with an unsent prompt releases at once", () => {
  const { prewarm, calls } = harness();
  prewarm.typed("draft", here);
  prewarm.abandon();
  prewarm.abandon();
  expect(calls).toEqual(["warm claude@/work/app", "release claude@/work/app"]);
});

test("a new harness or folder warms the new one and releases the old one", () => {
  const { prewarm, calls } = harness();
  prewarm.typed("a", here);
  prewarm.typed("ab", { harness: "codex", cwd: "/work/app" });
  prewarm.typed("abc", { harness: "codex", cwd: "/work/lib" });
  expect(calls).toEqual([
    "warm claude@/work/app",
    "release claude@/work/app",
    "warm codex@/work/app",
    "release codex@/work/app",
    "warm codex@/work/lib",
  ]);
});

test("no folder known, or a connection that cannot prewarm: nothing is asked", () => {
  const unknown = harness();
  unknown.prewarm.typed("a", undefined);
  expect(unknown.calls).toEqual([]);
  const remote = harness(false);
  remote.prewarm.typed("a", here);
  remote.prewarm.abandon();
  expect(remote.calls).toEqual([]);
});

test("whitespace alone is no prompt", () => {
  const { prewarm, calls } = harness();
  prewarm.typed("   ", here);
  expect(calls).toEqual([]);
});
