// The New Tab composer ships the bare (pad) icon column, with no tiles behind the chip glyphs
// (2026-11-23: "why is there a background icon grey thing here? we need to remove it"). This runs
// in every lane; newtab-chip-icons-bare.test.ts measures the glyphs in Chromium.
import { expect, test } from "bun:test";
import { newTabIconColumn } from "../src/agent-session/acpmux/newtab/iconColumn.experiment";

test("the shipped icon column arm is pad, the glyphs bare", () => {
  expect(newTabIconColumn.defaultArm).toBe("pad");
});
