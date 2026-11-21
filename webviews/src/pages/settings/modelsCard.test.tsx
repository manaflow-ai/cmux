// Settings > Models (ModelsCard.tsx, cmux-tui/docs/model-connections.md): an empty state, reordering
// sends the whole order, Add a Connection sends a pasted key once and keeps it nowhere after, a member
// reads the organization's policy without switches to change it, and a ChatGPT sign-in waits with Cancel.
import { afterAll, afterEach, expect, test } from "bun:test";
import { mockModels, runMockModels } from "./mockModels";
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

const render = async (models: ModelsState, path = "/settings/models") => {
  page = await renderPage({
    path,
    setup: (provider) => {
      provider.models = structuredClone(models);
    },
  });
  return page;
};
const card = (rendered: Rendered) => rendered.container.querySelector<HTMLElement>('[data-card="models"]')!;
const action = (scope: ParentNode, id: string) =>
  scope.querySelector<HTMLButtonElement>(`[data-models-action="${id}"]`);
const connectionIds = (rendered: Rendered) =>
  [...card(rendered).querySelectorAll<HTMLElement>("[data-connection]")].map((row) => row.dataset.connection);
const sheet = () => document.querySelector<HTMLElement>("[data-models-sheet]");

test("with nothing connected, the card says so and offers Add a Connection", async () => {
  const rendered = await render(mockModels.empty);
  const personal = card(rendered).querySelector<HTMLElement>('[data-models-section="personal"]')!;
  expect(personal.textContent).toContain("Your connections");
  expect(personal.textContent).toContain("No connections yet");
  expect(connectionIds(rendered)).toEqual([]);
  expect(action(personal, "add")!.disabled).toBe(false);
  expect(card(rendered).querySelector('[data-models-section="organization"]')?.textContent).toContain(
    "Join or create a team",
  );
  expect(card(rendered).querySelector('[data-models-section="members"]')).toBeNull();
});

test("Move Down sends the whole new order, and the rows follow", async () => {
  const rendered = await render(mockModels.macLogins);
  expect(connectionIds(rendered)).toEqual(["codex-login", "claude-login", "chatgpt", "claude-token", "openrouter-key"]);
  await click(card(rendered).querySelector('[data-menu="connection-codex-login"]')!);
  const down = document.querySelector<HTMLElement>('[role="menuitem"][data-value="moveDown"]')!;
  await click(down);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "order", ids: ["claude-login", "codex-login", "chatgpt", "claude-token", "openrouter-key"] },
  ]);
  expect(connectionIds(rendered)).toEqual(["claude-login", "codex-login", "chatgpt", "claude-token", "openrouter-key"]);
});

test("a ChatGPT plan row says so and links to its usage page", async () => {
  const rendered = await render(mockModels.macLogins);
  const row = card(rendered).querySelector<HTMLElement>('[data-connection="chatgpt"]')!;
  expect(row.querySelector("[data-chatgpt-plan]")?.textContent).toContain("Using ChatGPT plan");
  expect(row.querySelector("a")?.getAttribute("href")).toBe("https://chatgpt.com/settings/usage");
  expect(row.textContent).toContain("Authenticated as alex@work.example.com");
});

test("adding an API key sends it once and keeps it nowhere after", async () => {
  const rendered = await render(mockModels.empty);
  await click(action(card(rendered), "add")!);
  expect(sheet()?.textContent).toContain("Subscriptions");
  expect(sheet()?.textContent).toContain("API keys");
  await click(sheet()!.querySelector('[data-models-choice="anthropic"]')!);
  const form = sheet()!.querySelector<HTMLFormElement>('[data-models-key-form="anthropic"]')!;
  const field = form.querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(action(form, "addKey")!.disabled).toBe(true);
  await changeValue(field, "sk-ant-secret-0123456789");
  await changeValue(form.querySelectorAll<HTMLInputElement>("input")[1]!, "Work");
  await click(action(form, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "addKey", provider: "anthropic", key: "sk-ant-secret-0123456789", label: "Work" },
  ]);
  expect(sheet()).toBeNull();
  expect(connectionIds(rendered)).toEqual(["anthropic-key"]);
  expect(document.body.innerHTML).not.toContain("sk-ant-secret");
  expect(JSON.stringify(rendered.store.getSnapshot().models)).not.toContain("sk-ant-secret");
});

test("the search narrows the sheet's ways in", async () => {
  const rendered = await render(mockModels.empty);
  await click(action(card(rendered), "add")!);
  await changeValue(sheet()!.querySelector<HTMLInputElement>('input[type="search"]')!, "router");
  const choices = [...sheet()!.querySelectorAll<HTMLElement>("[data-models-choice]")].map(
    (c) => c.dataset.modelsChoice,
  );
  expect(choices).toEqual(["openrouter", "ramp"]);
});

test("every provider of acpmux's catalog is a way in, and each asks for what its key needs", async () => {
  const rendered = await render(mockModels.empty);
  await click(action(card(rendered), "add")!);
  const groups = (id: string) =>
    [...sheet()!.querySelectorAll<HTMLElement>(`[data-models-group="${id}"] [data-models-choice]`)].map(
      (choice) => choice.dataset.modelsChoice,
    );
  expect(groups("subscriptions")).toEqual([
    "chatgpt",
    "claude",
    "supergrok",
    "github-copilot",
    "opencode-go",
    "glm",
    "ollama-cloud",
    "kimi-code",
    "morph",
  ]);
  expect(groups("keys")).toContain("bedrock");
  expect(groups("keys")).toHaveLength(14);
  expect(groups("custom")).toEqual(["cloudflare", "neon", "custom"]);

  // A sign-in-only subscription says why it takes no key.
  await click(sheet()!.querySelector('[data-models-choice="github-copilot"]')!);
  expect(sheet()!.querySelector('[data-models-way="unavailable"]')?.textContent).toContain("GitHub Copilot");
  expect(sheet()!.querySelector('input[type="password"]')).toBeNull();
  await click(sheet()!.querySelector('[data-models-action="back"]')!);

  // A named endpoint takes its base URL and protocol; the key is checked before it is kept.
  await click(sheet()!.querySelector('[data-models-choice="custom"]')!);
  const form = sheet()!.querySelector<HTMLFormElement>('[data-models-key-form="custom"]')!;
  expect(form.querySelector('[data-models-field="base-url"]')).not.toBeNull();
  await changeValue(form.querySelector<HTMLInputElement>('input[type="password"]')!, "sk-gw-0123456789");
  expect(action(form, "addKey")!.disabled).toBe(true);
  await changeValue(
    form.querySelector<HTMLInputElement>('[data-models-field="base-url"]')!,
    "https://gw.example.com/v1",
  );
  await click(action(form, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([
    {
      action: "addKey",
      provider: "custom",
      key: "sk-gw-0123456789",
      baseUrl: "https://gw.example.com/v1",
      protocol: "anthropic",
    },
  ]);
  expect(connectionIds(rendered)).toEqual(["custom-key"]);
  expect(document.body.innerHTML).not.toContain("sk-gw-0123456789");
});

test("a key the provider refuses says so, and the form asks for it again", async () => {
  const rendered = await render(mockModels.empty);
  await click(action(card(rendered), "add")!);
  await click(sheet()!.querySelector('[data-models-choice="openrouter"]')!);
  const form = sheet()!.querySelector<HTMLFormElement>('[data-models-key-form="openrouter"]')!;
  await changeValue(form.querySelector<HTMLInputElement>('input[type="password"]')!, "sk-or-rejected-0123");
  await click(action(form, "addKey")!);
  // Said in the sheet, over the form the person is in.
  expect(sheet()!.querySelector("[data-models-sheet-error]")?.textContent).toBe(
    "The provider refused this key. Check it and paste it again.",
  );
  expect(form.querySelector<HTMLInputElement>('input[type="password"]')!.value).toBe("");
  expect(connectionIds(rendered)).toEqual([]);
});

test("Amazon Bedrock takes its AWS Region with the key", async () => {
  const rendered = await render(mockModels.empty);
  await click(action(card(rendered), "add")!);
  await click(sheet()!.querySelector('[data-models-choice="bedrock"]')!);
  const form = sheet()!.querySelector<HTMLFormElement>('[data-models-key-form="bedrock"]')!;
  expect(form.textContent).toContain("cmux checks the key with Amazon Bedrock before it keeps it.");
  await changeValue(form.querySelector<HTMLInputElement>('input[type="password"]')!, "ABSKbedrock0123456789");
  expect(action(form, "addKey")!.disabled).toBe(true);
  await changeValue(form.querySelector<HTMLInputElement>('[data-models-field="region"]')!, "us-west-2");
  await click(action(form, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "addKey", provider: "bedrock", key: "ABSKbedrock0123456789", region: "us-west-2" },
  ]);
});

test("cmux://settings/models/add opens on Add a Connection", async () => {
  await render(mockModels.empty, "/settings/models?focus=models.add");
  expect(sheet()).not.toBeNull();
});

test("a member reads the policy and the organization's keys with nothing to change", async () => {
  const rendered = await render(mockModels.member);
  const members = card(rendered).querySelector<HTMLElement>('[data-models-section="members"]')!;
  const switches = [...members.querySelectorAll<HTMLButtonElement>('[role="switch"]')];
  expect(switches.length).toBe(2);
  expect(switches.every((control) => control.disabled || control.getAttribute("aria-disabled") === "true")).toBe(true);
  expect(members.textContent).toContain("Owners and admins change these.");
  const organization = card(rendered).querySelector<HTMLElement>('[data-models-section="organization"]')!;
  expect(action(organization, "orgAdd")).toBeNull();
  expect(action(organization, "orgRemove")).toBeNull();
  expect(organization.querySelector('[data-models-row="gateway"]')).toBeNull();
  expect(organization.querySelector('[data-org-key="claude"]')?.textContent).toContain("Shared Claude key");
});

test("an owner's members switch sends the policy change", async () => {
  const rendered = await render(mockModels.macLogins);
  const row = card(rendered).querySelector<HTMLElement>('[data-models-row="chooseRunout"]')!;
  await click(row.querySelector('[role="switch"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "members", chooseRunout: true }]);
});

test("Continue with ChatGPT waits on the browser with Cancel, and Cancel stops it", async () => {
  const rendered = await render(mockModels.macLogins);
  await click(action(card(rendered), "add")!);
  await click(sheet()!.querySelector('[data-models-choice="chatgpt"]')!);
  await click(action(sheet()!, "connectChatGPT")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPT" }]);
  expect(sheet()!.querySelector('[data-chatgpt="pending"]')?.textContent).toContain("Waiting for you to finish");
  await click(action(sheet()!, "cancelChatGPT")!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "cancelChatGPT" });
  expect(rendered.store.getSnapshot().models?.chatgpt.attempt).toBeNull();
});

test("a failed ChatGPT sign-in says why in plain words", async () => {
  const rendered = await render(mockModels.chatgptError);
  const status = card(rendered).querySelector<HTMLElement>('[data-chatgpt="error"]')!;
  expect(status.textContent).toContain("didn't allow use of its plan");
  expect(status.textContent).not.toContain("no_chatgpt_account");
});

test("Mac logins that Cloud threads cannot use say This Mac only, with Set Up for Cloud", async () => {
  const rendered = await render(mockModels.macOnly);
  const local = [...card(rendered).querySelectorAll<HTMLElement>("[data-connection]")]
    .filter((row) => row.querySelector("[data-connection-local]"))
    .map((row) => row.dataset.connection);
  expect(local).toEqual(["codex-login", "claude-login"]);
  expect(card(rendered).querySelector('[data-connection="codex-login"] [data-connection-local]')?.textContent).toBe(
    "This Mac only · Set Up for Cloud",
  );
});

test("Claude Code opens a terminal for setup-token, then adds the pasted token once", async () => {
  const rendered = await render(mockModels.empty);
  await click(action(card(rendered), "add")!);
  await click(sheet()!.querySelector('[data-models-choice="claude"]')!);
  const form = sheet()!.querySelector<HTMLFormElement>("[data-models-claude-form]")!;
  await click(action(form, "claudeSetupToken")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "claudeSetupToken" }]);
  const field = form.querySelector<HTMLInputElement>('input[type="password"]')!;
  await changeValue(field, "sk-ant-api03 with spaces");
  expect(form.querySelector("[data-claude-token-invalid]")).not.toBeNull();
  expect(action(form, "addClaudeToken")!.disabled).toBe(true);
  await changeValue(field, "sk-ant-oat01-secret0123456789");
  expect(form.querySelector("[data-claude-token-invalid]")).toBeNull();
  await click(action(form, "addClaudeToken")!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "addClaudeToken",
    token: "sk-ant-oat01-secret0123456789",
  });
  expect(sheet()).toBeNull();
  expect(connectionIds(rendered)).toEqual(["claude-token"]);
  expect(document.body.innerHTML).not.toContain("sk-ant-oat01-secret");
  expect(JSON.stringify(rendered.store.getSnapshot().models)).not.toContain("sk-ant-oat01-secret");
});

test("the mock refuses what acpmux refuses and names new routes as acpmux does", () => {
  const state = structuredClone(mockModels.macLogins);
  expect(() => runMockModels(state, { action: "remove", id: "codex-login" })).toThrow("the CLI's own login");
  expect(() => runMockModels(state, { action: "remove", id: "claude-login" })).toThrow("the CLI's own login");
  expect(() => runMockModels(state, { action: "enable", id: "nope", on: true })).toThrow("unknown connection");
  const keyed = runMockModels(state, { action: "addKey", provider: "openrouter", key: "sk-or-1" });
  expect(keyed.personal.connections.at(-1)).toMatchObject({
    id: "openrouter-key-2",
    families: ["claude", "codex", "opencode"],
    servesCloud: true,
  });
  const tokened = runMockModels(state, { action: "addClaudeToken", token: "sk-ant-oat01-x" });
  expect(tokened.personal.connections.at(-1)).toMatchObject({ id: "claude-token-2", label: "Claude Code token" });
  const anthropic = runMockModels(mockModels.empty, { action: "addKey", provider: "anthropic", key: "k" });
  expect(anthropic.personal.connections[0]).toMatchObject({
    id: "anthropic-key",
    label: "Anthropic API key",
    servesCloud: true,
  });
});

test("the Models state is read again only while this Mac's connections can't be listed", async () => {
  const { modelsRetryMs } = await import("./store");
  const state = (available: boolean) => ({ personal: { available } }) as never;
  expect(modelsRetryMs(undefined)).toBe(false);
  expect(modelsRetryMs(state(true))).toBe(false);
  expect(modelsRetryMs(state(false))).toBe(2000);
});
