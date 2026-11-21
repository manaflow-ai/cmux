// l10n-allow-file: test fixture prompts, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { lateDraftText } from "./composerDraft";
import { applyHostEvent } from "./pageHost";

// A Cloud start's page takes its seed's draft before the start hands its tab off (so the page can draw
// out of sight first); what the person typed in that tab in between reaches the page as `lateDraft`.

const scope = globalThis as Record<string, unknown>;
const hadWindow = "window" in scope;
const savedWindow = scope.window;

afterEach(() => {
  if (hadWindow) scope.window = savedWindow;
  else delete scope.window;
});

test("a prompt that still holds the handshake's draft takes the tab's text as it closed", () => {
  expect(lateDraftText("and the", "and the nightly", "and the")).toBe("and the nightly");
  expect(lateDraftText("", "typed late", "")).toBe("typed late");
  expect(lateDraftText("  ", "typed late", "")).toBe("typed late");
  // Emptied before the tab closed: the prompt is emptied too.
  expect(lateDraftText("and the", "", "and the")).toBe("");
});

test("text typed in the prompt meanwhile stays, after the tab's text", () => {
  expect(lateDraftText("mine", "and the nightly", "and the")).toBe("and the nightly\n\nmine");
  expect(lateDraftText("mine", "", "and the")).toBe("mine");
});

test("the host's lateDraft event reaches the page's bridge as it was sent", () => {
  const got: unknown[] = [];
  scope.window = { cmuxAcpmuxBridge: { lateDraft: (value: unknown) => got.push(value) } };
  applyHostEvent({ kind: "lateDraft", value: { text: "and the nightly", replaces: "and the" } });
  expect(got).toEqual([{ text: "and the nightly", replaces: "and the" }]);
});
