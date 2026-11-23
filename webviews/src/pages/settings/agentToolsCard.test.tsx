// Agents > Agents on This Mac, under the agents.cmuxMcp choice row (the onboarding step's question): it
// lists each coding agent and whether it gets cmux's tools when cmux starts it, Turn On answers yes, the
// manual lines for agents started elsewhere copy on a click, and only what a click asked for is sent.
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
  element.querySelector<HTMLButtonElement>(`[data-agent-tools-action="${action}"]`);

test("the choice row and the card show on Agents; showing reads and changes nothing", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  expect(page.container.querySelector('[data-row-key="agents.cmuxMcp"]')).not.toBeNull();
  const element = card(page.container);
  expect(element.textContent).toContain("Agents on This Mac");
  expect(element.textContent).toContain("Agents you start in cmux get cmux’s tools.");
  expect(states(element)).toEqual(["claude:ready", "codex:ready"]);
  expect(element.textContent).toContain("Off in cmux");
  expect(page.provider.agentToolsRuns).toEqual([]);
  expect(ops(page.provider, "cmux.settings.agentTools.run")).toEqual([{ action: "refresh" }]);
  page.unmount();
});

test("Turn On answers yes; the agents then get cmux's tools in cmux and the button goes", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container);
  await act(async () => button(element, "turnOn")!.click());
  await settle();
  expect(page.provider.agentToolsRuns).toEqual([{ action: "turnOn" }]);
  expect(states(element)).toEqual(["claude:terminals", "codex:terminals"]);
  expect(element.textContent).toContain("Gets cmux’s tools in cmux");
  expect(button(element, "turnOn")).toBeNull();
  page.unmount();
});

test("the manual lines are labelled manual, and Copy copies one; nothing runs them", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container);
  const manual = element.querySelector<HTMLElement>("[data-agent-tools-manual]")!;
  expect(manual.textContent).toContain("Use cmux Tools Outside cmux (Manual)");
  expect(manual.textContent).toContain("run an agent’s line yourself");
  const lines = [...manual.querySelectorAll("[data-agent-tools-manual-line]")].map((line) => line.textContent);
  expect(lines).toEqual(page.provider.agentTools.manual!);
  await act(async () => manual.querySelectorAll<HTMLButtonElement>('[data-agent-tools-action="copy"]')[1]!.click());
  await settle();
  expect(page.provider.clipboard).toBe(page.provider.agentTools.manual![1]!);
  expect(page.provider.agentToolsRuns).toEqual([]);
  page.unmount();
});

test("an older host without the choice or manual lines still lists the agents", async () => {
  const page = await renderPage({
    path: "/settings/agents",
    setup: (provider) => {
      provider.agentTools = {
        loaded: true,
        applying: false,
        failed: false,
        rows: [{ id: "codex", name: "Codex", state: "failed" }],
      };
    },
  });
  await settle();
  const element = card(page.container);
  expect(states(element)).toEqual(["codex:failed"]);
  expect(element.querySelector(".badge-warning")).not.toBeNull();
  expect(element.querySelector("[data-agent-tools-manual]")).toBeNull();
  page.unmount();
});

test("an old cmux entry in an agent's own settings shows its remove line, and only a click removes it", async () => {
  const page = await renderPage({
    path: "/settings/agents",
    setup: (provider) => {
      provider.agentTools = {
        ...provider.agentTools,
        rows: [
          { id: "claude", name: "Claude Code", state: "ready", leftover: "claude mcp remove --scope user cmux" },
          { id: "codex", name: "Codex", state: "ready", leftover: null },
        ],
      };
    },
  });
  await settle();
  const element = card(page.container);
  const notice = element.querySelectorAll<HTMLElement>("[data-agent-tools-leftover]");
  expect(notice.length).toBe(1);
  expect(notice[0]!.textContent).toBe("Its own settings have a cmux entry, used outside cmux.");
  expect(element.querySelector("[data-agent-tools-leftover-line]")!.textContent).toBe(
    "claude mcp remove --scope user cmux",
  );
  // Showing removes nothing.
  expect(page.provider.agentToolsRuns).toEqual([]);
  await act(async () => button(element, "removeLeftover")!.click());
  await settle();
  expect(page.provider.agentToolsRuns).toEqual([{ action: "removeLeftover", id: "claude" }]);
  expect(element.querySelector("[data-agent-tools-leftover]")).toBeNull();
  page.unmount();
});

test("when Remove keeps an entry with settings cmux could not put back, the card says why", async () => {
  const why = "Claude Code's cmux entry has settings cmux would not put back (env API_TOKEN), so it is left as it is.";
  const page = await renderPage({
    path: "/settings/agents",
    setup: (provider) => {
      provider.agentToolsKeeps = why;
      provider.agentTools = {
        ...provider.agentTools,
        rows: [{ id: "claude", name: "Claude Code", state: "ready", leftover: "claude mcp remove --scope user cmux" }],
      };
    },
  });
  await settle();
  const element = card(page.container);
  expect(element.querySelector("[data-agent-tools-note]")).toBeNull();
  await act(async () => button(element, "removeLeftover")!.click());
  await settle();
  expect(element.querySelector("[data-agent-tools-note]")!.textContent).toBe(why);
  // Still listed, still removable once the person has kept what they need.
  expect(element.querySelector("[data-agent-tools-leftover]")).not.toBeNull();
  page.unmount();
});
