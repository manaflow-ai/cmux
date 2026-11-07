// Agents > Agent integrations: optional help for coding-agent hooks. The card stays collapsed
// and reads nothing until opened; opened, it lists `cmux agent hook status` with Install, Repair
// or Remove by state, sends only the gesture clicked, and a file cmux did not create in the way
// offers no Install but says what is there and gives the command to run by hand.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { ops, renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="agentIntegrations"]')!;
const ids = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-integration]")].map((row) => row.dataset.integration);
const actions = (element: HTMLElement, id: string) =>
  [...element.querySelectorAll<HTMLElement>(`[data-integration="${id}"] [data-integration-action]`)].map(
    (button) => button.dataset.integrationAction,
  );

test("closed, the card reads and runs nothing", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container);
  expect(element.querySelector("details")!.open).toBe(false);
  expect(ops(page.provider, "cmux.settings.integrations.run")).toEqual([]);
  expect(ops(page.provider, "cmux.settings.integrations.state")).toEqual([]);
  expect(page.provider.integrationRuns).toEqual([]);
  page.unmount();
});

test("opened, it lists each agent's hooks with the gestures its state allows", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  await settle();
  const element = card(page.container);
  expect(element.querySelector("details")!.open).toBe(true);
  expect(ids(element)).toEqual(["claude", "codex", "amp", "gemini"]);
  expect(element.textContent).toContain("Claude Code");
  expect(actions(element, "claude")).toEqual(["remove"]);
  expect(actions(element, "codex")).toEqual(["repair", "remove"]);
  expect(actions(element, "gemini")).toEqual(["install"]);
  // A file cmux did not create: no Install, what is in the way, and the command to copy.
  expect(actions(element, "amp")).toEqual(["copy"]);
  const amp = element.querySelector<HTMLElement>('[data-integration="amp"]')!;
  expect(amp.querySelector("[data-integration-reason]")!.textContent).toBe(
    "A file cmux didn’t create is here. Move it first.",
  );
  expect(amp.textContent).toContain("~/.config/amp/plugins/cmux-tui-journal.ts");
  expect(amp.querySelector("[data-integration-command]")!.textContent).toBe("cmux agent hook install amp");
  // Opening only read status.
  expect(page.provider.integrationRuns).toEqual([]);
  page.unmount();
});

test("a click sends that gesture for that agent and shows the new state", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  await settle();
  const element = card(page.container);
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-integration="gemini"] [data-integration-action="install"]');
  await press('[data-integration="codex"] [data-integration-action="repair"]');
  await press('[data-integration="claude"] [data-integration-action="remove"]');
  expect(page.provider.integrationRuns).toEqual([
    { action: "install", id: "gemini" },
    { action: "repair", id: "codex" },
    { action: "remove", id: "claude" },
  ]);
  expect(element.querySelector<HTMLElement>('[data-integration="gemini"]')!.dataset.integrationState).toBe("installed");
  expect(actions(element, "claude")).toEqual(["install"]);
  await press('[data-integration="amp"] [data-integration-action="copy"]');
  expect(page.provider.clipboard).toBe("cmux agent hook install amp");
  page.unmount();
});

test("without the cmux CLI the card says so and still gives the command", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  page.provider.integrations = {
    loading: false,
    problem: "unavailable",
    command: "cmux agent hook install",
    providers: [],
  };
  await act(async () =>
    card(page.container).querySelector<HTMLButtonElement>('[data-integration-action="refresh"]')!.click(),
  );
  await settle();
  const element = card(page.container);
  expect(element.querySelector("[data-integrations-problem]")!.getAttribute("data-integrations-problem")).toBe(
    "unavailable",
  );
  expect(element.querySelector("[data-integrations-command]")!.textContent).toBe("cmux agent hook install");
  page.unmount();
});

// cmux skills for agents outside cmux's chats (Aziz 2026-11-06): nothing installed until the
// person clicks Install on a folder, which sends only that folder; a folder the person made is
// never offered Install.
test("cmux skills are opt-in per global folder and install only on a click", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  await settle();
  const element = card(page.container);
  const section = element.querySelector<HTMLElement>("[data-skills-section]")!;
  const targets = [...section.querySelectorAll<HTMLElement>("[data-skills-target]")];
  expect(targets.map((row) => [row.dataset.skillsTarget, row.dataset.skillsState])).toEqual([
    ["claude", "absent"],
    ["agents", "absent"],
  ]);
  expect(section.textContent).toContain("Codex, OpenCode and other agents");
  expect(section.querySelector("[data-skills-command]")!.textContent).toBe("cmux agent skills install --global");
  // The hook rows stay one agent each.
  expect(ids(element)).toEqual(["claude", "codex", "amp", "gemini"]);
  expect(page.provider.integrationRuns).toEqual([]);
  await act(async () =>
    section.querySelector<HTMLButtonElement>('[data-skills-target="claude"] [data-skills-action="install"]')!.click(),
  );
  await settle();
  expect(page.provider.integrationRuns).toEqual([{ action: "install", id: "claude", kind: "skills" }]);
  const after = card(page.container).querySelector<HTMLElement>('[data-skills-target="claude"]')!;
  expect(after.dataset.skillsState).toBe("installed");
  page.unmount();
});

test("a folder cmux did not write offers no Install, only the command to copy", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  page.provider.integrations = {
    ...page.provider.integrations,
    skills: {
      problem: null,
      command: "cmux agent skills install --global",
      providers: [
        {
          id: "agents",
          path: "~/.agents/skills",
          state: "conflict",
          reason: "not_owned",
          detail: "~/.agents/skills already holds cmux-browser that cmux did not install",
          error: null,
        },
      ],
    },
  };
  await act(async () =>
    card(page.container).querySelector<HTMLButtonElement>('[data-integration-action="refresh"]')!.click(),
  );
  await settle();
  const row = card(page.container).querySelector<HTMLElement>('[data-skills-target="agents"]')!;
  expect([...row.querySelectorAll<HTMLElement>("[data-skills-action]")].map((b) => b.dataset.skillsAction)).toEqual([
    "copy",
  ]);
  expect(row.querySelector("[data-skills-reason]")!.textContent).toContain("cmux leaves it alone");
  page.unmount();
});
