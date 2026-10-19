// Lucas 2026-10-19: Files and Thread details side by side looked wrong, and Thread details under the
// header row did too. While the chat's viewer (Files, a file, Changes) is open beside the chat, Thread
// details floats as the popover it already is beside the browser; closed, it is its own column again.
import { expect, test } from "bun:test";
import { detailsFloat } from "../src/agent-session/acpmux/chatViewerPanels";

test("Thread details floats while the chat's viewer is open, and only with the viewer lab on", () => {
  expect(detailsFloat(true, { diff: false, file: false, files: false })).toBe(false);
  expect(detailsFloat(true, { diff: false, file: false, files: true })).toBe(true);
  expect(detailsFloat(true, { diff: false, file: true, files: false })).toBe(true);
  expect(detailsFloat(true, { diff: true, file: false, files: false })).toBe(true);
  expect(detailsFloat(false, { diff: true, file: true, files: true })).toBe(false);
});
