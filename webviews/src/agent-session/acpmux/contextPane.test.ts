import { expect, test } from "bun:test";
import { CONTEXT_PANE, isContextPane, openContextPane } from "./contextPane";

test("opens Context as a focused session tab with its reserved reveal", async () => {
  const calls: unknown[] = [];
  expect(
    await openContextPane(async (method, params) => {
      calls.push({ method, params });
      return { opened: true };
    }, "Contexte"),
  ).toBe(true);
  expect(calls).toEqual([
    { method: "chat.subagentPane", params: { subagent: CONTEXT_PANE, focus: true, title: "Contexte" } },
  ]);
  expect(isContextPane(CONTEXT_PANE)).toBe(true);
  expect(isContextPane("tool-call-id")).toBe(false);
});

test("older hosts fall back to displaying Context in the current pane", async () => {
  expect(
    await openContextPane(async () => {
      throw new Error("unsupported");
    }, "Context"),
  ).toBe(false);
});
