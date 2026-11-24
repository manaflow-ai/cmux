// User-visible behavior of Settings > Models and its connection dialogs.
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { chatgptDeviceError, mockChatGPTDevice, mockModels, runMockModels } from "./mockModels";
import type { ModelsState } from "./ops";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, changeValue, click, settle } = await import("./testing");

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
const card = (rendered: Rendered) =>
  rendered.container.querySelector<HTMLElement>('[data-card="models"], [data-card="cloudModels"]')!;
const action = (scope: ParentNode, id: string) =>
  scope.querySelector<HTMLButtonElement>(`[data-models-action="${id}"]`);
const connectionIds = (rendered: Rendered) =>
  [...card(rendered).querySelectorAll<HTMLElement>("[data-connection]")].map((row) => row.dataset.connection);
const row = (rendered: Rendered, id: string) => card(rendered).querySelector<HTMLElement>(`[data-connection="${id}"]`)!;
const detail = (rendered: Rendered, id: string) => row(rendered, id).querySelector(".models-row-detail");
const status = (rendered: Rendered, id: string) => row(rendered, id).querySelector(".models-row-status");
const menuButton = (rendered: Rendered, id: string) =>
  row(rendered, id).querySelector<HTMLButtonElement>("[data-menu]")!;
const menuItem = (id: string) => document.querySelector<HTMLElement>(`[role="menuitem"][data-value="${id}"]`)!;
const chooseAction = async (rendered: Rendered, connection: string, action: string) => {
  await click(menuButton(rendered, connection));
  await click(menuItem(action));
};
const panel = () => document.querySelector<HTMLElement>("[data-models-dialog]");
const catalog = () => document.querySelector<HTMLElement>("[data-models-catalog]")!;
const add = () => document.querySelector<HTMLButtonElement>("[data-models-add]")!;
const choice = (id: string) => catalog().querySelector<HTMLElement>(`[data-models-choice="${id}"]`)!;
const pick = async (id: string) => {
  await click(add());
  await click(choice(id));
};
const inputFor = (scope: ParentNode, label: string) =>
  [...scope.querySelectorAll("label")].find((field) => field.textContent === label)!.querySelector("input")!;
const changeRegion = (select: HTMLSelectElement, value: string) =>
  act(async () => {
    select.value = value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
const press = (node: Element, key: string) =>
  act(async () => node.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key })));

test("Connect is the last row and opens a focused picker", async () => {
  const rendered = await render(mockModels.empty);
  const personal = card(rendered).querySelector<HTMLElement>('[data-models-section="personal"]')!;
  expect(personal.textContent).toContain("Your connections");
  expect(personal.querySelector(".models-rows")?.lastElementChild).toBe(add());
  expect(add().textContent).toBe("Connect");
  expect(add().dataset.variant).toBe("ghost");
  expect(add().getAttribute("aria-expanded")).toBe("false");
  expect(document.querySelector("[data-models-catalog]")).toBeNull();
  await click(add());
  expect(add().getAttribute("aria-expanded")).toBe("true");
  expect(document.activeElement?.getAttribute("aria-label")).toBe("Search providers");
  expect(choice("claude-login")).toBeNull();
  expect(choice("ollama")).toBeNull();
  expect(choice("claude")).not.toBeNull();
  expect(choice("chatgpt")).not.toBeNull();
  expect(choice("codex-login")).toBeNull();
  expect(choice("gemini-login")).toBeNull();
  expect(choice("google")).not.toBeNull();
  expect(choice("lm-studio")).toBeNull();
  expect(choice("endpoint").textContent).toContain("Add custom provider");
});

test("Claude stays listed and cannot be picked when Claude Code is missing", async () => {
  const rendered = await render({ ...mockModels.empty, claudeCodeAvailable: false });
  await click(add());
  const claude = choice("claude");
  expect(claude.getAttribute("aria-disabled")).toBe("true");
  expect(claude.textContent).toContain("Disabled");
  expect(claude.textContent).toContain("Needs Claude Code on this Mac");
  await click(claude);
  await press(claude, "Enter");
  const search = document.querySelector<HTMLInputElement>('[role="combobox"][aria-label="Search providers"]')!;
  await changeValue(search, "claude");
  // The Anthropic key also matches and may take the highlight; the missing Claude Code row never does.
  expect(search.getAttribute("aria-activedescendant") ?? "").not.toMatch(/-claude$/);
  await press(search, "Enter");
  expect(panel()?.dataset.modelsDialog).not.toBe("claude");
  expect(rendered.provider.modelRuns).toEqual([]);
});

test("a direct link to Claude shows its disabled row instead of starting a connection", async () => {
  await render(
    { ...mockModels.empty, claudeCodeAvailable: false },
    "/settings/models?focus=models.add.claude&open=picker",
  );
  expect(choice("claude").getAttribute("aria-disabled")).toBe("true");
  expect(panel()).toBeNull();
});

test("Move Down sends the whole new order, and the rows follow", async () => {
  const rendered = await render(mockModels.macLogins);
  expect(connectionIds(rendered)).toEqual(["codex-login", "claude-login", "chatgpt", "openrouter-key"]);
  expect(row(rendered, "openrouter-key").nextElementSibling).toBe(add());
  expect(add().textContent).toBe("Connect");
  await click(card(rendered).querySelector('[data-menu="connection-codex-login"]')!);
  const down = document.querySelector<HTMLElement>('[role="menuitem"][data-value="moveDown"]')!;
  await click(down);
  expect(rendered.provider.modelRuns).toEqual([
    {
      action: "order",
      ids: ["claude-login", "codex-login", "chatgpt", "claude-token", "openrouter-key"],
    },
  ]);
  expect(connectionIds(rendered)).toEqual(["claude-login", "codex-login", "chatgpt", "openrouter-key"]);
});

test("subscription rows keep their type and account details without Cloud controls", async () => {
  const rendered = await render(mockModels.macLogins);
  for (const connection of card(rendered).querySelectorAll("[data-connection]")) {
    expect(connection.querySelectorAll("button")).toHaveLength(1);
    expect(connection.querySelector(".row-main")?.firstElementChild?.classList.contains("models-provider-mark")).toBe(
      true,
    );
    expect(connection.querySelectorAll(".models-row-detail")).toHaveLength(1);
    if (connection.getAttribute("data-connection") === "codex-login") {
      expect(connection.textContent).toContain("alex@example.com");
    } else if (connection.getAttribute("data-connection") !== "claude-login") {
      expect(connection.textContent).not.toContain("@example.com");
    }
    expect(connection.querySelector('[draggable="true"]')).toBeNull();
  }
  expect(detail(rendered, "codex-login")?.textContent).toBe("Subscription");
  expect(detail(rendered, "claude-login")?.textContent).toBe("Subscription");
  expect(detail(rendered, "openrouter-key")?.textContent).toBe("API key");
  expect(status(rendered, "openrouter-key")?.textContent).toBe("Turned off");
  await click(menuButton(rendered, "codex-login"));
  expect(document.querySelector(".models-menu-details")?.textContent).toContain("alex@example.com");
  const items = [...document.querySelectorAll('[role="menuitem"]')];
  expect(items.map((item) => item.textContent)).toEqual([
    "Reauthenticate",
    "Rename",
    "Move up",
    "Move down",
    "Disconnect",
  ]);
  expect(card(rendered).textContent).not.toMatch(/Cloud|This Mac/i);
  expect(items.every((item) => item.querySelector("svg"))).toBe(true);
});

test("Connect requests browser approval, displays the device code and closes on success", async () => {
  const rendered = await render(mockModels.macOnly, "/settings/cloud?provider=codex&open=1");
  expect(panel()?.dataset.modelsDialog).toBe("chatgpt");
  expect(rendered.provider.modelRuns).toEqual([]);
  await press(panel()!.querySelector(".models-dialog-heading")!, "Enter");
  await settle();
  const waiting = panel()!.querySelector('[data-chatgpt-device="waiting"]')!;
  expect(waiting.querySelector("code")?.textContent).toBe("MOCK-1234");
  expect(waiting.querySelector("[data-chatgpt-device-remaining]")?.textContent).toMatch(/^\d{1,2}:\d{2}$/);
  expect(waiting.textContent).toContain("Waiting for sign-in to complete");
  expect(waiting.querySelector("a")?.getAttribute("href")).toBe("https://auth.openai.com/codex/device");
  expect(action(waiting, "connectChatGPTDevice")?.disabled).toBe(true);
  const copy = [...waiting.querySelectorAll("button")].find((button) => button.textContent === "Copy")!;
  await click(copy);
  expect(rendered.provider.clipboard === "MOCK-1234").toBe(true);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", openBrowser: true }]);

  jest.useFakeTimers();
  try {
    const { personal } = mockModels.chatgptForCloud;
    const original = personal.connections.find((c) => c.kind === "chatgpt-plan")!;
    const connection = { ...original, id: "chatgpt-2", email: "other@example.com" };
    await act(async () =>
      rendered.provider.setModels({
        ...mockModels.chatgptForCloud,
        personal: { ...personal, connections: [...personal.connections, connection] },
        chatgptDevice: { phase: "connected", id: connection.id },
      }),
    );
    expect(panel()?.textContent).toContain("Signed in as other@example.com");
    expect(detail(rendered, "chatgpt-2")?.textContent).toBe("Subscription");
    await act(async () => jest.advanceTimersByTime(1500));
    expect(panel()).toBeNull();
  } finally {
    jest.useRealTimers();
  }
});

test("reconnecting a standalone ChatGPT row uses that account", async () => {
  const { personal } = mockModels.chatgptForCloud;
  const first = personal.connections.find((connection) => connection.kind === "chatgpt-plan")!;
  const second = { ...first, id: "chatgpt-2", email: "other@example.com" };
  const rendered = await render(
    {
      ...mockModels.chatgptForCloud,
      personal: { ...personal, connections: [first, second] },
      chatgptDevice: { phase: "connected", id: first.id },
    },
    "/settings/cloud",
  );
  await click(card(rendered).querySelector('[data-menu="connection-chatgpt-2"]')!);
  await click(document.querySelector('[role="menuitem"][data-value="signInAgain"]')!);
  expect(panel()?.textContent).toContain("Signed in as other@example.com");
  await click(action(panel()!, "connectChatGPTDevice")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", id: second.id, openBrowser: true }]);
});

test("a sign-in from another build offers to reconnect the same row", async () => {
  const { personal } = mockModels.chatgptForCloud;
  const plan = personal.connections.find((connection) => connection.kind === "chatgpt-plan")!;
  const rendered = await render({
    ...mockModels.chatgptForCloud,
    personal: {
      ...personal,
      connections: [{ ...plan, signedIn: false, signInReason: "keychain_other_build" }],
    },
  });
  expect(status(rendered, plan.id)?.textContent).toBe(
    "This sign-in was saved by another cmux build. Sign in again to use it here.",
  );
  await click(menuButton(rendered, plan.id));
  expect(menuItem("signInAgain").textContent).toBe("Sign in again");
  await click(menuItem("signInAgain"));
  await click(action(panel()!, "connectChatGPTDevice")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", id: plan.id, openBrowser: true }]);
});

test("API key validation, reveal, and successful submission use the existing key op", async () => {
  const rendered = await render(mockModels.empty);
  await pick("anthropic");
  const dialog = panel()!.closest('[role="dialog"]')!;
  const form = dialog.querySelector<HTMLFormElement>('[data-models-key-form="anthropic"]')!;
  const field = form.querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(dialog.querySelector("h2")?.textContent).toBe("Connect Anthropic API");
  // The dialog is the key field alone: no "get your key" line under it.
  expect(dialog.querySelector("a")).toBeNull();
  expect(field.placeholder).toBe("e.g. sk-ant-…");
  expect(action(form, "addKey")!.disabled).toBe(true);
  await changeValue(field, "has spaces");
  expect(action(form, "addKey")!.disabled).toBe(true);
  await changeValue(field, "sk-ant-secret-0123456789");
  await click(form.querySelector('button[aria-label="Show secret"]')!);
  expect(field.type).toBe("text");
  await click(action(form, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([
    {
      action: "addKey",
      provider: "anthropic",
      key: "sk-ant-secret-0123456789",
      verifyAccess: true,
    },
  ]);
  expect(panel()).toBeNull();
  expect(connectionIds(rendered)).toEqual(["anthropic-key"]);
  expect(document.body.innerHTML).not.toContain("sk-ant-secret");
  expect(JSON.stringify(rendered.store.getSnapshot().models)).not.toContain("sk-ant-secret");
});

test("the picker groups subscriptions and all key providers, and filters by name or host", async () => {
  await render(mockModels.empty);
  await click(add());
  expect(
    [...catalog().querySelectorAll("[data-models-group]")].map((group) => group.getAttribute("aria-label")),
  ).toEqual(["Plans", "API keys"]);
  expect(choice("openrouter").closest("[data-models-group]")?.getAttribute("aria-label")).toBe("API keys");
  expect(choice("opencode-go").closest("[data-models-group]")?.getAttribute("aria-label")).toBe("Plans");
  expect(choice("chatgpt").closest("[data-models-group]")?.getAttribute("aria-label")).toBe("Plans");
  // API keys and gateways are one grid, every key shown, the common ones first.
  const keys = [...catalog().querySelectorAll('[data-models-group="keys"] [data-models-choice]')].map((row) =>
    row.getAttribute("data-models-choice"),
  );
  expect(keys.slice(0, 6)).toEqual(["anthropic", "openai", "google", "xai", "openrouter", "deepseek"]);
  expect(keys).toContain("bedrock");
  expect(choice("bedrock").closest("[data-models-group]")?.getAttribute("aria-label")).toBe("API keys");
  const search = document.activeElement as HTMLInputElement;
  await changeValue(search, "openrouter.ai");
  expect([...catalog().querySelectorAll("[data-models-choice]")]).toEqual([choice("openrouter"), choice("endpoint")]);
  await changeValue(search, "invalid query");
  expect(catalog().textContent).toContain("No providers match");
});

test("a search lists its matches as rows, and a lab's name finds its products", async () => {
  await render(mockModels.empty);
  await click(add());
  const search = document.activeElement as HTMLInputElement;
  expect(catalog().querySelector(".models-picker-columns")).not.toBeNull();
  await changeValue(search, "openai");
  // One list of full-width rows: no columns, no key grid.
  expect(catalog().querySelector(".models-picker-columns")).toBeNull();
  expect(catalog().querySelector(".models-picker-grid")).toBeNull();
  expect(choice("chatgpt").closest("[data-models-group]")?.getAttribute("aria-label")).toBe("Plans");
  expect(choice("openai").closest("[data-models-group]")?.getAttribute("aria-label")).toBe("API keys");
  await changeValue(search, "claude");
  expect(choice("anthropic")).not.toBeNull();
  await changeValue(search, "");
  expect(catalog().querySelector(".models-picker-columns")).not.toBeNull();
});

test("Cloudflare requires a vendor model ID and fills its URL from the account ID", async () => {
  const rendered = await render(mockModels.empty);
  await pick("cloudflare");
  const form = panel()!;
  const gateway = inputFor(form, "Gateway ID");
  const account = [...form.querySelectorAll("label")].find((label) => label.textContent === "Account ID")!;
  const model = form.querySelector<HTMLInputElement>('input[placeholder="vendor/model"]')!;
  expect(model.value).toBe("");
  expect(form.querySelector("[data-models-check]")).toBeNull();
  expect(gateway.value).toBe("default");
  const id = "1234567890abcdef1234567890abcdef";
  await changeValue(account.querySelector("input")!, id);
  await changeValue(gateway, "work-models");
  const connect = action(form, "addEndpoint")!;
  await changeValue(form.querySelector('input[type="password"]')!, "cloudflare-fixture");
  expect(connect.disabled).toBe(true);
  await changeValue(model, "@cf/vendor/model");
  expect(connect.disabled).toBe(true);
  await changeValue(model, "openai/gpt-4.1");
  expect(connect.disabled).toBe(false);
  await click(connect);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    preset: "cloudflare",
    baseUrl: `https://gateway.ai.cloudflare.com/v1/${id}/work-models/compat`,
    model: "openai/gpt-4.1",
  });
});

test("a DeepSeek key uses the existing endpoint save with the catalog URL and discovered models", async () => {
  const rendered = await render(mockModels.empty);
  await pick("deepseek");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  expect(panel()?.querySelector("a")).toBeNull();
  expect(form.querySelector('input[type="url"]')).toBeNull();
  await changeValue(form.querySelector('input[type="password"]')!, "sk-deepseek-fixture");
  await click(action(form, "addEndpoint")!);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    name: "DeepSeek",
    kind: "openai-endpoint",
    baseUrl: "https://api.deepseek.com",
    apiKey: "sk-deepseek-fixture",
    model: "*",
  });
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).not.toHaveProperty(
    "servesCloud",
  );
  expect(panel()).toBeNull();
});

test("Connect shows disabled subscriptions and excludes unsupported providers", async () => {
  await render(mockModels.empty);
  await click(add());
  expect(catalog().querySelectorAll('[aria-disabled="true"]')).toHaveLength(2);
  expect(choice("grok")?.getAttribute("aria-disabled")).toBe("true");
  expect(choice("copilot")?.getAttribute("aria-disabled")).toBe("true");
  expect(catalog().textContent).not.toContain("Soon");
  for (const id of ["cursor", "perplexity", "vertex"]) expect(Boolean(choice(id))).toBe(false);
  for (const id of ["bedrock", "azure", "meta", "xai", "grok", "copilot", "morph"])
    expect(Boolean(choice(id))).toBe(true);
});

test("detected Gemini, Grok Build and Cursor sign-ins remain visible after reordering", async () => {
  const detected = [
    ["grok", "Grok Build"],
    ["cursor", "Cursor"],
    ["gemini", "Gemini CLI"],
  ].map(([provider, label]) => ({
    id: provider === "gemini" ? "gemini-login" : provider + "-native-login",
    kind: "native-login" as const,
    provider,
    families: [provider],
    label,
    email: null,
    plan: null,
    signedIn: true,
    enabled: true,
    defaultFor: [],
    servesCloud: false,
  }));
  const rendered = await render({
    ...mockModels.macOnly,
    personal: {
      ...mockModels.macOnly.personal,
      connections: [...mockModels.macOnly.personal.connections, ...detected],
    },
  });
  for (const { id, label } of detected) {
    expect(row(rendered, id).textContent).toContain(label);
    expect(detail(rendered, id)?.textContent).toBe("Subscription");
    expect(row(rendered, id).querySelector("[data-menu]")).toBeNull();
  }
  await chooseAction(rendered, "codex-login", "moveDown");
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "order",
    ids: ["claude-login", "codex-login"],
  });
  expect(connectionIds(rendered)).toEqual([
    "claude-login",
    "codex-login",
    "grok-native-login",
    "cursor-native-login",
    "gemini-login",
  ]);
});

test.each([
  ["https://team.openai.azure.com/", "https://team.openai.azure.com/openai/v1"],
  ["https://team.cognitiveservices.azure.com", "https://team.cognitiveservices.azure.com/openai/v1"],
  ["https://team.services.ai.azure.com/openai/v1", "https://team.services.ai.azure.com/openai/v1"],
])("Azure saves %s and the deployment name typed in the form", async (input, baseUrl) => {
  const rendered = await render(mockModels.empty);
  await pick("azure");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  const url = form.querySelector<HTMLInputElement>('input[type="url"]')!;
  expect(url.placeholder).toBe("https://<resource>.openai.azure.com/openai/v1");
  await changeValue(url, input);
  await changeValue(form.querySelector('input[type="password"]')!, "azure-test-key");
  const connect = action(form, "addEndpoint")!;
  expect(connect.disabled).toBe(true);
  expect(form.textContent).toContain("Deployment name");
  await changeValue(form.querySelector('input[type="text"]')!, "my-team-deployment");
  await click(connect);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    kind: "openai-endpoint",
    name: "Azure OpenAI (team)",
    baseUrl,
    apiKey: "azure-test-key",
    model: "my-team-deployment",
  });
});

test("editing Azure keeps the deployment field and requires a new key for a different URL", async () => {
  const rendered = (page = await renderPage({
    path: "/settings/models",
    setup: (provider) => {
      provider.agents.addEndpoint({
        kind: "openai-endpoint",
        id: "my-azure",
        name: "My Azure",
        baseUrl: "https://old.openai.azure.com/openai/v1",
        model: "old-deployment",
        apiKey: "old-key",
      });
      provider.models = structuredClone(mockModels.empty);
      provider.models.personal.connections.push(provider.agents.modelEndpoint("my-azure")!);
    },
  }));
  await chooseAction(rendered, "my-azure", "edit");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  expect(!!form.querySelector("[data-models-check]")).toBe(false);
  expect(form.textContent).toContain("Deployment name");
  expect(form.textContent).toContain("Leave empty to keep the current key.");
  const url = form.querySelector<HTMLInputElement>('input[type="url"]')!;
  const deployment = form.querySelector<HTMLInputElement>(".models-manual-model input")!;
  const save = action(form, "addEndpoint")!;
  await changeValue(url, "https://new.openai.azure.com/openai/deployments/demo/embeddings");
  expect(form.querySelector('[role="alert"]')?.textContent).toContain("/openai/v1");
  await changeValue(url, "https://new.openai.azure.com/openai/v1/chat/completions");
  expect(form.querySelector('[role="alert"]')?.textContent).toContain("/openai/v1");
  await changeValue(url, "https://new.openai.azure.com/openai/v1?api-version=1");
  expect(form.querySelector('[role="alert"]')?.textContent).toContain("query string");
  await changeValue(url, "https://proxy.example.com/openai/v1");
  await changeValue(deployment, "bad deployment");
  expect(deployment.getAttribute("aria-invalid")).toBe("true");
  expect(form.querySelector('[role="alert"]')?.textContent).toContain("spaces");
  await changeValue(deployment, "new-deployment");
  expect(save.disabled).toBe(true);
  expect(rendered.provider.agents.keys.get("my-azure")).toBe("old-key");
  await changeValue(form.querySelector('input[type="password"]')!, "new-key");
  expect(save.disabled).toBe(false);
  await click(save);
  expect(rendered.provider.log.filter(({ op }) => op === "cmux.chief.backend.add").at(-1)?.params).toMatchObject({
    id: "my-azure",
    preset: "azure",
    name: "My Azure",
    apiKey: "new-key",
    baseUrl: "https://proxy.example.com/openai/v1",
    model: "new-deployment",
  });
  await chooseAction(rendered, "my-azure", "edit");
  expect(panel()?.textContent).toContain("Deployment name");
  expect(panel()?.querySelector("[data-models-check]")).toBeNull();
});

test("Bedrock connects in the selected region with every model it lists", async () => {
  const rendered = await render(mockModels.empty);
  await pick("bedrock");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  const region = form.querySelector("select")!;
  expect(region.value).toBe("us-east-1");
  const baseUrl = "https://bedrock-mantle.us-west-2.api.aws/v1";
  await changeRegion(region, "us-west-2");
  await changeValue(form.querySelector('input[type="password"]')!, "bedrock-test-key");
  await click(action(form, "addEndpoint")!);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    kind: "openai-endpoint",
    name: "Amazon Bedrock (us-west-2)",
    baseUrl,
    apiKey: "bedrock-test-key",
    model: "*",
  });
});

test("Meta requires a key and saves the Model API preset", async () => {
  const rendered = await render(mockModels.empty);
  await pick("meta");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  expect(panel()?.querySelector("a")).toBeNull();
  const connect = action(form, "addEndpoint")!;
  expect(connect.disabled).toBe(true);
  await changeValue(form.querySelector('input[type="password"]')!, "meta-test-key");
  await click(connect);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    kind: "openai-endpoint",
    preset: "meta",
    baseUrl: "https://api.meta.ai/v1",
    apiKey: "meta-test-key",
    model: "*",
  });
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).not.toHaveProperty(
    "servesCloud",
  );
  await chooseAction(rendered, "meta-model-api", "edit");
  const edit = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  expect(edit.querySelector("[data-models-check]")).toBeNull();
  await changeValue(edit.querySelector('input[type="url"]')!, "https://meta-proxy.example.com/v1/completions");
  expect(action(edit, "addEndpoint")!.disabled).toBe(true);
  await changeValue(edit.querySelector('input[type="password"]')!, "meta-new-key");
  await click(action(edit, "addEndpoint")!);
  expect(rendered.provider.log.filter(({ op }) => op === "cmux.chief.backend.add").at(-1)?.params).toMatchObject({
    id: "meta-model-api",
    preset: "meta",
    apiKey: "meta-new-key",
    baseUrl: "https://meta-proxy.example.com/v1",
  });
});

test.each([
  ["ollama", "Ollama", "http://localhost:11434/v1"],
  ["lm-studio", "LM Studio", "http://localhost:1234/v1"],
])("the legacy %s link opens the custom provider dialog with the local preset", async (id, name, base) => {
  await render(mockModels.empty, `/settings/models?provider=${id}`);
  expect(document.querySelector("[data-models-catalog]")).toBeNull();
  expect(panel()?.querySelector("h2")?.textContent).toBe(`Connect ${name}`);
  expect(panel()?.querySelector('input[type="text"]')).toHaveProperty("value", name);
  expect(panel()?.querySelector('input[type="url"]')).toHaveProperty("value", base);
});

test("cmux://settings/models/add opens Connect", async () => {
  await render(mockModels.empty, "/settings/models?focus=models.add");
  await settle();
  expect(document.activeElement?.matches(".models-search input")).toBe(true);
  expect(panel()).toBeNull();
});

test("Cloud picker routes open the existing connection forms, including a repeated choice", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?focus=models.add.anthropic.first");
  expect(panel()?.querySelector('[data-models-key-form="anthropic"]')).not.toBeNull();
  await press(panel()!.querySelector("h2")!, "Escape");
  expect(panel()).toBeNull();
  await act(async () => rendered.history.push("/settings/models?focus=models.add.anthropic.second"));
  expect(panel()?.querySelector('[data-models-key-form="anthropic"]')).not.toBeNull();
  await act(async () => rendered.history.push("/settings/models?focus=models.add.claude.third"));
  expect(panel()?.querySelector("[data-models-claude-form]")).not.toBeNull();
  await act(async () => rendered.history.push("/settings/models?focus=models.add.chatgpt.fourth"));
  expect(panel()?.querySelector('[data-models-way="chatgpt"]')).not.toBeNull();
});

test("a member sees team keys without admin controls or member rules", async () => {
  const rendered = await render(mockModels.member);
  expect(card(rendered).querySelector('[data-models-section="members"]')).toBeNull();
  const organization = card(rendered).querySelector<HTMLElement>('[data-models-section="organization"]')!;
  expect(action(organization, "orgAdd")).toBeNull();
  expect(action(organization, "orgRemove")).toBeNull();
  expect(organization.textContent).toContain("Team connections");
  expect(organization.querySelector('[data-org-key="claude"]')?.textContent).toContain("Shared Claude key");
});

test("an owner's members switch sends the policy change", async () => {
  const rendered = await render(mockModels.macLogins);
  const row = card(rendered).querySelector<HTMLElement>('[data-models-row="chooseRunout"]')!;
  await click(row.querySelector('[role="switch"]')!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "members", chooseRunout: true }]);
});

test("Escape closes an in-flight device dialog and cancels the attempt", async () => {
  const device = mockChatGPTDevice();
  const rendered = await render(
    { ...mockModels.macOnly, chatgptDevice: device },
    "/settings/cloud?focus=card.cloudModels&provider=chatgpt&open=1",
  );
  const waiting = panel()!.querySelector('[data-chatgpt-device="waiting"]')!;
  expect(waiting.querySelector("code")?.textContent === device.userCode).toBe(true);
  expect(rendered.provider.modelRuns).toEqual([]);
  const link = waiting.querySelector("a")!;
  expect(link.textContent).toBe("auth.openai.com");
  expect(link.getAttribute("href")).toBe(device.verificationURL);
  await click(link);
  await press(panel()!.querySelector("h2")!, "Escape");
  expect(rendered.provider.modelRuns).toEqual([{ action: "openChatGPTDevice" }, { action: "cancelChatGPTDevice" }]);
  expect(panel()).toBeNull();
  await settle();
  expect(document.activeElement).toBe(add());
});

test.each([
  ["expired_token", "The ChatGPT sign-in code expired."],
  ["access_denied", "ChatGPT sign-in was canceled or access was denied."],
  ["network", "Couldn't reach ChatGPT. Check your connection."],
  ["already_signed_in", "This ChatGPT account is already connected."],
  ["no_chatgpt_account", "didn't allow use of its plan"],
  ["keychain_locked", "Unlock your Mac's keychain to use ChatGPT."],
  ["keychain_other_build", "This sign-in was saved by another cmux build. Sign in again to use it here."],
])("a device failure (%s) gives a reason and allows retry", async (error, message) => {
  const rendered = await render(chatgptDeviceError(error), "/settings/cloud?focus=card.cloudModels&provider=chatgpt");
  const row = panel()!;
  expect(row.querySelector("[role=alert]")?.textContent).toContain(message);
  const retry = action(row, "connectChatGPTDevice")!;
  expect(retry.textContent).toContain("Try again");
  await click(retry);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", openBrowser: true }]);
  expect(row.querySelector('[data-chatgpt-device="waiting"]')).not.toBeNull();
});

test("an expired waiting code offers a new code in one gesture", async () => {
  const device = { ...mockChatGPTDevice(), expiresAt: Math.floor(Date.now() / 1000) - 1 };
  const rendered = await render(
    { ...mockModels.macOnly, chatgptDevice: device },
    "/settings/cloud?focus=card.cloudModels&provider=chatgpt&open=1",
  );
  const row = panel()!;
  expect(row.querySelector("[data-chatgpt-device-remaining]")?.textContent).toBe("0:00");
  expect(row.querySelector("[role=alert]")?.textContent).toContain("code expired");
  const retry = action(row, "connectChatGPTDevice")!;
  expect(retry.textContent).toContain("Try again");
  await click(retry);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", openBrowser: true }]);
});

test.each([
  ["starting", "Getting a sign-in code…"],
  ["cancelling", "Cancelling…"],
] as const)("the device %s state shows progress", async (phase, label) => {
  await render({ ...mockModels.macOnly, chatgptDevice: { phase } }, "/settings/cloud");
  const row = panel()!;
  expect(row.querySelector(`[data-chatgpt-device="${phase}"] output`)?.textContent).toContain(label);
  expect(row.querySelector("button[aria-keyshortcuts=Escape]")).not.toBeNull();
});

test("Models shows the key and local subscription rows with the same type line", async () => {
  const state = runMockModels(mockModels.macLogins, {
    action: "addKey",
    provider: "openai",
    key: "fixture",
  });
  const rendered = await render(state);
  expect(detail(rendered, "openai-key")?.textContent).toBe("API key");
  expect(detail(rendered, "codex-login")?.textContent).toBe("Subscription");
  expect(detail(rendered, "claude-login")?.textContent).toBe("Subscription");
});

test("Mac Claude sign-in opens in the browser and cancels when the dialog closes", async () => {
  const rendered = await render(mockModels.macOnly, "/settings/models?focus=models.add.claude&open=picker");
  expect(panel()?.querySelector("h2")?.textContent).toBe("Connect with Claude");
  expect(panel()?.querySelector("input")).toBeNull();
  await click(action(panel()!, "connectClaude")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectClaude", cloud: false }]);
  expect(panel()?.textContent).toContain("Finish signing in in your browser.");
  expect(action(panel()!, "connectClaude")?.disabled).toBe(true);
  await press(panel()!.querySelector("h2")!, "Escape");
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "cancelClaudeLogin", cloud: false });
  expect(panel()).toBeNull();
  expect(document.activeElement).toBe(add());
});

test("Claude signs out from the detected row menu", async () => {
  const rendered = await render(mockModels.macOnly);
  await chooseAction(rendered, "claude-login", "signOutClaude");
  expect(rendered.provider.modelRuns).toEqual([{ action: "signOutClaude", cloud: false }]);
});

test("Cloud Claude Connect starts setup with no machine and Escape cancels it", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "idle", error: null } },
    "/settings/cloud",
  );
  const cloudModels = card(rendered);
  const trigger = add();
  expect(cloudModels.textContent).not.toContain("Sign in from your first Cloud chat");
  await pick("claude");
  const dialog = panel()!;
  expect(dialog.textContent).toContain(
    "Your Cloud machine runs Claude Code with your Claude plan. Sign in with Claude to connect it.",
  );
  expect(action(dialog, "connectClaude")?.disabled).toBe(false);
  await click(action(dialog, "connectClaude")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectClaude", cloud: true }]);
  expect(panel()?.querySelector('[data-login="preparing"] output')?.textContent).toBe("Setting up your Cloud machine…");
  const connecting = action(panel()!, "connectClaude");
  expect(connecting?.disabled).toBe(true);
  expect(connecting?.querySelector(".cv-spinner")).not.toBeNull();
  expect(add()).toBe(trigger);
  expect(cloudModels.textContent).toContain("No connections yet.");
  await press(panel()!.querySelector("h2")!, "Escape");
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "cancelClaudeLogin", cloud: true });
  expect(panel()).toBeNull();
  expect(document.activeElement).toBe(trigger);
  expect(rendered.store.getSnapshot().models?.cloudClaudeLogin?.phase).toBe("idle");
});

test("Cloud Claude setup failure offers Try again", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "failed", error: "machine_start_failed" } },
    "/settings/cloud?focus=card.cloudModels&provider=claude",
  );
  const dialog = panel()!;
  expect(dialog.querySelector("[role=alert]")?.textContent).toBe("Your Cloud machine did not start. Try again.");
  const retry = action(dialog, "connectClaude")!;
  expect(retry.textContent).toContain("Try again");
  await click(retry);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectClaude", cloud: true }]);
  expect(panel()?.querySelector('[data-login="preparing"]')).not.toBeNull();
  await act(async () =>
    rendered.provider.setModels({
      ...mockModels.empty,
      cloudClaudeLogin: { phase: "approving", error: null, machineName: "Cloud machine" },
    }),
  );
  expect(panel()?.textContent).toContain("Finish signing in in your browser.");
});

test("Cloud sign-in clears the fallback code when it is submitted", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "code", error: null } },
    "/settings/cloud?focus=card.cloudModels&provider=claude",
  );
  const dialog = panel()!;
  const field = dialog.querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(action(dialog, "finishClaudeLogin")?.disabled).toBe(true);
  await changeValue(field, "fixture#code");
  await click(action(dialog, "finishClaudeLogin")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "finishClaudeLogin", cloud: true, code: "fixture#code" }]);
  expect(panel()?.querySelector("input")).toBeNull();
  expect(JSON.stringify(rendered.store.getSnapshot().models)).not.toContain("fixture#code");
});

test.each([
  ["approving", null, "Finish signing in in your browser.", true],
  ["cancelling", null, "Cancelling…", true],
  ["failed", "expired", "The sign-in expired. Start again.", false],
  ["failed", "failed", "Sign-in didn't finish. Try again.", false],
  ["disabled", "cli_missing", "Couldn’t start Claude sign-in.", true],
  ["disabled", "shared_machine", "Only the machine's owner can connect Claude here", true],
  ["disabled", "unsupported", "Update", true],
  ["disabled", "update_claude", "Update Claude Code", true],
  ["connected", null, "Connected", true],
] as const)("Claude Cloud shows %s (%s)", async (phase, error, copy, disabled) => {
  await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase, error } },
    "/settings/cloud?focus=card.cloudModels&provider=claude",
  );
  const dialog = panel()!;
  expect(dialog.querySelector("h2")?.textContent).toBe("Connect Claude on Cloud");
  expect(dialog.textContent).toContain(copy);
  expect(dialog.querySelector("input")).toBeNull();
  expect(action(dialog, "connectClaude")?.disabled).toBe(disabled);
});

test("Claude names the configured API key's precedence", async () => {
  await render(
    { ...mockModels.macOnly, claudeLogin: { phase: "idle", error: null, apiKey: true } },
    "/settings/models?focus=models.add.claude",
  );
  expect(panel()?.textContent).toContain("Claude Code uses its configured API key before your Claude plan.");
});

test("a legacy Claude row is Claude Code with only Reconnect, which opens machine sign-in for cleanup", async () => {
  const rendered = await render(mockModels.claudeTokenOnly, "/settings/cloud");
  expect(connectionIds(rendered)).toEqual(["claude-token"]);
  const row = document.querySelector<HTMLElement>('[data-connection="claude-token"]')!;
  expect(row.querySelector(".models-connection-name")?.textContent).toBe("Claude Code");
  expect(row.querySelector(".models-row-detail")).toBeNull();
  expect(status(rendered, "claude-token")).toBeFalsy();
  const reconnect = row.querySelector<HTMLButtonElement>('[data-connection-action="reconnect"]')!;
  expect(reconnect.textContent).toBe("Reconnect");
  expect(reconnect.dataset.variant).toBe("solid");
  await click(reconnect);
  await click(action(panel()!, "connectClaude")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectClaude", cloud: true, replace: "claude-token" }]);
});

test("Reconnect waits for the new Claude result when the previous login was connected", async () => {
  const initial = { phase: "connected", error: null, completion: "previous-login" } as const;
  const models = { ...mockModels.claudeTokenOnly, cloudClaudeLogin: initial };
  const rendered = await render(models, "/settings/cloud");
  const reconnect = row(rendered, "claude-token").querySelector<HTMLButtonElement>(
    '[data-connection-action="reconnect"]',
  )!;
  await click(reconnect);
  const held = Promise.withResolvers<void>();
  rendered.provider.modelsReadHold = held.promise;
  await click(action(panel()!, "connectClaude")!);
  expect(panel()).not.toBeNull();
  await act(async () => rendered.provider.setModels({ ...models, cloudClaudeLogin: { ...initial } }));
  expect(panel()).not.toBeNull();
  await act(async () => {
    rendered.provider.setModels({ ...models, cloudClaudeLogin: { ...initial, completion: "new-login" } });
    held.resolve();
  });
  expect(panel()).toBeNull();
});

test("a second ChatGPT plan never displays the first plan's wrong-account error", async () => {
  const models = structuredClone(mockModels.chatgptForCloud);
  const first = models.personal.connections.find((connection) => connection.kind === "chatgpt-plan")!;
  first.signedIn = false;
  models.personal.connections.push({ ...first, id: "chatgpt-2", email: "second@example.com" });
  const rendered = await render(models);
  await chooseAction(rendered, first.id, "signInAgain");
  await click(action(panel()!, "connectChatGPTDevice")!);
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      deviceTarget: first.id,
      chatgptDevice: {
        phase: "failed",
        error: "different_account",
        actual: "wrong@example.com",
        expected: "first@example.com",
      },
    }),
  );
  expect(panel()?.querySelector("[role=alert]")?.textContent).toContain("wrong@example.com");
  await press(panel()!.querySelector("h2")!, "Escape");
  await chooseAction(rendered, "chatgpt-2", "signInAgain");
  expect(panel()?.querySelector("[role=alert]")).toBeNull();
  expect(panel()?.textContent).not.toContain("wrong@example.com");
  await click(action(panel()!, "connectChatGPTDevice")!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "connectChatGPTDevice",
    openBrowser: true,
    id: "chatgpt-2",
  });
});

test("a Cloud Claude recovery link signs in on the affected machine", async () => {
  const rendered = await render(
    { ...mockModels.claudeTokenOnly, cloudClaudeLogin: { phase: "connected", error: null, machine: "vm_a" } },
    "/settings/cloud?focus=card.cloudModels&provider=claude&machine=vm_b&open=1",
  );
  const form = panel()!;
  expect(form.querySelector("[data-models-claude-form]")?.getAttribute("data-login")).toBe("idle");
  await click(action(form, "connectClaude")!);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "connectClaude", cloud: true, replace: "claude-token", machine: "vm_b" },
  ]);
});

test.each(["claude-login", "codex-login"])("focus on %s reveals the detected row in Models", async (id) => {
  const rendered = await render(mockModels.macOnly, `/settings/models?focus=${id}&open=picker`);
  expect(panel()).toBeNull();
  expect(document.activeElement).toBe(menuButton(rendered, id));
});

test.each(["claude-login", "codex-login", "gemini-login"])(
  "the %s preset does not open a CLI setup form",
  async (id) => {
    await render(mockModels.empty, `/settings/models?focus=models.add.${id}`);
    expect(panel()).toBeNull();
  },
);

test("ChatGPT in Models opens the device code without starting the Codex CLI", async () => {
  const rendered = await render(mockModels.macOnly);
  await pick("chatgpt");
  const connect = action(panel()!, "connectChatGPTDevice")!;
  expect(connect.textContent).toContain("Connect");
  await click(connect);
  expect(panel()?.querySelector("code")?.textContent).toBe("MOCK-1234");
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", openBrowser: true }]);
  expect(rendered.provider.accountRuns).toEqual([]);
});

test("resuming a ChatGPT device attempt does not use an existing plan as a replacement target", async () => {
  const rendered = await render(
    { ...mockModels.chatgptForCloud, chatgptDevice: mockChatGPTDevice() },
    "/settings/cloud",
  );
  expect(panel()?.querySelector("code")?.textContent).toBe("MOCK-1234");
  expect(panel()?.textContent).not.toContain("alex@work.example.com");
  await act(async () =>
    rendered.provider.setModels({
      ...mockModels.chatgptForCloud,
      chatgptDevice: { phase: "failed", error: "network" },
    }),
  );
  await click(action(panel()!, "connectChatGPTDevice")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "connectChatGPTDevice", openBrowser: true }]);
});

test("the mock refuses what acpmux refuses and names new routes as acpmux does", () => {
  const state = structuredClone(mockModels.macLogins);
  expect(() => runMockModels(state, { action: "remove", id: "codex-login" })).toThrow("the CLI's own login");
  expect(() => runMockModels(state, { action: "remove", id: "claude-login" })).toThrow("the CLI's own login");
  expect(() => runMockModels(state, { action: "enable", id: "nope", on: true })).toThrow("unknown connection");
  const keyed = runMockModels(state, {
    action: "addKey",
    provider: "openrouter",
    key: "sk-or-1",
    servesCloud: false,
  });
  expect(keyed.personal.connections.at(-1)).toMatchObject({
    id: "openrouter-key-2",
    families: ["claude", "codex"],
    servesCloud: false,
  });
  const anthropic = runMockModels(mockModels.empty, {
    action: "addKey",
    provider: "anthropic",
    key: "k",
  });
  expect(anthropic.personal.connections[0]).toMatchObject({
    id: "anthropic-key",
    label: "Anthropic API key",
    servesCloud: true,
  });
});

test("the keyboard moves through filtered choices, selects with Return and restores focus on Escape", async () => {
  await render(mockModels.empty, "/settings/models?focus=models.add");
  await settle();
  const search = document.activeElement as HTMLInputElement;
  expect(search.getAttribute("role")).toBe("combobox");
  // "open" finds OpenCode Go and, by its lab's name, ChatGPT among the plans, then the OpenAI key.
  await changeValue(search, "open");
  const active = () => document.getElementById(search.getAttribute("aria-activedescendant")!)?.dataset.modelsChoice;
  expect(active()).toBe("chatgpt");
  await press(search, "ArrowDown");
  expect(active()).toBe("opencode-go");
  await press(search, "ArrowUp");
  expect(active()).toBe("chatgpt");
  await press(search, "ArrowDown");
  await press(search, "Enter");
  expect(panel()?.dataset.modelsDialog).toBe("opencode-go");
  expect(document.querySelector("[data-models-catalog]")).toBeNull();
  expect(panel()?.contains(document.activeElement)).toBe(true);
  await press(document.activeElement!, "Escape");
  await settle();
  expect(panel()).toBeNull();
  expect(document.activeElement).toBe(add());
  await click(add());
  await press(document.activeElement!, "Escape");
  await settle();
  expect(add().getAttribute("aria-expanded")).toBe("false");
  expect(document.activeElement).toBe(add());
});

test("in the column view the arrows move across Plans and the keys grid and down a column", async () => {
  await render(mockModels.empty, "/settings/models?focus=models.add");
  await settle();
  const search = document.activeElement as HTMLInputElement;
  const active = () => document.getElementById(search.getAttribute("aria-activedescendant")!)?.dataset.modelsChoice;
  const plans = [...catalog().querySelectorAll('[data-models-group="plans"] [data-models-choice]')].map(
    (row) => row.getAttribute("data-models-choice") ?? undefined,
  );
  await press(search, "ArrowDown");
  expect(active()).toBe(plans[0]);
  await press(search, "ArrowRight");
  expect(active()).toBe("anthropic");
  await press(search, "ArrowRight");
  expect(active()).toBe("openai");
  await press(search, "ArrowRight");
  expect(active()).toBe("openai");
  // Down a grid row: OpenAI's column, one row on (the grid is two wide).
  await press(search, "ArrowDown");
  expect(active()).toBe("xai");
  await press(search, "ArrowLeft");
  expect(active()).toBe("google");
  await press(search, "ArrowLeft");
  expect(active()).toBe(plans[1]);
  await press(search, "ArrowUp");
  expect(active()).toBe(plans[0]);
  await press(search, "ArrowUp");
  expect(active()).toBe("endpoint");
});

test("API submission stays busy while the host verifies and saves on one gesture", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?focus=models.add.anthropic");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-key-form]")!;
  await changeValue(form.querySelector('input[type="password"]')!, "sk-ant-example");
  const pending = Promise.withResolvers<void>();
  rendered.provider.holdModelAccess = pending.promise;
  await click(action(form, "addKey")!);
  expect(form.querySelector("[data-models-saving]")).not.toBeNull();
  expect(action(form, "addKey")?.disabled).toBe(true);
  await act(async () => pending.resolve());
  await settle();
  expect(panel()).toBeNull();
  expect(connectionIds(rendered)).toEqual(["anthropic-key"]);
  expect(rendered.provider.modelRuns).toEqual([
    {
      action: "addKey",
      provider: "anthropic",
      key: "sk-ant-example",
      verifyAccess: true,
    },
  ]);
});

test("a refusal from an access check stays visible in the form", async () => {
  page = await renderPage({
    path: "/settings/models?focus=models.add.openai",
    mock: { modelAccess: { failure: "The provider refused the key (HTTP 401)." } },
    setup: (provider) => {
      provider.models = mockModels.empty;
    },
  });
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-key-form]")!;
  await changeValue(form.querySelector('input[type="password"]')!, "example-key");
  await click(action(form, "addKey")!);
  const error = panel()?.querySelector('[role="alert"]');
  expect(error?.textContent).toContain("HTTP 401");
  expect(error?.querySelector("svg")).not.toBeNull();
  expect(connectionIds(page)).toEqual([]);
});

test("Add custom provider checks its URL and saves every model it lists through the existing harness add", async () => {
  const rendered = await render(mockModels.empty);
  await pick("endpoint");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  const connect = action(form, "addEndpoint")!;
  const url = form.querySelector<HTMLInputElement>('input[type="url"]')!;
  await changeValue(form.querySelector('input[type="text"]')!, "Inference");
  await changeValue(url, "http://inference.example.com/v1");
  expect(connect.disabled).toBe(true);
  await changeValue(url, "https://inference.example.com/v1/?api-version=1");
  await changeValue(url, "https://inference.example.com/v1/");
  expect(connect.disabled).toBe(false);
  expect(form.querySelector("[data-models-check]")).toBeNull();
  expect(form.querySelector(".models-add-model")).toBeNull();
  await click(connect);
  const add = rendered.provider.log.find((call) => call.op === "cmux.chief.backend.add");
  expect(add?.params).toMatchObject({
    kind: "openai-endpoint",
    name: "Inference",
    baseUrl: "https://inference.example.com/v1/",
    model: "*",
  });
  expect(panel()).toBeNull();
  expect(detail(rendered, "inference")?.textContent).toBe("Custom");
  await chooseAction(rendered, "inference", "edit");
  expect(panel()?.querySelector("h2")?.textContent).toBe("Edit Inference");
  const edit = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  expect(edit.querySelector('input[type="url"]')).toHaveProperty("value", "https://inference.example.com/v1");
  expect(edit.querySelector('input[type="password"]')).toHaveProperty("value", "");
  await changeValue(edit.querySelector('input[type="text"]')!, "Research endpoint");
  await click(action(edit, "addEndpoint")!);
  const saved = rendered.provider.log.filter((call) => call.op === "cmux.chief.backend.add").at(-1);
  expect(saved?.params).toMatchObject({
    id: "inference",
    replace: "inference",
    edit: expect.any(String),
    name: "Research endpoint",
  });
  expect(connectionIds(rendered)).toEqual(["inference"]);
  await chooseAction(rendered, "inference", "edit");
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-key");
  await click(action(panel()!, "addEndpoint")!);
  await chooseAction(rendered, "inference", "edit");
  expect(panel()?.textContent).toContain("Leave empty to keep the current key.");

  rendered.provider.agents.addEndpoint({
    id: "inference",
    replace: "inference",
    name: "Updated elsewhere",
    kind: "openai-endpoint",
    baseUrl: "https://other.example.com/v1",
    model: "model-large",
  });
  const latest = rendered.provider.agents.modelEndpoint("inference")!;
  const state = rendered.provider.models!;
  await act(async () =>
    rendered.provider.setModels({
      ...state,
      personal: { ...state.personal, connections: [latest] },
    }),
  );
  await changeValue(panel()!.querySelector('input[type="text"]')!, "Old draft");
  await click(action(panel()!, "addEndpoint")!);
  expect(panel()?.querySelector('[role="alert"]')).not.toBeNull();
  expect(rendered.provider.agents.modelEndpoint("inference")).toEqual(latest);
});

test("Rename changes only a saved connection's name", async () => {
  const rendered = await render(mockModels.macLogins);
  const menu = card(rendered).querySelector('[data-menu="connection-openrouter-key"]')!;
  await click(menu);
  await click(document.querySelector('[role="menuitem"][data-value="rename"]')!);
  const rename = panel()!;
  expect(rename.querySelector("h2")?.textContent).toBe("Rename OpenRouter API key");
  await changeValue(rename.querySelector("input")!, "Research");
  await click(action(rename, "rename")!);
  expect(document.activeElement).toBe(menu);
  expect(rendered.provider.modelRuns).toEqual([{ action: "rename", id: "openrouter-key", name: "Research" }]);
  expect(card(rendered).querySelector('[data-connection="openrouter-key"]')?.textContent).toContain("Research");
});

test("Disconnect confirms in a dialog and returns focus to Connect when the row goes away", async () => {
  const rendered = await render(mockModels.macLogins);
  await chooseAction(rendered, "openrouter-key", "remove");
  expect(panel()?.querySelector("h2")?.textContent).toBe("Disconnect OpenRouter API key");
  const button = action(panel()!, "confirmRemove")!;
  expect(button.hasAttribute("data-danger")).toBe(true);
  expect(rendered.provider.modelRuns).toEqual([]);
  await click(button);
  await settle();
  expect(connectionIds(rendered)).toEqual(["codex-login", "claude-login", "chatgpt"]);
  expect(document.activeElement).toBe(add());
});

test("disconnecting Copilot links to the GitHub app revocation page", async () => {
  const models = structuredClone(mockModels.empty);
  models.personal.connections.push({
    id: "copilot-plan",
    label: "GitHub Copilot",
    provider: "copilot",
    kind: "copilot-plan",
    families: ["github-copilot"],
    enabled: true,
    signedIn: true,
    servesCloud: true,
    defaultFor: [],
    email: null,
    plan: null,
  });
  const rendered = await render(models);
  await chooseAction(rendered, "copilot-plan", "remove");
  const link = panel()?.querySelector<HTMLAnchorElement>("a");
  expect(link?.href).toBe("https://github.com/settings/applications");
  expect(link?.textContent).toBe("Revoke the app in GitHub settings.");
  await click(action(panel()!, "confirmRemove")!);
  expect(rendered.provider.modelRuns).toEqual([{ action: "remove", id: "copilot-plan" }]);
});

test("Edit leaves a blank key alone and replaces a filled key on the same connection", async () => {
  const rendered = await render(mockModels.macLogins);
  await chooseAction(rendered, "openrouter-key", "edit");
  expect(panel()?.querySelector("h2")?.textContent).toBe("Edit OpenRouter");
  expect(panel()?.textContent).toContain("Leave empty to keep the current key.");
  const field = () => panel()!.querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(field().value).toBe("");
  await click(action(panel()!, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([]);
  await chooseAction(rendered, "openrouter-key", "edit");
  await changeValue(field(), "fixture-replacement");
  await click(action(panel()!, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([
    {
      action: "addKey",
      provider: "openrouter",
      key: "fixture-replacement",
      verifyAccess: true,
      replace: "openrouter-key",
    },
  ]);
  expect(connectionIds(rendered)).toEqual(["codex-login", "claude-login", "chatgpt", "openrouter-key"]);
  expect(detail(rendered, "openrouter-key")?.textContent).toBe("API key");
  expect(status(rendered, "openrouter-key")?.textContent).toBe("Turned off");
});

test("a saved key shows a spinner while Check access runs and reports results in the menu", async () => {
  const rendered = await render(mockModels.macLogins);
  const pending = Promise.withResolvers<void>();
  rendered.provider.holdModelAccess = pending.promise;
  await chooseAction(rendered, "openrouter-key", "checkAccess");
  expect(row(rendered, "openrouter-key").querySelector('[aria-label="Checking access…"]')).not.toBeNull();
  await act(async () => pending.resolve());
  await settle();
  expect(row(rendered, "openrouter-key").querySelector("[data-models-access]")).toBeNull();
  await click(menuButton(rendered, "openrouter-key"));
  expect(document.querySelector('[data-models-access="ok"]')?.textContent).toContain("Access OK, 2 models");
  expect(rendered.provider.modelRuns).toEqual([{ action: "checkAccess", id: "openrouter-key" }]);
  expect(rendered.store.getSnapshot().models).toEqual(mockModels.macLogins);
});

test("changing the endpoint URL clears a draft key", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?focus=models.add.endpoint");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  const url = form.querySelector<HTMLInputElement>('input[type="url"]')!;
  await changeValue(url, "https://models.example.com/v1/chat/completions");
  expect(url.value).toBe("https://models.example.com/v1");
  await changeValue(form.querySelector('input[type="password"]')!, "example-key");
  await click(form.querySelector('[aria-label="Show secret"]')!);
  expect(rendered.provider.log.some((call) => call.op === "cmux.chief.backend.add")).toBe(false);
  await changeValue(url, "https://other.example.com/v1");
  expect(form.querySelector<HTMLInputElement>('input[type="password"]')?.value).toBe("");
  expect(action(form, "addEndpoint")!.disabled).toBe(true);
});

test.each(["grok", "copilot"])("Connect declines to start unavailable %s sign-in", async (provider) => {
  const rendered = await render(mockModels.empty);
  await click(add());
  await click(choice(provider)!);
  expect(panel()).toBeNull();
  expect(rendered.provider.modelRuns).toEqual([]);
  expect(rendered.provider.accountRuns).toEqual([]);
});

test.each(["nvidia", "mistral", "groq"])("a fixed %s endpoint connects with its key alone", async (id) => {
  const rendered = await render({ ...mockModels.empty, connectionTools: true });
  await pick(id);
  const form = panel()!;
  expect(form.querySelector('input[type="url"]')).toBeNull();
  expect(form.querySelector("[data-models-check]")).toBeNull();
  expect(form.querySelector(".models-add-model")).toBeNull();
  const connect = action(form, "addEndpoint")!;
  expect(connect.disabled).toBe(true);
  await changeValue(form.querySelector('input[type="password"]')!, "fixture-key");
  await click(connect);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    apiKey: "fixture-key",
    model: "*",
  });
});

test("MiniMax coding plan saves its Anthropic endpoint on OpenCode", async () => {
  const rendered = await render(mockModels.empty);
  await pick("minimax-coding-plan");
  const form = panel()!;
  const key = form.querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(key.placeholder).toContain("sk-cp-");
  await changeValue(key, "sk-cp-fixture");
  await click(action(form, "addEndpoint")!);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    kind: "openai-endpoint",
    preset: "minimax-coding-plan",
    baseUrl: "https://api.minimax.io/anthropic",
    model: "MiniMax-M3.1-Flash",
  });
});

test("Cerebras shows its API key prefix", async () => {
  await render(mockModels.empty);
  await pick("cerebras");
  expect(panel()?.querySelector<HTMLInputElement>('input[type="password"]')?.placeholder).toContain("csk-");
});

test("Morph opens its Ultra endpoint with the two plan models", async () => {
  const rendered = await render(mockModels.empty);
  await pick("morph");
  const form = panel()!.querySelector<HTMLFormElement>("[data-models-endpoint-form]")!;
  await changeValue(form.querySelector('input[type="password"]')!, "morph-fixture");
  await click(action(form, "addEndpoint")!);
  expect(rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params).toMatchObject({
    baseUrl: "https://api.morphllm.com/v1",
    model: "morph-kimik31,morph-dsv41flash",
    preset: "morph",
  });
});

const providerDialogCopy = [
  [
    "chatgpt",
    "Connect with ChatGPT",
    "cmux will use your ChatGPT plan to run Codex models. Sign in with ChatGPT and enter the device code to connect.",
    "Connect",
  ],
  [
    "claude",
    "Connect with Claude",
    "cmux runs Claude Code with your Claude plan. Sign in with Claude in your browser to connect.",
    "Connect",
  ],
  [
    "kimi-code",
    "Connect with Kimi Code",
    "cmux will use your subscription to access Kimi Code supported models. Sign in with Kimi Code to connect your account.",
    "Connect",
  ],
  [
    "glm-coding-plan",
    "Connect with GLM Coding Plan",
    "cmux will use your GLM Coding Plan to access GLM models. Paste a Coding Plan API key to connect.",
    "Connect",
  ],
  [
    "minimax-coding-plan",
    "Connect with MiniMax",
    "cmux will use your MiniMax Coding Plan to access MiniMax models. Paste a Coding Plan key to connect.",
    "Connect",
  ],
  [
    "opencode-go",
    "Connect with OpenCode Go",
    "cmux will use your OpenCode Go plan to access its open models. Paste your OpenCode API key to connect.",
    "Connect",
  ],
  [
    "ollama-cloud",
    "Connect with Ollama Cloud",
    "cmux will use your Ollama account to run cloud models. Paste an Ollama API key to connect.",
    "Connect",
  ],
  [
    "morph",
    "Connect with Morph Ultra",
    "cmux will use your Morph Ultra plan for its coding models. Paste a Morph API key to connect.",
    "Connect",
  ],
  ["openrouter", "Connect with OpenRouter", "cmux will use your OpenRouter credits to access its models.", "Connect"],
  [
    "anthropic",
    "Connect Anthropic API",
    "cmux will use your API key to access Claude models. Usage bills to your Claude Console account.",
    "Connect",
  ],
  ["openai", "Connect OpenAI API", "cmux will use your OpenAI API key. Usage bills to the key's project.", "Connect"],
  [
    "google",
    "Connect Gemini API",
    "cmux will use your Google AI Studio key to access Gemini models. Free tier limits apply until billing is on.",
    "Connect",
  ],
  [
    "xai",
    "Connect xAI API",
    "cmux will use your xAI API key to access Grok models. Usage bills to your xAI account.",
    "Connect",
  ],
  [
    "deepseek",
    "Connect with DeepSeek",
    "cmux will use your DeepSeek API key. Usage comes from your DeepSeek balance.",
    "Connect",
  ],
  ["mistral", "Connect with Mistral", "cmux will use your Mistral API key.", "Connect"],
  ["groq", "Connect with Groq", "cmux will use your Groq API key for fast open models.", "Connect"],
  [
    "together",
    "Connect with Together AI",
    "cmux will use your Together AI key to run open models. Usage bills per token.",
    "Connect",
  ],
  [
    "fireworks",
    "Connect with Fireworks",
    "cmux will use your Fireworks key to run open models. Usage bills per token.",
    "Connect",
  ],
  ["cerebras", "Connect with Cerebras", "cmux will use your Cerebras key for very fast open models.", "Connect"],
  [
    "moonshot",
    "Connect with Kimi Platform",
    "cmux will use your Kimi API key. Usage comes from your platform balance.",
    "Connect",
  ],
  [
    "qwen",
    "Connect with Qwen",
    "cmux will use your Model Studio key to access Qwen models. Pick the region that issued the key.",
    "Connect",
  ],
  ["zai", "Connect with Z.ai", "cmux will use your Z.ai API balance to access GLM models.", "Connect"],
  [
    "minimax",
    "Connect with MiniMax API",
    "cmux will use your MiniMax API key to access MiniMax models. Usage bills to your MiniMax account.",
    "Connect",
  ],
  [
    "baseten",
    "Connect with Baseten",
    "cmux will use your Baseten account to run Model APIs. Paste a Baseten API key.",
    "Connect",
  ],
  [
    "nvidia",
    "Connect with NVIDIA",
    "cmux will use your NVIDIA developer account to access models on NVIDIA Build. Paste an API key from NVIDIA Build.",
    "Connect",
  ],
  [
    "hugging-face",
    "Connect with Hugging Face",
    "cmux will use your Hugging Face account to call Inference Providers. Paste a token with Inference Providers permission.",
    "Connect",
  ],
  [
    "meta",
    "Connect Meta Model API",
    "cmux will use your Meta developer account to access Muse models. Paste a key from the Model API dashboard.",
    "Connect",
  ],
  [
    "vercel",
    "Connect Vercel AI Gateway",
    "cmux will use your team's AI Gateway credits to access its models. Paste an AI Gateway API key.",
    "Connect",
  ],
  [
    "vercel-token-pass",
    "Connect with Vercel Token Pass",
    "Use the models included with your Token Pass, with no paid AI Gateway fallback. Paste a Token Pass key.",
    "Connect",
  ],
  [
    "cloudflare",
    "Connect with Cloudflare AI Gateway",
    "cmux will send requests through your gateway and use your Cloudflare credits. Paste a token with AI Gateway Run permission.",
    "Connect",
  ],
  [
    "bedrock",
    "Connect Amazon Bedrock",
    "cmux will use your AWS account to access Bedrock models. Paste a Bedrock API key and choose its region.",
    "Connect",
  ],
  [
    "azure",
    "Connect Azure OpenAI",
    "cmux will use the models you deployed in your Azure resource. Paste its endpoint, a key and the deployment names.",
    "Connect",
  ],
  ["ollama", "Connect Ollama", "cmux will use models that run on this Mac through Ollama.", "Connect"],
  ["lm-studio", "Connect LM Studio", "cmux will use models that run on this Mac through LM Studio.", "Connect"],
  [
    "endpoint",
    "Add a custom provider",
    "cmux will connect to any service that uses the OpenAI API. Enter its base URL and key.",
    "Connect",
  ],
] as const;

test.each(providerDialogCopy)("%s shows its own connection dialog copy", async (id, title, description, primary) => {
  const focus = id === "ollama" || id === "lm-studio" ? `provider=${id}` : `focus=models.add.${id}`;
  await render(mockModels.empty, `/settings/models?${focus}`);
  const dialog = panel()!;
  expect(dialog.querySelector("h2")?.textContent).toBe(title);
  expect(dialog.querySelector(".models-dialog-heading p")?.textContent).toBe(description);
  const buttons = Array.from(dialog.querySelectorAll<HTMLButtonElement>(".models-footer-buttons button"));
  expect(buttons).toHaveLength(2);
  expect(buttons[0]?.textContent).toContain("Cancel");
  expect(buttons[1]?.textContent).toContain(primary);
  expect(buttons[1]?.type).toBe("submit");
});

test.each([
  ["glm-coding-plan", "zaiChina", "https://open.bigmodel.cn/api/coding/paas/v4"],
  ["minimax-coding-plan", "minimaxChina", "https://api.minimaxi.com/anthropic"],
  ["minimax", "minimaxChina", "https://api.minimaxi.com/v1"],
  ["mistral", "europe", "https://api.eu.mistral.ai/v1"],
  ["mistral", "unitedStates", "https://api.us.mistral.ai/v1"],
  ["moonshot", "mainlandChina", "https://api.moonshot.cn/v1"],
  ["qwen", "virginia", "https://dashscope-us.aliyuncs.com/compatible-mode/v1"],
  ["qwen", "beijing", "https://dashscope.aliyuncs.com/compatible-mode/v1"],
  ["zai", "zaiChina", "https://open.bigmodel.cn/api/paas/v4"],
])("%s saves and reopens the selected region %s", async (id, region, baseUrl) => {
  const rendered = await render(mockModels.empty, `/settings/models?focus=models.add.${id}`);
  const dialog = panel()!;
  await changeRegion(dialog.querySelector("select")!, region);
  await changeValue(dialog.querySelector('input[type="password"]')!, "region-fixture");
  await click(action(dialog, "addEndpoint")!);
  const saved = rendered.provider.log.find(({ op }) => op === "cmux.chief.backend.add")?.params;
  expect(saved).toMatchObject({ preset: id, baseUrl });
  await chooseAction(rendered, (saved as { id: string }).id, "edit");
  expect(panel()?.querySelector("select")?.value).toBe(region);
});

test("Kimi Code forwards the selected region to sign-in", async () => {
  const rendered = await render(mockModels.empty);
  await pick("kimi-code");
  const dialog = panel()!;
  await changeRegion(dialog.querySelector("select")!, "kimiChina");
  await click(action(dialog, "connectChatGPTDevice")!);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "connectChatGPTDevice", provider: "kimi", openBrowser: true, region: "kimiChina" },
  ]);
  expect(dialog.querySelector("input[type=password]")).toBeNull();
  await press(dialog, "Escape");
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "cancelChatGPTDevice" });
});

test("OpenRouter opens on its key and saves it through the existing API-key operation", async () => {
  const rendered = await render(mockModels.empty);
  await pick("openrouter");
  const dialog = panel()!;
  await changeValue(dialog.querySelector("input[type=password]")!, "sk-or-fixture");
  await click(action(dialog, "addKey")!);
  expect(rendered.provider.modelRuns).toEqual([
    { action: "addKey", provider: "openrouter", key: "sk-or-fixture", verifyAccess: true },
  ]);
});
