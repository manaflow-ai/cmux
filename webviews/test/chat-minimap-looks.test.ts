// The VS Code Minimap's streaming placeholder looks (chatMinimap/placeholder.experiment.ts): the app
// always draws the shimmer, whatever cmux.experiments holds; only the gallery's compare view (which
// sets globalThis.cmuxExperiments) shows the others. The gallery entry's compare script settles for
// both variants, the at-rest one (no placeholder) included.
import { afterEach, expect, test } from "bun:test";
import entry from "../src/agent-session/acpmux/chatMinimap/chatMinimap.gallery";
import { placeholderLook } from "../src/agent-session/acpmux/chatMinimap/ChatMinimap";

const scope = globalThis as { localStorage?: unknown; cmuxExperiments?: Record<string, string> };
const storage = scope.localStorage;
afterEach(() => {
  scope.localStorage = storage;
  delete scope.cmuxExperiments;
});

test("a stored experiment override never changes the app's look; the gallery's arm does", () => {
  scope.localStorage = { getItem: () => JSON.stringify({ "chat-minimap-placeholder": "dotted" }) };
  expect(placeholderLook()).toBe("shimmer");
  scope.cmuxExperiments = { "chat-minimap-placeholder": "lines" };
  expect(placeholderLook()).toBe("lines");
});

test("the compare script settles on the at-rest variant, which has no placeholder", async () => {
  // The at-rest page: the picture drawn, no placeholder.
  const document = {
    querySelector: (selector: string) =>
      selector.includes("placeholder") ? null : selector.includes("canvas") ? {} : null,
  };
  const waitFor = async (check: () => unknown) => {
    for (let tries = 0; tries < 20; tries += 1) if (check()) return;
    throw new Error("timed out");
  };
  for (const step of entry.experiment!.script) await step.run({ document, waitFor } as never);
});
