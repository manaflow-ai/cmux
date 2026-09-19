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
        case "provider.writeLine":
        case "guiMode.executeTerminal": value = await write(request); break;
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

test("Terminal mode runs inline, updates the GUI directory and keeps a separate chat draft", async () => {
  const app = await mount(false, async () => ({ workingDirectory: "/tmp/Project One", output: "/tmp/Project One\n", exitCode: 0 }));
  try {
    app.type("Chat draft");
    const mode = (name: string) => [...dom.window.document.querySelectorAll<HTMLButtonElement>("[role=tab]")].find((tab) => tab.textContent === name)!;
    act(() => mode("Terminal").click());
    expect(dom.window.document.querySelector(".ProseMirror")?.textContent).toBe("");
    expect(dom.window.document.querySelector(".gui-mode-agent-model-trigger") === null).toBe(true);
    expect(dom.window.document.querySelector(".permissions-root") === null).toBe(true);
    app.type("cd '/tmp/Project One' && pwd"); app.enter(); app.enter();
    await waitFor(() => dom.window.document.querySelector(".gui-mode-agent-context-strip")?.textContent?.includes("Project One") === true);
    expect(app.requests.filter((request) => request.method === "guiMode.executeTerminal").length).toBe(1);
    expect(dom.window.document.querySelector(".gui-mode-terminal-result")?.textContent).toContain("/tmp/Project One");
    act(() => mode("Chat").click());
    expect(dom.window.document.querySelector(".ProseMirror")?.textContent).toBe("Chat draft");
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

test("GUI working indicator survives commentary and tools and ends with the turn", async () => {
  const app = await mount(true);
  try {
    app.start(); app.type("Check the project"); app.enter();
    await waitFor(() => dom.window.document.querySelector(".ProseMirror")?.textContent === "");
    app.event({ type: "provider.output", providerId: "codex", sessionId: "session-1", stream: "stdout", text: "I’ll check." });
    app.event({ type: "provider.activity", providerId: "codex", sessionId: "session-1", activityId: "tool-1", kind: "command", status: "inProgress", action: "Running", detail: "pwd" });
    expect(dom.window.document.querySelector(".gui-mode-thinking-indicator")).not.toBeNull();
    expect(dom.window.document.querySelector<HTMLButtonElement>(".send-button")?.disabled).toBe(true);
    app.event({ type: "provider.turnComplete", providerId: "codex", sessionId: "session-1" });
    expect(dom.window.document.querySelector(".gui-mode-thinking-indicator")).toBeNull();
    app.type("Follow up"); app.enter();
    await waitFor(() => app.sends().length === 2);
    await waitFor(() => dom.window.document.querySelector(".ProseMirror")?.textContent === "");
    app.event({ type: "provider.turnComplete", providerId: "codex", sessionId: "session-1" });
    expect(dom.window.document.querySelector(".gui-mode-thinking-indicator")).toBeNull();
  } finally { await app.cleanup(); }
});

test("GUI keeps stderr in diagnostics while showing actionable failures", async () => {
  const app = await mount(true, async () => { throw new Error("Could not send this message."); });
  try {
    app.start();
    app.event({ type: "provider.output", providerId: "codex", sessionId: "session-1", stream: "stderr", text: "\u001b[31mfailed to load models cache: missing field base_instructions" });
    expect(dom.window.document.body.textContent).not.toContain("base_instructions");
    app.type("Please help"); app.enter();
    await waitFor(() => dom.window.document.body.textContent?.includes("Could not send this message.") === true);
    expect(dom.window.document.querySelector(".ProseMirror")?.textContent).toBe("Please help");
  } finally { await app.cleanup(); }
});

test("GUI model menu escapes the composer clipping boundary and Escape restores focus", async () => {
  const app = await mount(false);
  try {
    const trigger = dom.window.document.querySelector<HTMLButtonElement>(".gui-mode-agent-model-trigger")!;
    act(() => trigger.click());
    const menu = dom.window.document.querySelector<HTMLElement>(".gui-mode-agent-model-menu")!;
    expect(menu).not.toBeNull();
    expect(menu.closest(".codex-composer-surface") === null).toBe(true);
    act(() => menu.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })));
    expect(dom.window.document.querySelector(".gui-mode-agent-model-menu")).toBeNull();
    expect(dom.window.document.activeElement === trigger).toBe(true);
  } finally { await app.cleanup(); }
});
