import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { context, providers } from "./fixtures/agentSessionContext";
import { installDomGlobals, pasteIntoPromptEditor, waitFor } from "./fixtures/agentSessionDom";
import type { AgentEvent } from "../src/agent-session/shared/types";

type Request = { method: string; params: Record<string, unknown> };

// Import after installing the browser surface, as WKWebView does at module load.
const dom = new JSDOM("<html><body><div id='root'></div></body></html>", { url: "file:///tmp/gui-mode.html" });
const restoreGlobals = installDomGlobals(dom);
const { AgentSessionApp } = await import("../src/agent-session/react/main");
const bridge = dom.window.cmuxAgentBridge!;
restoreGlobals();

async function mount(autoStart: boolean, write: (request: Request) => Promise<unknown> = async () => ({})) {
  const restore = installDomGlobals(dom);
  const previousActEnvironment = (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const requests: Request[] = [];
  (dom.window as any).webkit = { messageHandlers: { agentSession: {
    postMessage: async (request: Request) => {
      requests.push(request);
      let value: unknown = {};
      switch (request.method) {
        case "app.context": value = {
          ...context, renderer: "guiMode",
          guiMode: { selectedModelId: "custom-model", selectedReasoningEffort: "high",
            models: [{ id: "custom-model", displayName: "Custom model", providerId: "codex", reasoningEfforts: ["high"] }],
            providers: [
              { id: "codex", displayName: "Codex", accentColor: "#8ab4f8" },
              { id: "claude", displayName: "Claude Code", accentColor: "#d2a8ff" },
            ],
          },
        }; break;
        case "provider.list": value = providers.map((provider) => ({ ...provider, autoStart })); break;
        case "provider.start": value = { sessionId: "session-1" }; break;
        case "provider.writeLine": value = await write(request); break;
      }
      return { ok: true, value };
    },
  } } };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<AgentSessionApp />));
  await waitFor(() => requests.some((request) => request.method === "provider.list"));
  await waitFor(() => dom.window.document.querySelector(".ProseMirror") !== null);
  const event = (event: AgentEvent) => act(() => bridge.receive(event));
  return {
    requests, event,
    start: () => event({ type: "provider.started", providerId: "codex", sessionId: "session-1", executablePath: "codex", arguments: [] }),
    enter: () => act(() => dom.window.document.querySelector(".ProseMirror")!.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
    )),
    type: (text: string) => act(() => pasteIntoPromptEditor(dom, text)),
    sends: () => requests.filter((request) => request.method === "provider.writeLine"),
    cleanup: async () => {
      await act(async () => root.unmount());
      (globalThis as any).IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      restore();
    },
  };
}

test("fresh GUI send button starts the provider and submits once it is ready", async () => {
  const app = await mount(false);
  try {
    app.type("1+1");
    const button = dom.window.document.querySelector<HTMLButtonElement>(".send-button")!;
    expect(button.disabled).toBe(false);
    act(() => button.click());
    await waitFor(() => app.requests.some((request) => request.method === "provider.start"));
    expect(app.sends()).toHaveLength(0);
    app.start();
    await waitFor(() => app.sends().length === 1);
    expect(app.sends()[0].params).toMatchObject({ text: "1+1", modelId: "custom-model", reasoningEffort: "high" });
  } finally { await app.cleanup(); }
});

test("Enter during startup retains the prompt and sends it once after readiness", async () => {
  const app = await mount(true);
  try {
    await waitFor(() => app.requests.some((request) => request.method === "provider.start"));
    app.type("1+1"); app.enter(); app.enter();
    expect(app.sends()).toHaveLength(0);
    app.start();
    await waitFor(() => app.sends().length === 1);
    await waitFor(() => dom.window.document.querySelector(".ProseMirror")?.textContent === "");
    await waitFor(() => dom.window.document.querySelector(".gui-mode-thinking-indicator") !== null);
    app.event({ type: "provider.output", providerId: "codex", sessionId: "session-1", stream: "stdout", text: "2" });
    expect(dom.window.document.querySelector(".transcript")?.textContent ?? dom.window.document.body.textContent).toContain("2");
  } finally { await app.cleanup(); }
});

test("repeated Enter while the native send is pending does not submit twice", async () => {
  let accept!: () => void;
  const pending = new Promise<void>((resolve) => { accept = resolve; });
  const app = await mount(true, () => pending);
  try {
    await waitFor(() => app.requests.some((request) => request.method === "provider.start"));
    app.start(); app.type("1+1"); app.enter(); app.enter();
    expect(app.sends()).toHaveLength(1);
  } finally { await act(async () => { accept(); await pending; }); await app.cleanup(); }
});

test("GUI discovers model choices and sends the new model's supported reasoning effort", async () => {
  const app = await mount(true);
  try {
    app.start();
    app.event({ type: "provider.models", providerId: "codex", sessionId: "session-1", models: [
      { id: "custom-model", providerId: "codex", displayName: "Custom model", reasoningEfforts: ["high"] },
      { id: "new-model", providerId: "codex", displayName: "New model", reasoningEfforts: ["low", "medium"], defaultReasoningEffort: "medium" },
    ] });
    act(() => dom.window.document.querySelector<HTMLButtonElement>(".gui-mode-agent-model-trigger")!.click());
    const choice = [...dom.window.document.querySelectorAll<HTMLButtonElement>(".gui-mode-agent-model-option")]
      .find((button) => button.textContent === "New model")!;
    expect(choice).toBeTruthy();
    act(() => choice.click());
    app.type("1+1"); app.enter();
    expect(app.sends()[0].params).toMatchObject({ modelId: "new-model", reasoningEffort: "medium" });
    await act(async () => {});
  } finally { await app.cleanup(); }
});

test("GUI provider picker switches the agent before starting a session", async () => {
  const app = await mount(false);
  try {
    const picker = dom.window.document.querySelector<HTMLButtonElement>(".gui-mode-provider-button")!;
    expect(picker.textContent).toContain("Codex");
    act(() => picker.click());
    const claude = [...dom.window.document.querySelectorAll<HTMLButtonElement>(".gui-mode-provider-option")]
      .find((button) => button.textContent?.includes("Claude Code"));
    expect(claude).toBeTruthy();
    act(() => claude!.click());
    await waitFor(() => dom.window.document.querySelector(".gui-mode-provider-button")?.textContent?.includes("Claude Code") === true);
    expect(app.requests.some((request) => request.method === "provider.select" && request.params.providerId === "claude")).toBe(true);
  } finally { await app.cleanup(); }
});
