import { describe, expect, test } from "bun:test";
import type { NativePopupModel } from "./generated/popupProtocol";
import { NativePopupEventFence } from "./nativePopupEvents";

const model = (revision: number, checked: boolean, effort: string): NativePopupModel => ({
  schemaVersion: 1,
  id: "popup",
  revision,
  anchor: { left: 0, top: 0, right: 10, bottom: 10 },
  side: "bottom",
  align: "start",
  width: 240,
  rows: [
    { id: "fast", kind: "toggle", label: "Fast", checked },
    {
      id: "effort",
      kind: "choice",
      label: "Effort",
      value: effort,
      options: [
        { id: "low", label: "Low" },
        { id: "high", label: "High" },
      ],
    },
  ],
});

describe("native popup event fence", () => {
  test("a change from a toggle or choice rebuilt with new state is stale", () => {
    const fence = new NativePopupEventFence();
    fence.update(model(1, false, "low"));
    expect(fence.accepts({ type: "change", popupId: "popup", revision: 1, id: "fast", value: "true" })).toBe(true);
    fence.update(model(2, true, "high"));
    expect(fence.accepts({ type: "change", popupId: "popup", revision: 1, id: "fast", value: "true" })).toBe(false);
    expect(fence.accepts({ type: "change", popupId: "popup", revision: 1, id: "effort", value: "low" })).toBe(false);
    expect(fence.accepts({ type: "change", popupId: "popup", revision: 2, id: "fast", value: "false" })).toBe(true);
    // An update that leaves the state alone keeps earlier events valid.
    fence.update(model(3, true, "high"));
    expect(fence.accepts({ type: "change", popupId: "popup", revision: 2, id: "effort", value: "low" })).toBe(true);
  });
});
