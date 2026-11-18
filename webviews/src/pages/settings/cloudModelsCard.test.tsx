// Settings > Cloud > Models for Cloud (CloudModelsCard.tsx, model-connections.md Revision 2): each row
// says whether Cloud chats on it are set up, by the rule a Cloud start uses, and names only connections
// that serve Cloud, so a Mac-only login is neither read as set up nor explained here; each row fixes
// itself in place (Sign in with ChatGPT, Turn On, Set Up opening Models' own steps); a focus opens the
// page on its row; and Models' This Mac only rows link here.
import { afterAll, afterEach, expect, test } from "bun:test";
import { cloudReadiness } from "./components/CloudModelsCard";
import { mockModels } from "./mockModels";
import type { ModelsState } from "./ops";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, changeValue, click } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const render = async (models: ModelsState, path = "/settings/cloud") => {
  page = await renderPage({
    path,
    setup: (provider) => {
      provider.models = structuredClone(models);
    },
  });
  return page;
};
const card = (rendered: Rendered) => rendered.container.querySelector<HTMLElement>('[data-card="cloudModels"]')!;
const row = (rendered: Rendered, id: string) => card(rendered).querySelector<HTMLElement>(`[data-cloud-row="${id}"]`)!;
const statuses = (rendered: Rendered) =>
  Object.fromEntries(
    [...card(rendered).querySelectorAll<HTMLElement>("[data-cloud-row]")].map((r) => [
      r.dataset.cloudRow,
      r.dataset.cloudStatus,
    ]),
  );
const sheet = () => document.querySelector<HTMLElement>("[data-models-sheet]");

test("Settings > Cloud holds Models for Cloud, Cloud Environments and Cloud Workspaces", async () => {
  const rendered = await render(mockModels.empty);
  expect(rendered.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("cloud");
  expect(card(rendered).textContent).toContain("Models for Cloud");
  expect(rendered.container.querySelector('[data-card="cloudEnvironments"]')).not.toBeNull();
  expect(rendered.container.textContent).toContain("Cloud Workspaces");
});

test("with nothing connected, every row is Not set up for Cloud with its way in", async () => {
  const rendered = await render(mockModels.empty);
  expect(statuses(rendered)).toEqual({ claude: "missing", chatgpt: "missing", apiKey: "missing" });
  expect(row(rendered, "claude").textContent).toContain("Not set up for Cloud");
  expect(row(rendered, "claude").querySelector('[data-cloud-action="setUpClaude"]')).not.toBeNull();
  expect(row(rendered, "chatgpt").querySelector('[data-cloud-action="connectChatGPT"]')?.textContent).toBe(
    "Sign in with ChatGPT",
  );
  expect(row(rendered, "apiKey").querySelector('[data-menu="cloud-api-key"]')).not.toBeNull();
});

test("Mac-only logins are not listed: the card names only what serves Cloud", async () => {
  const rendered = await render(mockModels.macOnly);
  expect(statuses(rendered)).toEqual({ claude: "missing", chatgpt: "missing", apiKey: "missing" });
  expect(card(rendered).textContent).toContain("What Cloud chats run on.");
  expect(card(rendered).textContent).not.toMatch(/Mac|Codex CLI|Claude Code login/);
  expect(card(rendered).querySelector("[data-cloud-via]")).toBeNull();
  expect(row(rendered, "chatgpt").querySelector('[data-cloud-action="connectChatGPT"]')?.textContent).toBe(
    "Sign in with ChatGPT",
  );
});

test("a signed-out ChatGPT plan says Signed out and signs in again in place", async () => {
  const rendered = await render(mockModels.chatgptSignedOut);
  const chatgpt = row(rendered, "chatgpt");
  expect(chatgpt.dataset.cloudStatus).toBe("off");
  expect(chatgpt.querySelector("[data-cloud-status-text]")?.textContent).toBe("Signed out");
  expect(chatgpt.querySelector("[data-cloud-via]")?.textContent).toContain("ChatGPT plan");
  expect(chatgpt.textContent).not.toContain("Models");
  await click(chatgpt.querySelector('[data-cloud-action="connectChatGPT"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPT", id: "chatgpt" }]);
  expect(row(rendered, "chatgpt").querySelector('[data-chatgpt="pending"]')).not.toBeNull();
});

test("a turned-off ChatGPT plan says Turned off and Turn On makes it Connected for Cloud", async () => {
  const rendered = await render(mockModels.chatgptOff);
  const chatgpt = row(rendered, "chatgpt");
  expect(chatgpt.querySelector("[data-cloud-status-text]")?.textContent).toBe("Turned off");
  expect(chatgpt.querySelector('[data-cloud-action="connectChatGPT"]')).toBeNull();
  await click(chatgpt.querySelector('[data-cloud-action="turnOn"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "enable", id: "chatgpt", on: true }]);
  expect(statuses(rendered).chatgpt).toBe("ready");
});

test("a ChatGPT plan both turned off and signed out turns on as it signs in", async () => {
  const both = structuredClone(mockModels.chatgptSignedOut);
  both.personal.connections = both.personal.connections.map((c) =>
    c.kind === "chatgpt-plan" ? { ...c, enabled: false } : c,
  );
  const rendered = await render(both);
  expect(row(rendered, "chatgpt").querySelector("[data-cloud-status-text]")?.textContent).toBe("Signed out");
  expect(row(rendered, "chatgpt").querySelector('[data-cloud-action="turnOn"]')).toBeNull();
  await click(row(rendered, "chatgpt").querySelector('[data-cloud-action="connectChatGPT"]')!);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "enable", id: "chatgpt", on: true },
    { action: "connectChatGPT", id: "chatgpt" },
  ]);
});

test("a Claude Code token is Connected for Cloud; ChatGPT stays not set up", async () => {
  const rendered = await render(mockModels.claudeForCloud);
  expect(statuses(rendered)).toEqual({ claude: "ready", chatgpt: "missing", apiKey: "missing" });
  expect(row(rendered, "claude").querySelector("[data-cloud-status-text]")?.textContent).toBe("Connected for Cloud");
  expect(row(rendered, "claude").querySelector("[data-cloud-via]")?.textContent).toBe("Claude Code token");
  expect(row(rendered, "claude").querySelector("[data-cloud-action]")).toBeNull();
});

test("a ChatGPT plan is Connected for Cloud; Claude stays not set up", async () => {
  const rendered = await render(mockModels.chatgptForCloud);
  expect(statuses(rendered)).toEqual({ claude: "missing", chatgpt: "ready", apiKey: "missing" });
  expect(row(rendered, "chatgpt").querySelector("[data-cloud-status-text]")?.textContent).toBe("Connected for Cloud");
  expect(row(rendered, "chatgpt").querySelector("[data-cloud-via]")?.textContent).toContain("ChatGPT plan");
});

test("readiness follows the Cloud start's rule: off or signed out does not count, the team's key does", () => {
  const off = structuredClone(mockModels.claudeForCloud);
  off.personal.connections = off.personal.connections.map((c) => ({ ...c, enabled: false }));
  expect(cloudReadiness(off, "claude").state).toBe("off");
  const team = structuredClone(mockModels.macOnly);
  team.organization = {
    team: { id: "t", name: "Acme" },
    canEdit: false,
    keys: [{ agent: "claude", set: true, last4: null }],
  };
  expect(cloudReadiness(team, "claude")).toMatchObject({ state: "ready", via: "Shared Claude key" });
  expect(cloudReadiness(team, "chatgpt").state).toBe("missing");
  // An OpenRouter key works on this Mac only; an Anthropic key serves Cloud.
  expect(cloudReadiness(mockModels.macLogins, "apiKey")).toMatchObject({ state: "missing" });
});

test("Set Up on Claude opens Models' Claude steps, which add the pasted token once", async () => {
  const rendered = await render(mockModels.macOnly);
  await click(row(rendered, "claude").querySelector('[data-cloud-action="setUpClaude"]')!);
  const form = sheet()!.querySelector<HTMLFormElement>("[data-models-claude-form]")!;
  await click(form.querySelector('[data-models-action="claudeSetupToken"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "claudeSetupToken" }]);
  await changeValue(form.querySelector<HTMLInputElement>('input[type="password"]')!, "sk-ant-oat01-secret0123456789");
  await click(form.querySelector('[data-models-action="addClaudeToken"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "addClaudeToken",
    token: "sk-ant-oat01-secret0123456789",
  });
  expect(sheet()).toBeNull();
  expect(statuses(rendered).claude).toBe("ready");
  expect(document.body.innerHTML).not.toContain("sk-ant-oat01-secret");
});

test("Sign in with ChatGPT runs the sign-in and waits with Cancel on its row", async () => {
  const rendered = await render(mockModels.macOnly);
  await click(row(rendered, "chatgpt").querySelector('[data-cloud-action="connectChatGPT"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPT" }]);
  expect(row(rendered, "chatgpt").querySelector('[data-chatgpt="pending"]')).not.toBeNull();
});

test("Add an API Key opens the chosen provider's key form", async () => {
  const rendered = await render(mockModels.empty);
  await click(row(rendered, "apiKey").querySelector('[data-menu="cloud-api-key"]')!);
  await click(document.querySelector<HTMLElement>('[role="menuitem"][data-value="openai"]')!);
  expect(sheet()!.querySelector('[data-models-key-form="openai"]')).not.toBeNull();
});

test("a focus opens the page on its row (the chat's Set up Cloud card)", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=cloud.chatgpt");
  expect(document.activeElement).toBe(row(rendered, "chatgpt"));
});

test("Models' This Mac only rows link to Settings > Cloud on the matching row", async () => {
  const rendered = await render(mockModels.macOnly, "/settings/models");
  const link = rendered.container.querySelector<HTMLElement>(
    '[data-connection="claude-login"] [data-models-action="setUpForCloud"]',
  )!;
  expect(link.textContent).toBe("Set Up for Cloud");
  await click(link);
  expect(rendered.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("cloud");
  expect(document.activeElement).toBe(row(rendered, "claude"));
});

test("a This Mac only login offers no Set Up for Cloud once a connection of its kind serves Cloud", async () => {
  const rendered = await render(mockModels.macLogins, "/settings/models");
  const login = rendered.container.querySelector<HTMLElement>('[data-connection="claude-login"]')!;
  expect(login.querySelector("[data-connection-local]")?.textContent).toBe("This Mac only");
  expect(login.querySelector('[data-models-action="setUpForCloud"]')).toBeNull();
});
