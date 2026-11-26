// l10n-allow-file: test fixture prompts, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { hasCustomizeRunner, idleRun, readRun, runCustomize, runReducer, setCustomizeRunner } from "./customizeRun";

afterEach(() => setCustomizeRunner(undefined));

test("readRun mirrors the daemon allowlist", () => {
  expect(readRun({ customize: "keep" })).toEqual({ customize: "keep" });
  expect(readRun({ customize: "revert" })).toEqual({ customize: "revert" });
  expect(readRun({ customize: "try", target: "pr:12", minutes: 30 })).toEqual({
    customize: "try",
    target: "pr:12",
    minutes: 30,
  });
  expect(readRun({ customize: "try", target: "dir:/tmp/x" })).toBeTruthy();
  expect(readRun({ customize: "try", target: "sha:abc1234" })).toBeTruthy();
  expect(readRun({ customize: "try", target: "--help" })).toBeUndefined();
  expect(readRun({ customize: "try", target: "pr:x" })).toBeUndefined();
  expect(readRun({ customize: "try", target: "Upper" })).toBeUndefined();
  expect(readRun({ customize: "try", target: "pr:1", minutes: 0 })).toBeUndefined();
  expect(readRun({ customize: "try", target: "pr:1", minutes: 241 })).toBeUndefined();
  expect(readRun({ customize: "try" })).toBeUndefined();
  expect(readRun({ customize: "rm" })).toBeUndefined();
  expect(readRun("keep")).toBeUndefined();
});

test("runReducer: try then keep or revert, failures go back", () => {
  const tryRun = { customize: "try", target: "pr:1" } as const;
  let s = runReducer(idleRun, { type: "start" });
  expect(s.phase).toBe("running");
  s = runReducer(s, { type: "done", run: tryRun, ok: true });
  expect(s.phase).toBe("tried");
  s = runReducer(s, { type: "start" });
  s = runReducer(s, { type: "done", run: { customize: "keep" }, ok: false });
  expect(s).toMatchObject({ phase: "tried", failed: true });
  s = runReducer(runReducer(s, { type: "start" }), { type: "done", run: { customize: "revert" }, ok: true });
  expect(s.phase).toBe("reverted");
  expect(runReducer(runReducer(idleRun, { type: "start" }), { type: "done", run: tryRun, ok: false })).toMatchObject({
    phase: "idle",
    failed: true,
  });
});

test("runner hook", async () => {
  expect(hasCustomizeRunner()).toBe(false);
  expect((await runCustomize({ customize: "keep" })).ok).toBe(false);
  setCustomizeRunner({ available: () => true, run: async () => ({ ok: true, output: "hi" }) });
  expect(hasCustomizeRunner()).toBe(true);
  expect(await runCustomize({ customize: "keep" })).toEqual({ ok: true, output: "hi" });
});

test("Go: only a PR, offered after that PR's try-on, and it ends the card", () => {
  expect(readRun({ customize: "go", target: "pr:57001" })).toEqual({ customize: "go", target: "pr:57001" });
  expect(readRun({ customize: "go", target: "branch:x" })).toBeUndefined();
  expect(readRun({ customize: "go", target: "darker" })).toBeUndefined();
  expect(readRun({ customize: "go" })).toBeUndefined();
  const tried = (target: string) =>
    runReducer(runReducer(idleRun, { type: "start" }), { type: "done", run: { customize: "try", target }, ok: true });
  expect(tried("pr:57001")).toMatchObject({ phase: "tried", pr: "pr:57001" });
  expect(tried("darker").pr).toBeUndefined();
  const went = runReducer(runReducer(tried("pr:57001"), { type: "start" }), {
    type: "done",
    run: { customize: "go", target: "pr:57001" },
    ok: true,
  });
  expect(went.phase).toBe("went");
  const failed = runReducer(runReducer(tried("pr:57001"), { type: "start" }), {
    type: "done",
    run: { customize: "go", target: "pr:57001" },
    ok: false,
  });
  expect(failed).toMatchObject({ phase: "tried", failed: true, pr: "pr:57001" });
});
