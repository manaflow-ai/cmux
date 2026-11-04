import { expect, test } from "bun:test";
import { turnFoldStyle } from "./turnFoldStyle";

test("only ChatGPT and Codex fold to the conclusion with their calls drawn one under another", () => {
  expect(turnFoldStyle("codex")).toEqual({ conclusion: true, runs: false });
  expect(turnFoldStyle(undefined)).toEqual({ conclusion: true, runs: false });
});

test("Claude takes one Worked for with its runs folded inside, a variant id too", () => {
  expect(turnFoldStyle("claude")).toEqual({ conclusion: true, runs: true });
  expect(turnFoldStyle("claude-sr2")).toEqual({ conclusion: true, runs: true });
});

test("Gemini and Muse draw no Worked for; their runs fold in place", () => {
  for (const family of ["gemini", "gemini-cli", "muse", "muse-code"])
    expect(turnFoldStyle(family)).toEqual({ conclusion: false, runs: true });
});

test("a key on the object prototype is not a family", () => {
  expect(turnFoldStyle("constructor")).toEqual({ conclusion: true, runs: false });
});
