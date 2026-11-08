import { sendChoiceForKey, sendMenuChoices } from "../composer/sendMenuModel";
import { expect, test } from "bun:test";
import type { PickerCatalog, PickerHarness } from "../modelCatalogData";
import { MAX_RUNS, defaultVariants, fanoutVariants, nextVariant, variantLabel, withModel } from "./runOnAgents";

const model = (id: string, shortName: string, efforts: string[] = []) =>
  ({ id, name: shortName, shortName, efforts, fast: false, searchText: id }) as PickerHarness["models"][number];
const harness = (id: string, name: string, models: PickerHarness["models"], installed = true): PickerHarness => ({
  id,
  name,
  brand: id,
  acpmuxHarness: id,
  installed,
  pickable: true,
  models,
});
const catalog: PickerCatalog = {
  provisional: false,
  harnesses: [
    harness("claude", "Claude", [
      model("claude-opus-5-5", "Opus 5.5", ["low", "medium", "high"]),
      model("claude-sonnet-5-5", "Sonnet 5.5", ["low", "medium"]),
    ]),
    harness("codex", "Codex", [model("gpt-6.1-sol", "GPT-6.1 Sol")]),
    harness("gemini", "Gemini", [], false),
    harness("opencode", "OpenCode", []),
  ],
};

test("a run starts on Claude Opus, Codex and Claude Sonnet", () => {
  expect(defaultVariants(catalog)).toEqual([
    { harness: "claude", model: "claude-opus-5-5" },
    { harness: "codex" },
    { harness: "claude", model: "claude-sonnet-5-5" },
  ]);
});

test("with no Claude it still starts on two installed agents, never one that is not installed", () => {
  const noClaude = { ...catalog, harnesses: catalog.harnesses.filter((h) => h.id !== "claude") };
  expect(defaultVariants(noClaude)).toEqual([{ harness: "codex" }, { harness: "opencode" }]);
  expect(defaultVariants(undefined)).toEqual([]);
});

test("an added agent is one the run does not use yet", () => {
  expect(nextVariant(catalog, defaultVariants(catalog))).toEqual({ harness: "opencode" });
  expect(nextVariant(catalog, [{ harness: "claude" }, { harness: "codex" }, { harness: "opencode" }])).toEqual({
    harness: "claude",
  });
});

test("a model change drops an effort the new model does not offer", () => {
  const opusHigh = { harness: "claude", model: "claude-opus-5-5", effort: "high" };
  expect(withModel(catalog, opusHigh, "claude-sonnet-5-5")).toEqual({ harness: "claude", model: "claude-sonnet-5-5" });
  const opusLow = { ...opusHigh, effort: "low" };
  expect(withModel(catalog, opusLow, "claude-sonnet-5-5")).toEqual({
    harness: "claude",
    model: "claude-sonnet-5-5",
    effort: "low",
  });
  expect(withModel(catalog, opusLow, undefined)).toEqual({ harness: "claude" });
});

test("labels, and the wire's 2 to 4 bound", () => {
  expect(variantLabel(catalog, { harness: "claude", model: "claude-opus-5-5", effort: "high" })).toBe(
    "Claude · Opus 5.5 · high",
  );
  expect(variantLabel(catalog, { harness: "codex" })).toBe("Codex");
  expect(fanoutVariants([{ harness: "codex" }])).toBeUndefined();
  const five = Array.from({ length: MAX_RUNS + 1 }, () => ({ harness: "codex" }));
  expect(fanoutVariants(five)).toBeUndefined();
  expect(
    fanoutVariants([
      { harness: "codex", model: "" },
      { harness: "claude", effort: "high" },
    ]),
  ).toEqual([{ harness: "codex" }, { harness: "claude", effort: "high" }]);
});

test("Send's menu offers Run on several agents for a typed draft, on ⌘⌥Return, never ⌘⇧Return", () => {
  const key = (meta: boolean, alt: boolean, shift = false) =>
    sendChoiceForKey({ key: "Enter", metaKey: meta, altKey: alt, shiftKey: shift, ctrlKey: false });
  expect(key(true, true)).toBe("runOn");
  // ⌘⇧Return is Ghostty's Toggle Pane Zoom, reserved in every pane.
  expect(key(true, false, true)).toBeUndefined();
  expect(sendMenuChoices({ draft: true, sendSteers: false, side: false, files: false, runOn: true })).toEqual([
    "send",
    "runOn",
  ]);
  // A run's prompt is text alone, and a chat that cannot start runs has no row.
  expect(sendMenuChoices({ draft: true, sendSteers: false, side: false, files: true, runOn: true })).toEqual([]);
  expect(sendMenuChoices({ draft: true, sendSteers: false, side: false, files: false })).toEqual([]);
});
