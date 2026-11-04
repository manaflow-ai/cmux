import { expect, test } from "bun:test";
import { contextInventory } from "./contextInventory";

test("retains provider totals without double-counting nested category detail", () => {
  const value = contextInventory({
    providerTotalTokens: 100,
    cmuxTokens: 12,
    parts: [
      { id: "category", tokens: 100, measurement: "measured" },
      { id: "nested-tool", tokens: 40, measurement: "measured" },
    ],
  });
  expect(value.totalTokens).toBe(100);
  expect(value.parts[0].textAvailable).toBe(false);
  expect(value.cmuxTokens).toBe(12);
});

test("partial reports do not claim a measured total or expose unavailable settings", () => {
  const value = contextInventory({
    totalTokens: 12,
    cmuxTokens: 12,
    parts: [{ measurement: "unavailable" }],
  });
  expect(value.totalTokens).toBeUndefined();
  expect(value.settings).toBeUndefined();
  expect(value.parts[0].measurement).toBe("unavailable");
  expect(value.parts[0].tokenCount).toBeUndefined();
  expect(
    contextInventory({ canEditOverrides: false, overrides: { user: null, project: null, cwd: "" } }).settings,
  ).toBeUndefined();
});

test("preserves a disabling empty project override separately from session text", () => {
  const value = contextInventory({
    canEditOverrides: true,
    overrides: { user: "user text", project: "", cwd: "/project" },
    parts: [{ text: "original text", tokens: 4, editable: true, measurement: "estimated" }],
  });
  expect(value.settings).toEqual({ user: "user text", project: "", cwd: "/project", defaultText: undefined });
  expect(value.parts[0].text).toBe("original text");
  expect(value.parts[0].editable).toBeUndefined();
});
