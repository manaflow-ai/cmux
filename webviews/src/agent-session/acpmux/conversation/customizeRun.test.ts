// l10n-allow-file: test fixture prompts, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import {
  hasCustomizeRunner,
  idleRun,
  readRun,
  runCustomize,
  runReducer,
  setCustomizeRunner,
  shareLine,
  shareTarget,
} from "./customizeRun";

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

test("Share: the tried target's one-line install, code only, kept through Keep", () => {
  const tryRun = { customize: "try", target: "pr:51234", minutes: 15 } as const;
  let s = runReducer(runReducer(idleRun, { type: "start" }), { type: "done", run: tryRun, ok: true });
  expect(s.target).toBe("pr:51234");
  expect(shareLine(s.target)).toBe("cmux customize try pr:51234");
  s = runReducer(runReducer(s, { type: "start" }), { type: "done", run: { customize: "keep" }, ok: false });
  expect(s).toMatchObject({ phase: "tried", failed: true, target: "pr:51234" });
  s = runReducer(runReducer(s, { type: "start" }), { type: "done", run: { customize: "keep" }, ok: true });
  expect(s).toMatchObject({ phase: "kept", target: "pr:51234" });
  expect(shareLine("branch:lane/x")).toBe("cmux customize try branch:lane/x");
  expect(shareLine("sha:abc1234")).toBe("cmux customize try sha:abc1234");
  // A folder or a profile name is this Mac's only; a bad target has no line.
  expect(shareLine("dir:/tmp/x")).toBeUndefined();
  expect(shareLine("darker")).toBeUndefined();
  expect(shareLine("pr:x")).toBeUndefined();
  expect(shareLine(undefined)).toBeUndefined();
});

test("Share asks the daemon: a profile's setup repo, a folder's branch, else the page's own line", async () => {
  // No daemon: code still shares; a profile or folder has nothing to say.
  expect(await shareTarget("pr:7")).toEqual({ line: "cmux customize try pr:7", note: "" });
  expect(await shareTarget("kept-night")).toEqual({ line: undefined, note: "" });
  const sent: unknown[] = [];
  setCustomizeRunner({
    available: () => true,
    run: async (run) => {
      sent.push(run);
      if ("target" in run && run.target === "kept-night")
        return { ok: true, output: "a setup repo", line: "cmux setup install /h/cmux-setups/kept-night" };
      if ("target" in run && run.target === "dir:/w") return { ok: false, output: "push them first" };
      return { ok: false, output: "unknown method" };
    },
  });
  expect(await shareTarget("kept-night")).toEqual({
    line: "cmux setup install /h/cmux-setups/kept-night",
    note: "a setup repo",
  });
  expect(await shareTarget("dir:/w")).toEqual({ line: undefined, note: "push them first" });
  // An older daemon without Share: code falls back to the page's line, quietly.
  expect(await shareTarget("branch:lane/x")).toEqual({ line: "cmux customize try branch:lane/x", note: "" });
  expect(sent).toEqual([
    { customize: "share", target: "kept-night" },
    { customize: "share", target: "dir:/w" },
    { customize: "share", target: "branch:lane/x" },
  ]);
  // An agent's wrap-up action can never be a share.
  expect(readRun({ customize: "share", target: "pr:1" })).toBeUndefined();
});
