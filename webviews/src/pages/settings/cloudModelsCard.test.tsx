import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import modelsGallery from "./models.gallery";
import type { ModelsState } from "./ops";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, changeValue, click, fire, ops, settle } = await import("./testing");
const { createRoot } = await import("react-dom/client");
const { CloudSetupCard } = await import("../../agent-session/acpmux/conversation/CloudSetupCard");
const { waitForCloudSetUp } = await import("../../agent-session/acpmux/cloudSetup");
const { mockModels, runMockModels } = await import("./mockModels");
const { cloudReadiness } = await import("./components/CloudModelsCard");

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
const row = (rendered: Rendered, id: string) => card(rendered).querySelector<HTMLElement>(`[data-cloud-row="${id}"]`)!;
const statuses = (rendered: Rendered) =>
  Object.fromEntries(
    [...card(rendered).querySelectorAll<HTMLElement>("[data-cloud-row]")].map(({ dataset }) => [
      dataset.cloudRow,
      dataset.cloudStatus,
    ]),
  );
const ids = (rendered: Rendered) =>
  [...card(rendered).querySelectorAll<HTMLElement>("[data-connection]")].map((row) => row.dataset.connection);

test("Cloud models sits alongside Cloud Environments and Cloud Workspaces", async () => {
  const rendered = await render(mockModels.macLogins, "/settings/cloud");
  expect(card(rendered).querySelector("h3")?.textContent).toBe("Cloud models");
  expect(ids(rendered)).toEqual(["chatgpt", "claude-token"]);
  expect(rendered.container.querySelector("[data-models-catalog]")).toBeNull();
  expect(rendered.container.querySelector('[data-card="cloudEnvironments"]')).not.toBeNull();
  expect(rendered.container.textContent).toContain("Cloud Workspaces");
  expect(ops(rendered.provider, "cmux.settings.models.state")).toHaveLength(1);
});

test.each([
  ["claude", "Shared Claude key"],
  ["codex", "Shared Codex key"],
] as const)("Cloud Models shows a member's shared %s key without a personal connection", async (agent, label) => {
  const models: ModelsState = {
    ...mockModels.empty,
    organization: {
      team: { id: "team-acme", name: "Acme" },
      canEdit: false,
      keys: [{ agent, set: true, last4: null }],
    },
  };
  const rendered = await render(models);
  expect(card(rendered).textContent).toContain(label);
  expect(card(rendered).textContent).not.toContain("No connections yet");

  await act(async () =>
    rendered.provider.setModels({
      ...models,
      organization: { ...models.organization, keys: [{ agent, set: false, last4: null }] },
    }),
  );
  expect(card(rendered).textContent).not.toContain(label);
  expect(card(rendered).textContent).toContain("No connections yet");
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
});

test.each([
  ["cloud-endpoint-toggle-error", '[data-card="cloudModels"] [role="alert"]'],
  ["cloud-key-menu", '[data-value="setCloud"]'],
])("gallery variant %s reaches its Cloud Models state", async (name, result) => {
  const fixture = modelsGallery.variants[name]!;
  const rendered = (page = await renderPage({
    path: "/settings/cloud",
    closedMore: true,
    mock: fixture.options,
    setup: (provider) => {
      provider.models = structuredClone(fixture.models ?? null);
    },
  }));
  for (const step of fixture.steps ?? []) {
    const control = document.querySelector(step.selector);
    expect(control, step.selector).not.toBeNull();
    if (step.action === "click") await click(control!);
  }
  expect(document.querySelector(result)).not.toBeNull();
  expect(card(rendered).querySelector('[data-connection="openai-key"]')).not.toBeNull();
});

test.each([
  ["claude", "claude"],
  ["codex", "chatgpt"],
  ["gemini", "google"],
  ["grok", "xai"],
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

test("a targeted Claude visit hides another machine's row and signs out its own row", async () => {
  const models: ModelsState = {
    ...mockModels.empty,
    cloudClaudeLogin: { phase: "connected", signedIn: true, error: null, machine: "vm_a", machineName: "A" },
  };
  const rendered = await render(models, "/settings/models?provider=claude&machine=vm_b");
  expect(ids(rendered)).not.toContain("claude-cloud-login");
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      cloudClaudeLogin: { phase: "connected", signedIn: true, error: null, machine: "vm_b", machineName: "B" },
    }),
  );
  const row = card(rendered).querySelector('[data-connection="claude-cloud-login"]')!;
  await click(row.querySelector('[data-menu="connection-claude-cloud-login"]')!);
  await click(document.querySelector('[data-value="signOutClaude"]')!);
  expect(rendered.provider.modelRuns.filter((run) => run.action === "signOutClaude")).toEqual([
    { action: "signOutClaude", cloud: true, machine: "vm_b" },
  ]);
});

test("a refused Claude sign-out leaves the connection and shows the error in Cloud Models", async () => {
  const rendered = await render({
    ...mockModels.empty,
    cloudClaudeLogin: { phase: "connected", error: null, machine: "vm_b" },
  });
  rendered.provider.claudeSignOutRefused = true;
  await click(card(rendered).querySelector('[data-menu="connection-claude-cloud-login"]')!);
  await click(document.querySelector('[data-value="signOutClaude"]')!);
  expect(ids(rendered)).toContain("claude-cloud-login");
  expect(card(rendered).querySelector('[role="alert"]')?.textContent).toBe("Could not sign out of Claude Code.");
});

test.each([
  ["bad_code", "Enter the code from your browser."],
  ["expired", "The sign-in expired. Start again."],
])("a Claude reauthentication failure (%s) keeps the signed-in machine and its actions", async (error, message) => {
  const login = { phase: "connected", signedIn: true, error: null, machine: "vm_b", machineName: "Cloud VM" } as const;
  const rendered = await render({ ...mockModels.empty, cloudClaudeLogin: login });
  const menu = () => card(rendered).querySelector('[data-menu="connection-claude-cloud-login"]')!;
  await click(menu());
  await click(document.querySelector('[data-value="signInAgain"]')!);
  await click(panel()!.querySelector('[data-models-action="connectClaude"]')!);
  await act(async () =>
    rendered.provider.setModels({ ...mockModels.empty, cloudClaudeLogin: { ...login, phase: "code" } }),
  );
  await act(async () =>
    rendered.provider.setModels({ ...mockModels.empty, cloudClaudeLogin: { ...login, phase: "failed", error } }),
  );
  expect(panel()?.querySelector('[role="alert"]')?.textContent).toBe(message);
  expect(ids(rendered)).toContain("claude-cloud-login");
  await click(panel()!.querySelector(".models-dialog-close")!);
  await click(menu());
  await click(document.querySelector('[data-value="signOutClaude"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "signOutClaude", cloud: true, machine: "vm_b" });
});

test("reopening an explicit-machine link checks the same guest again", async () => {
  const path = "/settings/models?provider=claude&machine=vm_b&open=";
  const models = { ...mockModels.empty };
  const rendered = await render(models, path + "before");
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      cloudClaudeLogin: { phase: "disabled", error: "unsupported", machine: "vm_b" },
    }),
  );
  const connect = () => panel()?.querySelector<HTMLButtonElement>('[data-models-action="connectClaude"]');
  expect(connect()?.disabled).toBe(true);
  const checks = () =>
    ops(rendered.provider, "cmux.settings.models.run").filter(
      (run) => (run as { action?: string }).action === "checkClaudeLogin",
    );
  const before = checks().length;
  await act(async () => rendered.history.push(path + "after"));
  expect(checks().slice(before)).toEqual([{ action: "checkClaudeLogin", cloud: true, machine: "vm_b" }]);
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      cloudClaudeLogin: { phase: "idle", error: null, machine: "vm_b" },
    }),
  );
  expect(connect()?.disabled).toBe(false);
});

test("Cloud Models can turn a saved setup token off and back on", async () => {
  const rendered = await render(mockModels.claudeTokenOnly);
  const row = () => card(rendered).querySelector('[data-connection="claude-token"]')!;
  const toggle = () => row().querySelector('[role="switch"]')!;
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  await click(toggle());
  expect(toggle().getAttribute("aria-checked")).toBe("false");
  expect(row().textContent).toContain("Turned off");
  await click(toggle());
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  expect(rendered.provider.modelRuns).toEqual([
    { action: "enable", id: "claude-token", on: false },
    { action: "enable", id: "claude-token", on: true },
  ]);
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
    await click(chat.querySelector('[data-connect-action="begin"], [data-action="setUpClaude"]')!);
    expect(calls).toEqual([
      {
        method: "cloud.setUp",
        params: { key: "held-send", action: "setUpClaude", family: "claude" },
      },
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

test("ordinary Connect confirms an already signed-in target without showing its form", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "connected", error: null, machine: "vm_b" } },
    "/settings/models?provider=claude&machine=vm_b&fromSend=1&open=held",
  );
  expect(panel()).toBeNull();
  expect(card(rendered).querySelector("[data-cloud-connected]")?.textContent).toBe("Connected. Your chat is starting.");
});

test("Add a connection still opens the requested form after Claude is already connected", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "connected", error: null, machine: "vm_b" } },
    "/settings/models?provider=claude&machine=vm_b&open=connected",
  );
  expect(panel()).toBeNull();
  await click(card(rendered).querySelector("button[data-models-add]")!);
  await click(document.querySelector('[data-models-choice="google"]')!);
  expect(panel()?.dataset.modelsDialog).toBe("google");
});

test("the CLI can open Claude setup for its exact new machine name", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "connected", error: null, machine: "vm_a", machineName: "A" } },
    "/settings/models?provider=claude&machineName=New%20Claude&open=cli",
  );
  const submit = panel()?.querySelector<HTMLButtonElement>('button[type="submit"]');
  expect(submit?.disabled).toBe(false);
  await click(submit!);
  expect(rendered.provider.modelRuns).toContainEqual({
    action: "connectClaude",
    cloud: true,
    machineName: "New Claude",
  });
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
  expect(cloudReadiness(mockModels.macOnly, "apiKey")).toMatchObject({ state: "missing" });
  expect(cloudReadiness(mockModels.macLogins, "apiKey")).toMatchObject({ state: "ready" });
});

test("Connect Claude runs the one click in its row, with its progress line and Cancel", async () => {
  const rendered = await render(mockModels.macOnly);
  await click(row(rendered, "claude").querySelector('[data-cloud-action="connectClaudeToken"]')!);
  expect(rendered.provider.modelRuns.filter(({ action }) => action !== "checkClaudeLogin")).toEqual([
    { action: "connectClaudeToken" },
  ]);
  expect(panel()).toBeNull();
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
  const form = panel()!.querySelector<HTMLElement>("[data-models-claude-form]")!;
  expect(form.querySelector<HTMLDetailsElement>("[data-models-claude-paste]")!.open).toBe(true);
  await changeValue(form.querySelector<HTMLInputElement>('input[type="password"]')!, "sk-ant-oat01-secret0123456789");
  await click(form.querySelector('[data-models-action="addClaudeToken"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "addClaudeToken",
    token: "sk-ant-oat01-secret0123456789",
  });
  expect(panel()).toBeNull();
  expect(statuses(rendered).claude).toBe("ready");
  expect(document.body.innerHTML).not.toContain("sk-ant-oat01-secret");
});

test.each([true, false])(
  "a named Settings visit hides the old Claude connection (status succeeds: %s)",
  async (succeeds) => {
    const refresh = Promise.withResolvers<void>();
    const login = { phase: "connected", error: null, machine: "vm_a", machineName: "Named VM" } as const;
    const rendered = (page = await renderPage({
      path: "/settings/models?provider=claude&machineName=Named%20VM&open=cli",
      setup: (provider) => {
        provider.models = { ...mockModels.empty, cloudClaudeLogin: login };
        provider.holdNamedClaudeStatus = refresh.promise;
      },
    }));
    expect(ids(rendered)).not.toContain("claude-cloud-login");
    expect(panel()?.dataset.modelsDialog).toBe("claude");
    await act(async () => {
      if (succeeds) {
        rendered.provider.setModels({ ...mockModels.empty, cloudClaudeLogin: { ...login, machine: "vm_b" } });
        refresh.resolve();
      } else {
        refresh.reject(new Error("The status bridge is unavailable"));
      }
    });
    await settle();
    if (!succeeds) {
      expect(ids(rendered)).not.toContain("claude-cloud-login");
      expect(panel()?.dataset.modelsDialog).toBe("claude");
      return;
    }
    expect(ids(rendered)).toContain("claude-cloud-login");
    expect(panel()).toBeNull();
    await click(card(rendered).querySelector('[data-menu="connection-claude-cloud-login"]')!);
    await click(document.querySelector('[role="menuitem"][data-value="signOutClaude"]')!);
    expect(rendered.provider.modelRuns).toContainEqual({ action: "signOutClaude", cloud: true, machine: "vm_b" });
  },
);

test("a rejected Claude token can recover on an already signed-in target", async () => {
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { phase: "connected", error: null, machine: "vm_b" } },
    "/settings/models?provider=claude&machine=vm_b&recoverySession=chat-b&open=recovery",
  );
  const submit = panel()?.querySelector<HTMLButtonElement>('button[type="submit"]');
  expect(submit?.disabled).toBe(false);
  await click(submit!);
  expect(rendered.provider.modelRuns).toContainEqual({
    action: "connectClaude",
    cloud: true,
    machine: "vm_b",
    recoverySession: "chat-b",
  });
});

test("a recovery visit cannot submit a code to or close on another chat's sign-in", async () => {
  const route = (chat: string) => `/settings/models?provider=claude&machine=vm_b&recoverySession=${chat}&open=recovery`;
  const attempt = { machine: "vm_b", recoverySession: "chat-a", error: null };
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { ...attempt, phase: "code" } },
    route("chat-a"),
  );
  expect(panel()?.querySelector('input[type="password"]')).not.toBeNull();

  await act(async () => rendered.history.push(route("chat-b")));
  expect(panel()?.textContent).toContain("Another sign-in is in progress.");
  expect(panel()?.querySelector('input[type="password"]')).toBeNull();
  expect(panel()?.querySelector('button[type="submit"]')).toBeNull();
  await fire(panel()!.querySelector("h2")!, "keydown", { key: "Enter" });
  expect(rendered.provider.modelRuns).toEqual([]);

  await act(async () =>
    rendered.provider.setModels({
      ...mockModels.empty,
      cloudClaudeLogin: { ...attempt, phase: "connected", completion: "a-finished" },
    }),
  );
  const submit = panel()?.querySelector<HTMLButtonElement>('button[type="submit"]');
  expect(submit?.disabled).toBe(false);
  await click(submit!);
  expect(rendered.provider.modelRuns).toContainEqual({
    action: "connectClaude",
    cloud: true,
    machine: "vm_b",
    recoverySession: "chat-b",
  });
});

test("Claude Connect waits for a Cloud approval on another machine", async () => {
  const attempt = { machine: "vm_a", error: null };
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { ...attempt, phase: "approving" } },
    "/settings/models?provider=claude&machine=vm_b&open=second",
  );
  expect(panel()?.textContent).toContain("Another sign-in is in progress.");
  expect(panel()?.querySelector('button[type="submit"]')).toBeNull();
  await fire(panel()!.querySelector("h2")!, "keydown", { key: "Enter" });
  expect(rendered.provider.modelRuns).toEqual([]);

  await act(async () =>
    rendered.provider.setModels({ ...mockModels.empty, cloudClaudeLogin: { ...attempt, phase: "connected" } }),
  );
  const submit = panel()?.querySelector<HTMLButtonElement>('button[type="submit"]');
  expect(submit?.disabled).toBe(false);
  await click(submit!);
  expect(rendered.provider.modelRuns).toContainEqual({ action: "connectClaude", cloud: true, machine: "vm_b" });
});

test("the Cloud Claude dialog shows a prep failure for the requested environment and can retry after an update", async () => {
  const scope = { machine: "vm_b", environment: "env_b" };
  const rendered = await render(
    { ...mockModels.empty, cloudClaudeLogin: { ...scope, phase: "failed", error: "machine_start_failed" } },
    "/settings/models?provider=claude&machine=vm_b&environment=env_b&open=retry",
  );
  expect(panel()?.querySelector('[role="alert"]')?.textContent).toContain("Your Cloud machine did not start");
  await act(async () =>
    rendered.provider.setModels({
      ...mockModels.empty,
      cloudClaudeLogin: { ...scope, phase: "disabled", error: "update_claude" },
    }),
  );
  expect(panel()?.querySelector('[role="alert"]')?.textContent).toBe("Update Claude Code");
  const submit = panel()?.querySelector<HTMLButtonElement>('button[type="submit"]');
  expect(submit?.disabled).toBe(false);
  await click(submit!);
  expect(rendered.provider.modelRuns).toContainEqual({ action: "connectClaude", cloud: true, ...scope });
});

test("the Cloud Claude dialog shows a daemon busy refusal and still offers retry", async () => {
  await render(
    {
      ...mockModels.empty,
      cloudClaudeLogin: { machine: "vm_b", recoverySession: "chat-b", phase: "failed", error: "busy" },
    },
    "/settings/models?provider=claude&machine=vm_b&recoverySession=chat-b&open=busy",
  );
  expect(panel()?.querySelector('[role="alert"]')?.textContent).toContain("Another sign-in is in progress.");
  expect(panel()?.querySelector<HTMLButtonElement>('button[type="submit"]')?.disabled).toBe(false);
  expect(panel()?.querySelector('input[type="password"]')).toBeNull();
});

test("a Claude approval owned by another Settings window blocks Connect until it ends", async () => {
  const models = { ...mockModels.empty, cloudClaudeApprovalBusy: true };
  const rendered = await render(models, "/settings/models?provider=claude&machine=vm_b&open=busy");
  expect(panel()?.textContent).toContain("Another sign-in is in progress.");
  expect(panel()?.querySelector('button[type="submit"]')).toBeNull();
  await act(async () => rendered.provider.setModels({ ...models, cloudClaudeApprovalBusy: false }));
  expect(panel()?.querySelector<HTMLButtonElement>('button[type="submit"]')?.disabled).toBe(false);
});

test("Cloud Models can turn on a disabled API key", async () => {
  const models = structuredClone(mockModels.macLogins);
  const original = models.personal.connections.find((row) => row.id === "openrouter-key")!;
  models.personal.connections.push({
    ...original,
    id: "openai-key",
    provider: "openai",
    label: "OpenAI API key",
    families: ["codex"],
    servesCloud: true,
    canServeCloud: true,
  });
  const rendered = await render(models);
  const key = card(rendered).querySelector('[data-connection="openai-key"]')!;
  const turnOn = [...key.querySelectorAll("button")].find((button) => button.textContent === "Turn On")!;
  await click(turnOn);
  expect(rendered.provider.modelRuns).toEqual([{ action: "enable", id: "openai-key", on: true }]);
  expect(rendered.provider.models?.personal.connections.find((c) => c.id === "openai-key")?.enabled).toBe(true);
});

test.each(["openai", "google", "vertex-express", "xai"])(
  "a local %s key starts with Cloud use off",
  async (provider) => {
    const id = provider + "-key";
    const rendered = await render(mockModels.empty, `/settings/models?focus=models.add.${provider}`);
    await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-api-key");
    await click(panel()!.querySelector('[data-models-action="addKey"]')!);
    expect(rendered.provider.modelRuns.at(-1)).toMatchObject({
      action: "addKey",
      provider,
      servesCloud: false,
    });
    await act(async () => rendered.history.push("/settings/cloud"));
    const { credentialInstance, keyRevision: revision } = rendered.provider.models!.personal.connections.find(
      (c) => c.id === id,
    )!;
    const instance = credentialInstance ?? "";
    const keyRevision = revision ?? "";
    expect(instance).toBeTruthy();
    expect(keyRevision).toBeTruthy();
    const key = card(rendered).querySelector(`[data-connection="${id}"]`)!;
    const menu = () => key.querySelector(`[data-menu="connection-${id}"]`)!;
    expect(key.textContent).toContain("Off for new chats");
    await click(menu());
    expect(document.querySelector('[data-value="moveUp"]')).toBeNull();
    expect(document.querySelector('[data-value="moveDown"]')).toBeNull();
    expect(document.querySelector('[data-value="remove"]')).toBeNull();
    const use = document.querySelector('[data-value="setCloud"]')!;
    expect(use.textContent).toBe("Use on Cloud");
    await click(use);
    expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "setCloud", id, instance, keyRevision, on: true });
    expect(key.textContent).not.toContain("Off for new chats");
    await click(menu());
    const stop = document.querySelector('[data-value="setCloud"]')!;
    expect(stop.textContent).toBe("Stop using on Cloud");
    await click(stop);
    expect(rendered.provider.modelRuns.at(-1)).toEqual({ action: "setCloud", id, instance, keyRevision, on: false });
    expect(key.textContent).toContain(
      "Off for new chats. Older machines can keep using the key until their chats end.",
    );
    await act(async () => rendered.history.push("/settings/models"));
    const local = rendered.container.querySelector(`[data-card="models"] [data-connection="${id}"]`)!;
    await click(local.querySelector("[data-menu]")!);
    expect(local.textContent).toContain("API key");
    expect(document.querySelector('[data-value="setCloud"]')).toBeNull();
  },
);

test("Cloud models adds a key with Cloud use enabled", async () => {
  const rendered = await render(mockModels.empty, "/settings/cloud?focus=cloudModels.add.openai");
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-api-key");
  await click(panel()!.querySelector('[data-models-action="addKey"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toMatchObject({ action: "addKey", servesCloud: true });
  expect(card(rendered).querySelector('[data-connection="openai-key"]')?.textContent).toContain("API key");
});

test.each(["The provider refused the key (HTTP 401).", "the endpoint was not reached: check the base URL"])(
  "Cloud models lets a person save after the Mac's probe reports %s",
  async (failure) => {
    const rendered = (page = await renderPage({
      path: "/settings/cloud?focus=cloudModels.add.openai",
      mock: { modelAccess: { failure } },
      setup: (provider) => {
        provider.models = mockModels.empty;
      },
    }));
    const key = "fixture-api-key";
    await changeValue(panel()!.querySelector('input[type="password"]')!, key);
    const submit = () => panel()!.querySelector('[data-models-action="addKey"]')!;
    await click(submit());
    expect(panel()?.querySelector('[role="alert"]')?.textContent).toBe(failure);
    expect(submit().textContent).toContain("Save Without Verification");
    expect(ids(rendered)).toEqual([]);
    await click(submit());
    expect(panel()).toBeNull();
    expect(ids(rendered)).toEqual(["openai-key"]);
    expect(rendered.provider.modelRuns).toEqual(
      [true, false].map((verifyAccess) => ({
        action: "addKey",
        provider: "openai",
        key,
        verifyAccess,
        servesCloud: true,
      })),
    );
  },
);

test("Cloud Connect only offers providers that a guest can launch", async () => {
  const rendered = await render(mockModels.empty);
  await click(card(rendered).querySelector("button[data-models-add]")!);
  const choices = () =>
    [...document.querySelectorAll<HTMLElement>("[data-models-choice]")].map((row) => row.dataset.modelsChoice);
  expect(choices().sort((a, b) => (a ?? "").localeCompare(b ?? ""))).toEqual([
    "anthropic",
    "chatgpt",
    "claude",
    "google",
    "openai",
    "vertex-express",
    "xai",
  ]);
  const search = document.querySelector<HTMLInputElement>('input[role="combobox"]')!;
  for (const provider of ["OpenRouter", "DeepSeek", "Custom"]) {
    await changeValue(search, provider);
    expect(choices()).toEqual([]);
  }
});

test("Settings search opens the Cloud models card", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?q=cloud%20models");
  const result = rendered.container.querySelector('[data-page-hit="cloudModels"]')!;
  await click(result);
  expect(rendered.history.location.pathname).toBe("/settings/cloud");
  expect(rendered.history.location.search).toContain("card.cloudModels");
  expect(card(rendered).querySelector("h3")?.textContent).toBe("Cloud models");
});

test("Return takes the exact Cloud models title ahead of the local Models result", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?q=cloud%20models");
  await fire(rendered.container.querySelector("[data-settings-search]")!, "keydown", {
    key: "Enter",
  });
  expect(rendered.history.location.pathname).toBe("/settings/cloud");
  expect(rendered.history.location.search).toContain("card.cloudModels");
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
    credentialInstance: "fixture-anthropic",
    keyRevision: "fixture-anthropic-key",
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
  expect(rendered.provider.modelRuns).toEqual([
    {
      action: "setCloud",
      id: "anthropic-key",
      instance: "fixture-anthropic",
      keyRevision: "fixture-anthropic-key",
      on: true,
    },
  ]);
  expect(card(rendered).textContent).not.toContain("Not used on Cloud");
});

test.each(["new route", "in-place replacement"])(
  "a stale Cloud menu cannot opt a key in before the page refreshes after %s",
  async (replacement) => {
    const rendered = await render(mockModels.empty, "/settings/models?focus=models.add.google");
    await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-api-key");
    await click(panel()!.querySelector('[data-models-action="addKey"]')!);
    await act(async () => rendered.history.push("/settings/cloud"));
    const state = rendered.provider.models!;
    const saved = state.personal.connections.find((c) => c.id === "google-key")!;
    const instance = saved.credentialInstance ?? "";
    expect(instance).toBeTruthy();
    await click(card(rendered).querySelector('[data-menu="connection-google-key"]')!);
    const toggle = document.querySelector('[data-value="setCloud"]')!;
    // Change the mock host's state without delivering its update to the open menu yet.
    rendered.provider.models = {
      ...state,
      personal: {
        ...state.personal,
        connections: [
          {
            ...saved,
            credentialInstance: replacement === "new route" ? "replacement" : instance,
            keyRevision: "replacement-key",
          },
        ],
      },
    };
    await click(toggle);
    expect(rendered.provider.models.personal.connections[0]?.servesCloud).toBe(false);
    expect(rendered.provider.modelRuns.at(-1)).toEqual({
      action: "setCloud",
      id: saved.id,
      instance,
      keyRevision: saved.keyRevision ?? "",
      on: true,
    });
    expect(card(rendered).querySelector('[role="alert"]')).not.toBeNull();
    expect(document.querySelector('[data-value="setCloud"]')).toBeNull();
  },
);

test("refreshing Cloud Models after in-place key replacement closes the open consent menu", async () => {
  const rendered = await render(mockModels.empty, "/settings/models?focus=models.add.google");
  await changeValue(panel()!.querySelector('input[type="password"]')!, "fixture-api-key");
  await click(panel()!.querySelector('[data-models-action="addKey"]')!);
  await act(async () => rendered.history.push("/settings/cloud"));
  const state = rendered.provider.models!;
  const saved = state.personal.connections.find((c) => c.id === "google-key")!;
  const menu = () => card(rendered).querySelector('[data-menu="connection-google-key"]')!;
  await click(menu());
  expect(document.querySelector('[data-value="setCloud"]')).not.toBeNull();

  await act(async () =>
    rendered.provider.setModels({
      ...state,
      personal: { ...state.personal, connections: [{ ...saved, keyRevision: "replacement-key" }] },
    }),
  );
  expect(document.querySelector('[data-value="setCloud"]')).toBeNull();
  await click(menu());
  await click(document.querySelector('[data-value="setCloud"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "setCloud",
    id: saved.id,
    instance: saved.credentialInstance ?? "",
    keyRevision: "replacement-key",
    on: true,
  });
});

test("saved OpenRouter and endpoint rows stay local even with stale Cloud readiness", async () => {
  const models = structuredClone(mockModels.macLogins);
  const router = models.personal.connections.find((row) => row.id === "openrouter-key")!;
  router.servesCloud = true;
  router.canServeCloud = true;
  models.personal.connections.push({
    ...router,
    id: "deepseek",
    provider: "deepseek",
    kind: "endpoint",
    label: "DeepSeek",
    launchHarness: "opencode",
  });
  const rendered = await render(models);
  expect(ids(rendered)).toEqual(["chatgpt", "claude-token"]);
  await act(async () => rendered.history.push("/settings/models"));
  for (const id of ["openrouter-key", "deepseek"]) {
    expect(rendered.container.querySelector(`[data-card="models"] [data-connection="${id}"]`)).not.toBeNull();
  }
});

test("Cloud models shows an offline machine after its readiness deadline and clears the status on reconnect", async () => {
  const models = structuredClone(mockModels.empty);
  models.cloudEndpointRunnersPending = true;
  models.cloudHarnesses = [];
  models.personal.connections.push({
    id: "xai-key",
    label: "xAI API key",
    provider: "xai",
    kind: "api-key",
    families: ["grok"],
    enabled: true,
    signedIn: true,
    servesCloud: true,
    defaultFor: [],
    email: null,
    plan: null,
    launchHarness: "grok",
  });
  const rendered = await render(models);
  const row = card(rendered).querySelector('[data-connection="xai-key"]')!;
  expect(row.textContent).toContain("Updating Cloud machine");
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      cloudEndpointRunnersPending: false,
      cloudRunnersOffline: true,
    }),
  );
  expect(row.textContent).toContain("Cloud machine offline");
  expect(row.textContent).not.toContain("Updating Cloud machine");
  await act(async () =>
    rendered.provider.setModels({
      ...models,
      cloudEndpointRunnersPending: false,
      cloudHarnesses: ["grok"],
    }),
  );
  expect(row.textContent).not.toContain("Cloud machine offline");
});

test("local-only plans stay in Models when a stale list advertises them for Cloud", async () => {
  const models = structuredClone(mockModels.empty);
  for (const [kind, provider, family, label] of [
    ["grok-plan", "grok", "grok", "SuperGrok"],
    ["copilot-plan", "copilot", "github-copilot", "GitHub Copilot"],
    ["kimi-plan", "kimi-code", "opencode", "Kimi Code"],
  ] as const) {
    models.personal.connections.push({
      id: kind,
      kind,
      provider,
      label,
      families: [family],
      enabled: true,
      signedIn: true,
      servesCloud: true,
      canServeCloud: true,
      defaultFor: [],
      email: null,
      plan: null,
    });
  }
  const rendered = await render(models);
  expect(ids(rendered)).toEqual([]);
  await act(async () => rendered.history.push("/settings/models"));
  for (const kind of ["grok-plan", "copilot-plan", "kimi-plan"]) {
    expect(rendered.container.querySelector(`[data-card="models"] [data-connection="${kind}"]`)).not.toBeNull();
  }
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

test.each(["endpoint", "deepseek", "openrouter"])("Cloud Add links do not open the local %s form", async (provider) => {
  const rendered = await render(mockModels.empty, `/settings/cloud?focus=cloudModels.add.${provider}`);
  expect(panel()).toBeNull();
  expect(card(rendered).querySelector("[data-cloud-coming-soon]")).not.toBeNull();
  expect(rendered.provider.modelRuns).toEqual([]);
});

test("a named Cloud connection link lands on its summary row", async () => {
  const rendered = await render(mockModels.macOnly, "/settings/connections?focus=chatgpt");
  expect(panel()).toBeNull();
  expect(row(rendered, "chatgpt")).not.toBeNull();
  expect(rendered.container.querySelector(".link-missing")).toBeNull();
});

test("a signed-out Cloud ChatGPT plan opens device sign-in for that plan", async () => {
  const rendered = await render(mockModels.chatgptSignedOut);
  await click(row(rendered, "chatgpt").querySelector('[data-cloud-action="connectChatGPT"]')!);
  await click(panel()!.querySelector('[data-models-action="connectChatGPTDevice"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "connectChatGPTDevice",
    id: "chatgpt",
    openBrowser: true,
  });
});

test("the Cloud API key shortcut opens the shared credential dialog", async () => {
  const rendered = await render(mockModels.macOnly);
  await click(row(rendered, "apiKey").querySelector('[data-menu="cloud-api-key"]')!);
  await click(document.querySelector('[role="menuitem"][data-value="anthropic"]')!);
  expect(panel()?.dataset.modelsDialog).toBe("anthropic");
});

test("the Cloud key shortcut confirms Disconnect against the saved instance", async () => {
  const models = runMockModels(mockModels.empty, {
    action: "addKey",
    provider: "openai",
    key: "fixture-key",
    servesCloud: true,
  });
  const key = models.personal.connections[0]!;
  const rendered = await render(models);
  await click(row(rendered, "apiKey").querySelector('[data-menu="cloud-connection-openai-key"]')!);
  await click(document.querySelector('[role="menuitem"][data-value="remove"]')!);
  const dialog = panel()!;
  expect(dialog.dataset.modelsDialog).toBe("disconnect");
  const replacement = { ...key, credentialInstance: "replacement" };
  await act(async () =>
    rendered.provider.setModels({ ...models, personal: { ...models.personal, connections: [replacement] } }),
  );
  await click(dialog.querySelector('button[type="submit"]')!);
  expect(rendered.provider.modelRuns.at(-1)).toEqual({
    action: "remove",
    id: key.id,
    instance: key.credentialInstance ?? null,
  });
  expect(ids(rendered)).toEqual(["openai-key"]);
  expect(panel()?.querySelector('[role="alert"]')).not.toBeNull();
});
