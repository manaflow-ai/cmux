// Agents > Agents with cmux Tools, under the agents.cmuxMcp choice row (the onboarding step's
// question): it lists each coding agent and whether its config holds cmux's server (a dry run),
// Add Now answers yes and adds to the ready agents, Remove takes cmux's own entry out, and only
// what a click asked for is sent.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { ops, renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="agentTools"]')!;
const states = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-agent-tools]")].map(
    (row) => `${row.dataset.agentTools}:${row.dataset.agentToolsState}`,
  );
const button = (element: HTMLElement, action: string) =>
  element.querySelector<HTMLButtonElement>(`[data-agent-tools-action="${action}"]`)!;

test("the choice row and the card show on Agents; showing reads and changes nothing", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  expect(page.container.querySelector('[data-row-key="agents.cmuxMcp"]')).not.toBeNull();
  const element = card(page.container);
  expect(element.textContent).toContain("Agents with cmux Tools");
  expect(states(element)).toEqual(["claude:added", "codex:ready"]);
  expect(element.textContent).toContain("Added");
  expect(element.textContent).toContain("Not added");
  expect(page.provider.agentToolsRuns).toEqual([]);
  expect(ops(page.provider, "cmux.settings.agentTools.run")).toEqual([{ action: "refresh" }]);
  page.unmount();
});

test("Add Now adds to the ready agents and answers yes; Remove takes cmux out", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container);
  await act(async () => button(element, "add").click());
  await settle();
  expect(page.provider.agentToolsRuns).toEqual([{ action: "add" }]);
  expect(states(element)).toEqual(["claude:added", "codex:added"]);
  expect(button(element, "add").disabled).toBe(true);
  await act(async () => button(element, "remove").click());
  await settle();
  expect(page.provider.agentToolsRuns).toEqual([{ action: "add" }, { action: "remove" }]);
  expect(states(element)).toEqual(["claude:ready", "codex:ready"]);
  expect(button(element, "remove").disabled).toBe(true);
  page.unmount();
});
