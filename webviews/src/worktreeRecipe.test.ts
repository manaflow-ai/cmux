// The worktree recipe's wire shapes: a `git.worktree.setup` reply reads into the recipe and the
// run, output reads join on `since`/`output_end`, and an edit becomes the saved override.
import { expect, test } from "bun:test";
import {
  SETUP_OUTPUT_CAP,
  appendSetupOutput,
  isFinalSetupState,
  lastOutputLine,
  readSetupReply,
  savedRecipe,
} from "./worktreeRecipe";

test("a setup reply reads into the recipe and the run", () => {
  const read = readSetupReply({
    root: "/w/fix",
    main_root: "/src/app",
    recipe: {
      setup: "bun install",
      run: null,
      teardown: null,
      include: [".env", "local.json"],
      repository: { setup: "npm ci", include: [".env"] },
      saved: { setup: "bun install", include: ["local.json"] },
      files: [".worktreeinclude"],
    },
    run: {
      state: "failed",
      port: 40_010,
      setup: "bun install",
      exit_code: 2,
      include: { copied: 1, kept: 0, outside: [], problems: [] },
      started_ms: "1000",
      finished_ms: "5100",
      output: "boom\n",
      output_start: "0",
      output_end: "5",
    },
  });
  expect(read?.mainRoot).toBe("/src/app");
  expect(read?.recipe?.repository).toEqual({ setup: "npm ci", include: [".env"] });
  expect(read?.recipe?.saved).toEqual({ setup: "bun install", include: ["local.json"] });
  expect(read?.run).toMatchObject({ state: "failed", port: 40_010, exitCode: 2, startedMs: 1000, finishedMs: 5100 });
  expect(read?.run.include?.copied).toBe(1);
  // A mutation-shaped reply (`value`) reads the same; an unknown state is none.
  expect(readSetupReply({ value: { root: "/w", run: { state: "later" } } })?.run.state).toBe("none");
  expect(readSetupReply({})).toBeUndefined();
});

test("only copying and running are live", () => {
  expect(isFinalSetupState("copying")).toBe(false);
  expect(isFinalSetupState("running")).toBe(false);
  for (const state of ["none", "succeeded", "failed", "timed_out", "interrupted"] as const)
    expect(isFinalSetupState(state)).toBe(true);
});

test("output reads join where the last one ended, and a gap starts over", () => {
  const run = (output: string, start: string, end: string) => ({
    state: "running" as const,
    output,
    outputStart: start,
    outputEnd: end,
  });
  expect(appendSetupOutput("abc", "3", run("def", "3", "6"))).toBe("abcdef");
  // The host dropped the middle (more than its cap since the last read): its tail stands alone.
  expect(appendSetupOutput("abc", "3", run("xyz", "90000", "90003"))).toBe("xyz");
  const long = "x".repeat(SETUP_OUTPUT_CAP);
  expect(appendSetupOutput(long, String(long.length), run("tail", String(long.length), "0")).endsWith("tail")).toBe(
    true,
  );
  expect(appendSetupOutput(long, String(long.length), run("tail", String(long.length), "0")).length).toBe(
    SETUP_OUTPUT_CAP,
  );
  expect(lastOutputLine("one\ntwo\n\n")).toBe("two");
});

test("the kept output is capped in UTF-8 bytes and never splits a character", () => {
  const run = (output: string) => ({ state: "running" as const, output, outputStart: "0", outputEnd: "0" });
  const kept = appendSetupOutput("", "0", run(`a${"é".repeat(SETUP_OUTPUT_CAP)}`));
  expect(new TextEncoder().encode(kept).length).toBeLessThanOrEqual(SETUP_OUTPUT_CAP);
  expect(kept).toBe("é".repeat(SETUP_OUTPUT_CAP / 2));
  const emoji = appendSetupOutput("", "0", run(`x${"😀".repeat(SETUP_OUTPUT_CAP / 4)}`));
  expect(emoji).toBe("😀".repeat(SETUP_OUTPUT_CAP / 4));
});

test("an edit becomes the saved override: empty scripts stay (they turn the repository's off), blank lines go", () => {
  expect(savedRecipe({ setup: "", include: ["  .env ", "", " "] })).toEqual({ setup: "", include: [".env"] });
  expect(savedRecipe({ include: [""] })).toBeNull();
  expect(savedRecipe({})).toBeNull();
});
