// Settings > Cloud > Models for Cloud (CloudModelsCard.tsx, model-connections.md Revision 2): each row
// says whether Cloud chats on it are set up, by the rule a Cloud start uses, and names only connections
// that serve Cloud, so a Mac-only login is neither read as set up nor explained here; each row fixes
// itself in place (Sign in with ChatGPT, Turn On, Set Up opening Models' own steps); a focus opens the
// page on its row; and Models' This Mac only rows link here.
import { afterAll, afterEach, expect, test } from "bun:test";
import { cloudReadiness } from "./components/CloudModelsCard";
import { mockModels } from "./mockModels";
import type { ModelConnection, ModelsState } from "./ops";
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
  expect(row(rendered, "claude").querySelector('[data-cloud-action="connectClaudeToken"]')?.textContent).toBe(
    "Connect Claude",
  );
  expect(row(rendered, "claude").querySelector('[data-cloud-action="setUpClaude"]')?.textContent).toBe(
    "Paste a token instead",
  );
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

test("Connect Claude runs the one click in its row, with its progress line and Cancel", async () => {
  const rendered = await render(mockModels.macOnly);
  await click(row(rendered, "claude").querySelector('[data-cloud-action="connectClaudeToken"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectClaudeToken" }]);
  expect(sheet()).toBeNull();
  expect(row(rendered, "claude").querySelector('[data-claude-token="starting"]')?.textContent).toContain(
    "Opening the Claude sign-in page…",
  );
  expect(row(rendered, "claude").querySelector('[data-cloud-action="connectClaudeToken"]')).toBeNull();
  await click(row(rendered, "claude").querySelector('[data-models-action="cancelClaudeToken"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "cancelClaudeToken" });
});

test("Paste a token instead opens Models' sheet with the paste field out, which adds the token once", async () => {
  const rendered = await render(mockModels.macOnly);
  await click(row(rendered, "claude").querySelector('[data-cloud-action="setUpClaude"]')!);
  const form = sheet()!.querySelector<HTMLElement>("[data-models-claude-form]")!;
  expect(form.querySelector<HTMLDetailsElement>("[data-models-claude-paste]")!.open).toBe(true);
  await changeValue(form.querySelector<HTMLInputElement>('input[type="password"]')!, "sk-ant-oat01-secret0123456789");
  await click(form.querySelector('[data-models-action="addClaudeToken"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "addClaudeToken", token: "sk-ant-oat01-secret0123456789" }]);
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

const menuItem = async (rendered: Rendered, id: string, value: string) => {
  await click(row(rendered, id).querySelector<HTMLElement>('[data-menu^="cloud-connection-"]')!);
  await click(document.querySelector<HTMLElement>(`[role="menuitem"][data-value="${value}"]`)!);
};

test("a connected ChatGPT plan signs in again or signs out from its row", async () => {
  const rendered = await render(mockModels.chatgptForCloud);
  await menuItem(rendered, "chatgpt", "signInAgain");
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPT", id: "chatgpt" }]);
  await menuItem(rendered, "chatgpt", "remove");
  expect(row(rendered, "chatgpt").querySelector("[data-cloud-remove]")?.textContent).toContain("ChatGPT plan");
  await click(row(rendered, "chatgpt").querySelector('[data-cloud-action="confirmRemove"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "remove", id: "chatgpt" });
  expect(statuses(rendered).chatgpt).toBe("missing");
});

test("Replace on a Claude Code token adds the new one, then removes the old", async () => {
  const rendered = await render(mockModels.claudeForCloud);
  const old = row(rendered, "claude").querySelector("[data-cloud-via]")?.textContent;
  await menuItem(rendered, "claude", "replace");
  const form = sheet()!.querySelector<HTMLFormElement>("[data-models-claude-form]")!;
  await changeValue(
    form.querySelector<HTMLInputElement>('input[type="password"]')!,
    "sk-ant-oat01-newsecret0123456789",
  );
  await click(form.querySelector('[data-models-action="addClaudeToken"]')!);
  const runs = rendered.provider.modelRuns;
  expect(runs.map((r) => r.action)).toEqual(["addClaudeToken", "order", "remove"]);
  expect(runs[0]).toEqual({ action: "addClaudeToken", token: "sk-ant-oat01-newsecret0123456789" });
  expect(runs.at(-1)).toEqual({ action: "remove", id: "claude-token" });
  expect(statuses(rendered).claude).toBe("ready");
  expect(old).toBe("Claude Code token");
  expect(rendered.provider.models!.personal.connections.filter((c) => c.kind === "claude-token")).toHaveLength(1);
});

test("Replace keeps the new token in the old one's place, and another kind added from the sheet replaces nothing", async () => {
  const both = structuredClone(mockModels.claudeForCloud);
  const anthropic: ModelConnection = {
    ...both.personal.connections.find((c) => c.kind === "claude-token")!,
    id: "anthropic-key",
    kind: "api-key",
    provider: "anthropic",
    label: "Anthropic",
  };
  both.personal.connections.push(anthropic);
  const rendered = await render(both);
  await menuItem(rendered, "claude", "replace");
  const form = sheet()!.querySelector<HTMLFormElement>("[data-models-claude-form]")!;
  await changeValue(
    form.querySelector<HTMLInputElement>('input[type="password"]')!,
    "sk-ant-oat01-newsecret0123456789",
  );
  await click(form.querySelector('[data-models-action="addClaudeToken"]')!);
  expect(sheet()).toBeNull();
  const ids = rendered.provider.models!.personal.connections.map((c) => c.id);
  expect(ids.indexOf("claude-token-2")).toBeLessThan(ids.indexOf("anthropic-key"));
  expect(ids).not.toContain("claude-token");
  expect(row(rendered, "claude").querySelector("[data-cloud-via]")?.textContent).toBe("Claude Code token");

  // Replace on the Anthropic key, Back, then an OpenAI key: added, and the Anthropic key stays.
  await menuItem(rendered, "apiKey", "replace");
  await click(sheet()!.querySelector('[data-models-action="back"]')!);
  await click(sheet()!.querySelector('[data-models-choice="openai"]')!);
  const keyForm = sheet()!.querySelector<HTMLFormElement>('[data-models-key-form="openai"]')!;
  await changeValue(keyForm.querySelector<HTMLInputElement>('input[type="password"]')!, "sk-openai-0123456789");
  await click(keyForm.querySelector('[data-models-action="addKey"]')!);
  const after = rendered.provider.models!.personal.connections.map((c) => c.id);
  expect(after).toContain("anthropic-key");
  expect(after).toContain("openai-key");
});

test("a row served by the team's key has no menu of its own", async () => {
  const team = structuredClone(mockModels.macOnly);
  team.organization = {
    team: { id: "t", name: "Acme" },
    canEdit: false,
    keys: [{ agent: "claude", set: true, last4: null }],
  };
  const rendered = await render(team);
  expect(row(rendered, "claude").querySelector('[data-menu^="cloud-connection-"]')).toBeNull();
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
