// cmux#47677: the folder, the place and the model are each their own pick. A New Tab page names its
// folder's last pick until the person picks an agent or model there; a folder picked after that never
// swaps the chips back to that folder's older pick.
import { expect, test } from "bun:test";
import { chipPick } from "./lastPick";

const claude = { harness: "claude", model: "opus" };
const codex = { harness: "codex", model: "gpt-6.1" };
const gemini = { harness: "gemini", model: "neon" };

test("before any pick on the page, each folder names its own last pick", () => {
  expect(chipPick(claude, { pick: codex, seq: 4 }, 4)).toBe(claude);
  expect(chipPick(undefined, { seq: 0 }, 0)).toBeUndefined();
});

test("a pick made on the page stays through a folder pick", () => {
  // Opened on codex; the person picked gemini; the next folder's own last pick was claude.
  expect(chipPick(claude, { pick: gemini, seq: 5 }, 4)).toBe(gemini);
});

test("a pick naming the same agent and model as the last one still counts", () => {
  // The global last pick was claude/opus; folders A and B remember codex. On A the person picks
  // claude/opus again, then folder B: the chips stay claude/opus.
  expect(chipPick(codex, { pick: claude, seq: 5 }, 4)).toBe(claude);
});

test("the app's copy arriving after the page opened is no pick", () => {
  expect(chipPick(claude, { pick: gemini, seq: 0 }, 0)).toBe(claude);
});
