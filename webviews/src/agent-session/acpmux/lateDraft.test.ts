// l10n-allow-file: test fixture prompts, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { lateDraftText, mergedDraft } from "./composerDraft";
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

test("other text beside the handshake's draft stays, and the draft is in the prompt once", () => {
  // A first prompt that was refused comes back beside the draft, after it or before it.
  expect(lateDraftText("and the\n\nfix the build", "and the nightly", "and the")).toBe(
    "and the nightly\n\nfix the build",
  );
  expect(lateDraftText("fix the build\n\nand the", "and the nightly", "and the")).toBe(
    "and the nightly\n\nfix the build",
  );
  expect(lateDraftText("and the more", "and the nightly", "and the")).toBe("and the nightly\n\nmore");
  expect(lateDraftText("and the\n\nfix the build", "", "and the")).toBe("fix the build");
  // Text that only starts with the draft's letters is not the draft.
  expect(lateDraftText("apple\n\nb", "late", "a")).toBe("late\n\napple\n\nb");
});

test("the composer's own draft merge adds nothing to a prompt that took a late draft", () => {
  for (const typed of ["and the", "mine", "and the\n\nfix the build", "fix the build\n\nand the", ""]) {
    const next = lateDraftText(typed, "and the nightly", "and the");
    expect(mergedDraft(next, "and the nightly")).toBe(next);
  }
});

test("the host's lateDraft event reaches the page's bridge as it was sent", () => {
  const got: unknown[] = [];
  scope.window = { cmuxAcpmuxBridge: { lateDraft: (value: unknown) => got.push(value) } };
  applyHostEvent({ kind: "lateDraft", value: { text: "and the nightly", replaces: "and the" } });
  expect(got).toEqual([{ text: "and the nightly", replaces: "and the" }]);
});
