// A started Claude Code chat that picks another model with Ultracode in the model menu: the model
// lands, then the effort once the chat runs it. Ultracode is no level of the chat's effort option
// (acpmux lists low..max there and offers Ultracode as its own switch), so the pending pick waited for
// a level the option never lists and dropped the effort. It rides Extra High through the same option.
import { expect, test } from "bun:test";
import { effortTakes } from "../src/agent-session/acpmux/composerPickerModel";

const CLAUDE = ["low", "medium", "high", "xhigh", "max"];

test("a chat takes a level its effort option lists", () => {
  expect(effortTakes("high", CLAUDE, false)).toBe(true);
  expect(effortTakes("minimal", CLAUDE, true)).toBe(false);
});

test("a chat that offers Ultracode takes it through Extra High", () => {
  expect(effortTakes("ultracode", CLAUDE, true)).toBe(true);
});

test("Ultracode needs both the chat's switch and an Extra High level", () => {
  expect(effortTakes("ultracode", CLAUDE, false)).toBe(false);
  expect(effortTakes("ultracode", ["low", "high"], true)).toBe(false);
});
