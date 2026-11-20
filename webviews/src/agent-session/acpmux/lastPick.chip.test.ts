// cmux#47677: the folder, the place and the model are each their own pick. A New Tab page names its
// folder's last pick until the person picks an agent or model there; a folder picked after that never
// swaps the chips back to that folder's older pick.
import { expect, test } from "bun:test";
import { chipPick } from "./lastPick";

const claude = { harness: "claude", model: "opus" };
const codex = { harness: "codex", model: "gpt-6.1" };
const gemini = { harness: "gemini", model: "neon" };

test("before any pick on the page, each folder names its own last pick", () => {
  expect(chipPick(claude, { pick: codex, picked: true }, codex)).toBe(claude);
  expect(chipPick(undefined, { pick: codex, picked: false }, undefined)).toBeUndefined();
});

test("a pick made on the page stays through a folder pick", () => {
  // Opened on codex; the person picked gemini; the next folder's own last pick was claude.
  expect(chipPick(claude, { pick: gemini, picked: true }, codex)).toBe(gemini);
});

test("the app's copy arriving after the page opened is no pick", () => {
  expect(chipPick(claude, { pick: gemini, picked: false }, codex)).toBe(claude);
});
