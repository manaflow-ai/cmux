import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { ModelsState } from "./ops";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, changeValue, click, ops, settle } = await import("./testing");
const { createRoot } = await import("react-dom/client");
const { CloudSetupCard } = await import("../../agent-session/acpmux/conversation/CloudSetupCard");
const { waitForCloudSetUp } = await import("../../agent-session/acpmux/cloudSetup");
const { mockModels } = await import("./mockModels");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const render = async (models: ModelsState, path = "/settings/cloud") => {
  page = await renderPage({
    path,
    closedMore: true,
    setup: (provider) => {
      provider.models = structuredClone({
        cloudHarnesses: ["claude", "gemini", "grok", "opencode"],
        ...models,
      });
    },
  });
  return page;
};
const card = (rendered: Rendered) => rendered.container.querySelector<HTMLElement>('[data-card="cloudModels"]')!;
const panel = () => document.querySelector<HTMLElement>("[data-models-dialog]");
const ids = (rendered: Rendered) =>
  [...card(rendered).querySelectorAll<HTMLElement>("[data-connection]")].map((row) => row.dataset.connection);

test("Cloud models sits alongside Cloud Environments and Cloud Workspaces", async () => {
  const rendered = await render(mockModels.macLogins, "/settings/cloud");
  expect(card(rendered).querySelector("h3")?.textContent).toBe("Cloud models");
  expect(ids(rendered)).toEqual(["chatgpt", "claude-token", "openrouter-key"]);
  expect(rendered.container.querySelector("[data-models-catalog]")).toBeNull();
  expect(rendered.container.querySelector('[data-card="cloudEnvironments"]')).not.toBeNull();
  expect(rendered.container.textContent).toContain("Cloud Workspaces");
  expect(ops(rendered.provider, "cmux.settings.models.state")).toHaveLength(1);
});

test.each([
  ["claude", "claude"],
  ["codex", "chatgpt"],
  ["gemini", "google"],
  ["grok-build", "xai"],
])("picker Connect for %s opens and focuses %s in Cloud models", async (family, provider) => {
  await render(mockModels.empty, `/settings/models?provider=${family}&open=from-picker`);
  expect(document.querySelector("[data-models-catalog]")).toBeNull();
  expect(panel()?.dataset.modelsDialog).toBe(provider);
  expect(document.activeElement?.className).toBe("models-dialog-heading");
});

test.each([
  ["cloud.claude", "claude"],
  ["cloud.chatgpt", "chatgpt"],
])("an old Cloud focus %s redirects to the %s form", async (focus, provider) => {
  const rendered = await render(mockModels.empty, `/settings/cloud?focus=${focus}`);
  expect(rendered.history.location.pathname).toBe("/settings/cloud");
  expect(panel()?.dataset.modelsDialog).toBe(provider);
  expect(document.activeElement?.className).toBe("models-dialog-heading");
});

test("an old API-key focus still opens Add a connection and honors a named provider", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=cloud.apiKey");
  expect(rendered.history.location.pathname).toBe("/settings/cloud");
  expect(panel()).toBeNull();
  await settle();
  expect(document.activeElement?.getAttribute("role")).toBe("combobox");
  await act(async () => rendered.history.push("/settings/cloud?focus=cloud.apiKey&provider=gemini&open=legacy"));
  expect(rendered.history.location.pathname).toBe("/settings/cloud");
  expect(panel()?.dataset.modelsDialog).toBe("google");
});

test("a Cloud picker request opens after the loading rows settle", async () => {
  const pending = Promise.withResolvers<void>();
  const rendered = (page = await renderPage({
    path: "/settings/models?provider=claude&open=from-picker",
    setup: (provider) => {
      provider.modelsReadHold = pending.promise;
      provider.models = mockModels.claudeForCloud;
    },
  }));
  const loading = card(rendered).querySelector("[data-models-connections-loading]");
  expect(loading?.querySelector("output")?.textContent).toBe("Loading connections…");
  expect(loading?.querySelectorAll('.row[aria-hidden="true"]')).toHaveLength(3);
  expect(card(rendered).querySelector("[role=alert]")).toBeNull();
  expect(panel() === null).toBe(true);
  await act(async () => pending.resolve());
  await settle();
  expect(panel()?.dataset.modelsDialog).toBe("claude");
  expect(panel()?.contains(document.activeElement)).toBe(true);
  expect(ids(rendered)).toEqual(["claude-token"]);
  expect(rendered.provider.modelRuns).toEqual([]);
  expect(ops(rendered.provider, "cmux.settings.models.state")).toHaveLength(1);
});

test("Try again refreshes the same model read and opens the requested form", async () => {
  const unavailable = structuredClone(mockModels.empty);
  unavailable.personal.available = false;
  const rendered = await render(unavailable, "/settings/models?provider=openai&open=retry");
  expect(card(rendered).querySelector('[role="alert"]')?.textContent).toBe("Couldn't load model connections.");
  expect(panel() === null).toBe(true);
  const retry = [...card(rendered).querySelectorAll("button")].find((button) => button.textContent === "Try again")!;
  rendered.provider.models = mockModels.claudeForCloud;
  await click(retry);
  expect(card(rendered).querySelector('[role="alert"]')).toBeNull();
  expect(panel()?.dataset.modelsDialog).toBe("openai");
  expect(ops(rendered.provider, "cmux.settings.models.state")).toHaveLength(2);
});

test("Claude and Codex picker links open their Cloud forms and a new open value reopens the form", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?provider=claude&open=1");
  expect(panel()?.dataset.modelsDialog).toBe("claude");
  const cancel = [...panel()!.querySelectorAll("button")].find(
    (button) => button.getAttribute("aria-keyshortcuts") === "Escape" && button.textContent?.includes("Cancel"),
  )!;
  await click(cancel);
  expect(panel() === null).toBe(true);
  await settle();
  expect(document.activeElement).toBe(card(rendered).querySelector("[data-models-add]"));
  await act(async () => rendered.history.push("/settings/models?provider=claude&open=2"));
  expect(panel()?.dataset.modelsDialog).toBe("claude");
  await act(async () => rendered.history.push("/settings/models?provider=codex&open=3"));
  expect(panel()?.dataset.modelsDialog).toBe("chatgpt");
});

test("the Codex held-send setup link opens the OpenAI key dialog", async () => {
  await render(mockModels.empty, "/settings/models?provider=codex&open=from-card&fromSend=1");
  expect(panel()?.dataset.modelsDialog).toBe("openai");
  expect(document.querySelector("[data-models-catalog]")).toBeNull();
});

test("only a new Cloud connection for the requested family confirms the visit", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?provider=claude&open=1");
  const status = () => card(rendered)?.querySelector("[data-cloud-connected]")?.textContent;
  expect(status()).toBeUndefined();
  await act(async () => rendered.provider.setModels(mockModels.chatgptForCloud));
  expect(status()).toBeUndefined();
  await act(async () => rendered.provider.setModels(mockModels.claudeMacOnly));
  expect(status()).toBeUndefined();
  await act(async () => rendered.provider.setModels(mockModels.claudeForCloud));
  expect(status()).toBe("Connected. Go back to your chat.");
  await act(async () => rendered.history.push("/settings/models?provider=claude&open=2"));
  expect(status()).toBeUndefined();
  await act(async () => rendered.history.push("/settings/models"));
  await act(async () => rendered.provider.setModels(mockModels.chatgptForCloud));
  expect(status()).toBeUndefined();
});

test("Connect on the held-send card opens the Cloud models form and waits for the connection", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud");
  const host = Promise.withResolvers<unknown>();
  const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
  const need = { family: "claude" } as const;
  const chat = document.createElement("div");
  document.body.append(chat);
  const root = createRoot(chat);
  try {
    let setup: ReturnType<typeof waitForCloudSetUp> | undefined;
    await act(async () =>
      root.render(
        <CloudSetupCard
          need={need}
          runHereLabel="Run on This Mac"
          onSetUp={(action) => {
            setup = waitForCloudSetUp(
              (method, params) => {
                calls.push({ method, ...(params ? { params } : {}) });
                // The native host owns the route and keeps the send until the connection is ready.
                rendered.history.push("/settings/models?provider=claude&open=from-card&fromSend=1");
                return host.promise;
              },
              "held-send",
              action,
              need,
              () => () => undefined,
            );
          }}
        />,
      ),
    );
    await click(chat.querySelector('[data-action="setUpClaude"]')!);
    expect(calls).toEqual([
      { method: "cloud.setUp", params: { key: "held-send", action: "setUpClaude", family: "claude" } },
    ]);
    expect(rendered.history.location.pathname).toBe("/settings/cloud");
    expect(panel()?.dataset.modelsDialog).toBe("claude");
    expect(document.activeElement?.className).toBe("models-dialog-heading");
    await act(async () => rendered.provider.setModels(mockModels.claudeForCloud));
    host.resolve({ ready: true });
    expect(await setup?.ended).toBe("signedIn");
    expect(card(rendered).querySelector("[data-cloud-connected]")?.textContent).toBe(
      "Connected. Your chat is starting.",
    );
  } finally {
    await act(async () => root.unmount());
    chat.remove();
  }
});

test("Cloud models can enable and disable a key added in Models without removing the local row", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?focus=models.add.openai");
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-api-key");
  await click(panel()!.querySelector('[data-models-action="addKey"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toMatchObject({ action: "addKey" });
  expect(rendered.provider.modelRuns.at(-1)).not.toHaveProperty("servesCloud");
  await act(async () => rendered.history.push("/settings/cloud"));
  const key = card(rendered).querySelector('[data-connection="openai-key"]')!;
  expect(key.textContent).toContain("API key");
  expect(key.textContent).not.toContain("Not used on Cloud");
  await click(key.querySelector('[data-menu="connection-openai-key"]')!);
  expect(document.querySelector('[data-value="moveUp"]')).toBeNull();
  expect(document.querySelector('[data-value="moveDown"]')).toBeNull();
  expect(document.querySelector('[data-value="remove"]')).toBeNull();
  const stop = document.querySelector('[data-value="setCloud"]')!;
  expect(stop.textContent).toBe("Stop using on Cloud");
  await click(stop);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "setCloud",
    id: "openai-key",
    on: false,
  });
  expect(key.textContent).toContain("Not used on Cloud");
  await click(key.querySelector('[data-menu="connection-openai-key"]')!);
  const use = document.querySelector('[data-value="setCloud"]')!;
  expect(use.textContent).toBe("Use on Cloud");
  await click(use);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "setCloud",
    id: "openai-key",
    on: true,
  });
  expect(key.textContent).not.toContain("Not used on Cloud");
  await act(async () => rendered.history.push("/settings/models"));
  const local = rendered.container.querySelector('[data-card="models"] [data-connection="openai-key"]')!;
  await click(local.querySelector("[data-menu]")!);
  expect(local.textContent).toContain("API key");
  expect(document.querySelector('[data-value="setCloud"]')).toBeNull();
});

test("Cloud models adds a key with Cloud use enabled", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=cloudModels.add.openai");
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-api-key");
  await click(panel()!.querySelector('[data-models-action="addKey"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toMatchObject({ action: "addKey", servesCloud: true });
  expect(card(rendered).querySelector('[data-connection="openai-key"]')?.textContent).toContain("API key");
});

test("Cloud models updates a saved endpoint using its existing profile revision and key", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=cloudModels.add.deepseek");
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-endpoint-key");
  await click(panel()!.querySelector('[data-models-action="addEndpoint"]')!);
  const adds = () => ops(rendered.provider, "cmux.chief.backend.add");
  expect(adds().at(-1)).toMatchObject({
    kind: "openai-endpoint",
    id: "deepseek",
    servesCloud: true,
  });
  const endpoint = card(rendered).querySelector('[data-connection="deepseek"]')!;
  expect(endpoint.querySelector(".models-row-detail")?.textContent).toBe("Custom");
  await click(endpoint.querySelector("[data-menu]")!);
  await click(document.querySelector('[data-value="setCloud"]')!);
  const edited = adds().at(-1);
  expect(edited).toMatchObject({
    id: "deepseek",
    replace: "deepseek",
    edit: "1",
    servesCloud: false,
  });
  expect(edited).not.toHaveProperty("apiKey");
  expect(endpoint.textContent).toContain("Not used on Cloud");

  rendered.provider.agents.endpoint.addFails = "cmux.page.invalid_params";
  await click(endpoint.querySelector("[data-menu]")!);
  await click(document.querySelector('[data-value="setCloud"]')!);
  expect(card(rendered).querySelector('[role="alert"]')).not.toBeNull();
  expect(endpoint.textContent).toContain("Not used on Cloud");
});

test("Settings search opens the Cloud models card", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?q=cloud%20models");
  const result = rendered.container.querySelector('[data-page-hit="cloudModels"]')!;
  await click(result);
  expect(rendered.history.location.pathname).toBe("/settings/cloud");
  expect(rendered.history.location.search).toContain("card.cloudModels");
  expect(card(rendered).querySelector("h3")?.textContent).toBe("Cloud models");
});

test("a picker link for an unsupported family lands in Cloud models with its status", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=card.cloudModels&provider=cursor&open=visit");
  const row = card(rendered).querySelector("[data-cloud-coming-soon]")!;
  expect(row.textContent).toContain("Cursor");
  expect(row.textContent).toContain("Runs on Cloud soon");
  expect(row.querySelector(".models-provider-mark")).not.toBeNull();
  expect(panel()).toBeNull();
  expect(rendered.provider.modelRuns).toEqual([]);
});

test("Connect opens the opted-out connection's Cloud toggle", async () => {
  const state = structuredClone(mockModels.empty);
  state.personal.connections.push({
    id: "anthropic-key",
    label: "Anthropic API key",
    provider: "anthropic",
    kind: "api-key",
    families: ["claude"],
    signedIn: true,
    enabled: true,
    servesCloud: false,
    canServeCloud: true,
    defaultFor: [],
    email: null,
    plan: null,
  });
  const rendered = await render(state, "/settings/cloud?focus=card.cloudModels&provider=claude&open=picker");
  expect(panel()).toBeNull();
  const enable = document.querySelector('[data-value="setCloud"]')!;
  expect(enable.textContent).toBe("Use on Cloud");
  await click(enable);
  expect(rendered.provider.modelRuns).toEqual([{ action: "setCloud", id: "anthropic-key", on: true }]);
  expect(card(rendered).textContent).not.toContain("Not used on Cloud");
});

test("a saved endpoint stays visible while the Cloud harness is unconfirmed", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudHarnesses: [] },
    "/settings/models?focus=models.add.deepseek",
  );
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-endpoint-key");
  await click(panel()!.querySelector('[data-models-action="addEndpoint"]')!);
  await act(async () => rendered.history.push("/settings/cloud"));
  const endpoint = card(rendered).querySelector('[data-connection="deepseek"]')!;
  expect(endpoint.textContent).toContain("Not ready on Cloud yet");
  await act(async () => rendered.provider.setModels({ ...rendered.provider.models!, cloudHarnesses: ["opencode"] }));
  expect(card(rendered).querySelector('[data-connection="deepseek"]')).toBe(endpoint);
  expect(endpoint.textContent).not.toContain("Not ready on Cloud yet");
});

test("Cloud models shows an offline machine after its readiness deadline and clears the status on reconnect", async () => {
  const models = structuredClone(mockModels.empty);
  models.cloudSubscriptionRunnersPending = true;
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
    launchHarness: "opencode",
  });
  const rendered = await render(models);
  const row = card(rendered).querySelector('[data-connection="copilot-plan"]')!;
  expect(row.textContent).toContain("Updating Cloud machine");
  await act(async () =>
    rendered.provider.setModels({ ...models, cloudSubscriptionRunnersPending: false, cloudRunnersOffline: true }),
  );
  expect(row.textContent).toContain("Cloud machine offline");
  expect(row.textContent).not.toContain("Updating Cloud machine");
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      cloudSubscriptionRunnersPending: false,
      cloudSubscriptionHarnesses: ["opencode"],
    }),
  );
  expect(row.textContent).not.toContain("Cloud machine offline");
});

test("Cloud models waits for subscription capability even when OpenCode is installed", async () => {
  const models = structuredClone(mockModels.empty);
  models.cloudSubscriptionRunnersPending = true;
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
    launchHarness: "opencode",
  });
  const rendered = await render(models);
  const row = card(rendered).querySelector('[data-connection="copilot-plan"]');
  expect(row?.textContent).toContain("Updating Cloud machine");
  await act(async () =>
    rendered.provider.setModels({
      ...rendered.provider.models!,
      cloudSubscriptionHarnesses: ["opencode"],
      cloudSubscriptionRunnersPending: false,
    }),
  );
  expect(card(rendered).querySelector('[data-connection="copilot-plan"]')).toBe(row);
  expect(row?.textContent).not.toContain("Updating Cloud machine");
});

test.each(["models", "claude", "chatgpt", "api key"])("search offers Models first for %s", async (query) => {
  const rendered = await render(mockModels.empty, `/settings/cloud?q=${encodeURIComponent(query)}`);
  const first = rendered.container.querySelector("[data-search-results] [data-page-hit]")!;
  expect(first.getAttribute("data-page-hit")).toBe("models");
  await click(first);
  expect(rendered.history.location.pathname).toBe("/settings/models");
});

test.each(["claude", "chatgpt", "openai"])("an explicit Models add focus opens %s in Models", async (provider) => {
  const rendered = await render(mockModels.empty, `/settings/models?focus=models.add.${provider}&provider=${provider}`);
  expect(rendered.history.location.pathname).toBe("/settings/models");
  expect(panel()?.dataset.modelsDialog).toBe(provider);
});

test("Cloud endpoint Connect and Edit both explain why HTTP is disabled", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=cloudModels.add.endpoint");
  const assertInsecure = async () => {
    await changeValue(panel()!.querySelector('input[type="url"]')!, "http://localhost:1234/v1");
    expect(panel()?.querySelector('[data-models-action="addEndpoint"]')).toHaveProperty("disabled", true);
    expect(panel()?.querySelector('[role="alert"]')?.textContent).toContain("Use https.");
  };
  await assertInsecure();
  await act(async () => rendered.history.push("/settings/cloud?focus=cloudModels.add.deepseek"));
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-endpoint-key");
  await click(panel()!.querySelector('[data-models-action="addEndpoint"]')!);
  await click(card(rendered).querySelector('[data-menu="connection-deepseek"]')!);
  await click(document.querySelector('[data-value="edit"]')!);
  await assertInsecure();
});
