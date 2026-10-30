// l10n-allow-file: test fixtures.
// Long tokens in a message (softBreaks.tsx) end a line at a range's `..` or a path's `/`, never
// mid-hash. Leo 2026-10-28: "WHY IS THIS RENDERING/MESSAGING NOT FIXED YET".
import { expect, test } from "bun:test";
import { isValidElement, type ReactNode } from "react";
import { softBreaks } from "./softBreaks";

const A = "9127e6194f1c2a9be07d3e6f58a1b2c3d4e50b1a";
const B = "68ab5dda55f4d5d0821cf21a4b520c2397145d00";

/// The text with each `<wbr>` as `|`.
const marked = (nodes: ReactNode[]) => nodes.map((node) => (isValidElement(node) ? "|" : String(node))).join("");

test("a SHA range breaks after its `..` and nowhere inside either hash", () => {
  expect(marked(softBreaks(`Review of manaflow-ai/cmux:${A}..${B} by box`, "k"))).toBe(
    `Review of manaflow-|ai/|cmux:|${A}..|${B} by box`,
  );
});

test("a path breaks after each separator", () => {
  expect(marked(softBreaks("webviews/src/agent-session/PromptText.tsx", "k"))).toBe(
    "webviews/|src/|agent-|session/|PromptText.|tsx",
  );
});

test("short words and a lone hash take no break points", () => {
  expect(softBreaks("Ship it at 2c1e.", "k")).toEqual(["Ship it at 2c1e."]);
  expect(softBreaks(`head ${A} ok`, "k")).toEqual([`head ${A} ok`]);
});
