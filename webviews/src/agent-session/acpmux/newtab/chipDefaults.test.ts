import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";
import { newTabChipSnapshot } from "./chipDefaults";

const catalog: PickerCatalog = {
  provisional: false,
  harnesses: [
    {
      id: "claude-code",
      name: "Claude Code",
      brand: "claude",
      acpmuxHarness: "claude",
      installed: true,
      pickable: true,
      defaultModel: "claude-opus-5-5",
      models: [{ id: "claude-opus-5-5", name: "Opus 5.5" } as PickerCatalog["harnesses"][number]["models"][number]],
    },
  ],
};
const snapshot = (model?: string) =>
  ({ sessions: [], catalog: [{ id: "claude", name: "Claude Code", models: [] }], summary: { sessionId: "", harness: "claude", ...(model ? { model } : {}) } }) as unknown as AcpmuxSnapshot;

// cx-e2aa decision (chief 2026-10-09): before a pick the New Tab chip names the agent's default model.
test("an unpicked chip takes the model catalog's default model for the shown agent", () => {
  expect(newTabChipSnapshot(snapshot("default"), catalog).summary?.model).toBe("claude-opus-5-5");
  expect(newTabChipSnapshot(snapshot(), catalog).summary?.model).toBe("claude-opus-5-5");
  // Listed with the catalog's name, so the chip reads "Opus 5.5".
  expect(newTabChipSnapshot(snapshot(), catalog).catalog[0]?.models).toEqual([{ id: "claude-opus-5-5", name: "Opus 5.5" }]);
});

test("a real model, an unknown agent or no catalog leave the chip as it is", () => {
  expect(newTabChipSnapshot(snapshot("claude-sonnet-5-5"), catalog).summary?.model).toBe("claude-sonnet-5-5");
  const other = { ...snapshot("default"), summary: { sessionId: "", harness: "codex", model: "default" } } as AcpmuxSnapshot;
  expect(newTabChipSnapshot(other, catalog).summary?.model).toBe("default");
  expect(newTabChipSnapshot(snapshot("default"), undefined).summary?.model).toBe("default");
});
