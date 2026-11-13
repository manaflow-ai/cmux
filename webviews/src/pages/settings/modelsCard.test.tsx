// Settings > Models (ModelsCard.tsx, cmux-tui/docs/model-connections.md): an empty state, reordering
// sends the whole order, Add a Connection sends a pasted key once and keeps it nowhere after, a member
// reads the organization's policy without switches to change it, and a ChatGPT sign-in waits with Cancel.
import { afterAll, afterEach, expect, test } from "bun:test";
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
  expect(connectionIds(rendered)).toEqual([
    "codex-login",
    "claude-login",
    "chatgpt-plan-1",
    "claude-token-1",
    "key-openrouter",
  ]);
  await click(card(rendered).querySelector('[data-menu="connection-codex-login"]')!);
  const down = document.querySelector<HTMLElement>('[role="menuitem"][data-value="moveDown"]')!;
  await click(down);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "order", ids: ["claude-login", "codex-login", "chatgpt-plan-1", "claude-token-1", "key-openrouter"] },
  ]);
  expect(connectionIds(rendered)).toEqual([
    "claude-login",
    "codex-login",
    "chatgpt-plan-1",
    "claude-token-1",
    "key-openrouter",
  ]);
});

test("a ChatGPT plan row says so and links to its usage page", async () => {
  const rendered = await render(mockModels.macLogins);
  const row = card(rendered).querySelector<HTMLElement>('[data-connection="chatgpt-plan-1"]')!;
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
  expect(connectionIds(rendered)).toEqual(["key-anthropic-1"]);
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
  expect(choices).toEqual(["openrouter"]);
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
  expect(status.textContent).not.toContain("no_plan_scope");
});

test("Mac logins that Cloud threads cannot use say This Mac only", async () => {
  const rendered = await render(mockModels.macLogins);
  const local = [...card(rendered).querySelectorAll<HTMLElement>("[data-connection]")]
    .filter((row) => row.querySelector("[data-connection-local]"))
    .map((row) => row.dataset.connection);
  expect(local).toEqual(["codex-login", "claude-login"]);
  expect(card(rendered).querySelector('[data-connection="codex-login"] [data-connection-local]')?.textContent).toBe(
    "This Mac only",
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
  expect(connectionIds(rendered)).toEqual(["claude-token-1"]);
  expect(document.body.innerHTML).not.toContain("sk-ant-oat01-secret");
  expect(JSON.stringify(rendered.store.getSnapshot().models)).not.toContain("sk-ant-oat01-secret");
});
