import { afterEach, expect, test } from "bun:test";
import React from "react";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { SessionSurface } from "./main";
import styles from "../shared/styles.css" with { type: "text" };
import type { Action, SessionState } from "../shared/sessionModel";
import type { AgentSessionCopy, AgentSessionTheme, ProviderInfo } from "../shared/types";

let dom: JSDOM | null = null;
let root: Root | null = null;

const originalGlobals = new Map<string, any>();
for (
  const key of [
    "window",
    "document",
    "navigator",
    "Element",
    "Node",
    "HTMLElement",
    "MutationObserver",
    "getSelection",
  ]
) {
  originalGlobals.set(key, (globalThis as any)[key]);
}

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

test("multiline composer keeps the editor area from flex-growing past the footer anchor", () => {
  dom = createDom();
  installDomGlobals(dom);
  installStyles(dom);

  renderSurface({
    context: {
      copy: copyFixture(),
      initialProviderId: "codex",
      panelId: "panel-1",
      renderer: "react",
      theme: themeFixture(),
      workspaceId: "workspace-1",
    },
    input: "first line\nsecond line",
    providers: [codexProvider()],
    runningSessionId: "session-1",
    selectedProviderId: "codex",
    status: "running",
  });

  const inputArea = dom.window.document.querySelector<HTMLElement>(".codex-composer-input-area");
  const inner = dom.window.document.querySelector<HTMLElement>(".codex-composer-inner");
  const footer = dom.window.document.querySelector<HTMLElement>(".composer-footer");

  expect(inputArea).toBeTruthy();
  expect(inner).toBeTruthy();
  expect(footer).toBeTruthy();
  expect(inputArea?.className).not.toContain("flex-grow");
  expect(dom.window.getComputedStyle(inputArea!).flexGrow).toBe("0");
  expect(dom.window.getComputedStyle(inner!).justifyContent).toBe("flex-end");
  expect(inputArea!.compareDocumentPosition(footer!) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});

function createDom(): JSDOM {
  return new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/agent-session",
  });
}

function installDomGlobals(nextDom: JSDOM): void {
  (globalThis as any).window = nextDom.window;
  (globalThis as any).document = nextDom.window.document;
  (globalThis as any).navigator = nextDom.window.navigator;
  (globalThis as any).Element = nextDom.window.Element;
  (globalThis as any).Node = nextDom.window.Node;
  (globalThis as any).HTMLElement = nextDom.window.HTMLElement;
  (globalThis as any).MutationObserver = nextDom.window.MutationObserver;
  (globalThis as any).getSelection = nextDom.window.getSelection.bind(nextDom.window);
}

function installStyles(nextDom: JSDOM): void {
  const style = nextDom.window.document.createElement("style");
  style.textContent = styles as unknown as string;
  nextDom.window.document.head.append(style);
}

function renderSurface(overrides: Partial<SessionState>): void {
  const container = dom?.window.document.getElementById("root");
  expect(container).toBeTruthy();
  root = createRoot(container!);
  const state: SessionState = {
    autoStartAttemptedProviderIds: [],
    input: "",
    log: [],
    providers: [],
    seenSessionIds: [],
    selectedProviderId: "codex",
    status: "loading",
    transcript: [],
    ...overrides,
  };
  const dispatch = (_action: Action) => {};
  flushSync(() => {
    root?.render(React.createElement(SessionSurface, { dispatch, renderer: "React", state }));
  });
}

function codexProvider(): ProviderInfo {
  return {
    arguments: [],
    autoStart: false,
    displayName: "Codex",
    executableName: "codex",
    id: "codex",
    transportKind: "stdio-jsonrpc",
  };
}

function themeFixture(): AgentSessionTheme {
  return {
    accent: "#8cf",
    accentSoft: "#345",
    border: "#333",
    borderStrong: "#444",
    danger: "#f66",
    inputBackground: "rgba(8, 10, 8, 0.36)",
    isDark: true,
    mutedText: "#888",
    pageBackground: "#111",
    shadow: "rgba(0, 0, 0, 0.2)",
    softText: "#aaa",
    surfaceBackground: "#181818",
    surfaceElevatedBackground: "#222",
    text: "#eee",
  };
}

function copyFixture(): AgentSessionCopy {
  return {
    addFilesAndMore: "Add files and more",
    addPhotosAndFiles: "Add photos and files",
    attachFile: "Attach file",
    autoContext: "Auto context",
    browseWeb: "Browse web",
    changePermissions: "Change permissions",
    collapseShell: "Collapse shell",
    composerNoResults: "No results",
    copiedAssistantMessage: "Copied assistant message",
    copiedShellContents: "Copied shell contents",
    copiedUserMessage: "Copied user message",
    copyAssistantMessage: "Copy assistant message",
    copyOutput: "Copy output",
    copyShellContents: "Copy shell contents",
    copyUserMessage: "Copy user message",
    failedStatus: "Failed",
    ideContext: "IDE context",
    idleStatus: "Idle",
    includeIdeContext: "Include IDE context",
    loadingStatus: "Loading",
    mentionCurrentWorkspace: "Current workspace",
    mentionMenuTitle: "Mention",
    permissionsAutoReview: "Auto review",
    permissionsCustom: "Custom",
    permissionsDefault: "Default",
    permissionsFullAccess: "Full access",
    planMode: "Plan mode",
    planSuggestionAction: "Use plan",
    planSuggestionDismiss: "Dismiss",
    planSuggestionShortcut: "Shortcut",
    planSuggestionTitle: "Plan this first",
    promptPlaceholder: "Ask Codex",
    provider: "Provider",
    providerExitedFormat: "Provider exited",
    providerStarted: "Provider started",
    rateLimitDaysFormat: "%d days",
    rateLimitHoursFormat: "%d hours",
    rateLimitMinutesFormat: "%d minutes",
    rateLimitMonthly: "Monthly",
    rateLimitPrimary: "Primary",
    rateLimitResets: "Resets",
    rateLimitSecondary: "Secondary",
    rateLimits: "Rate limits",
    rateLimitUsageRemaining: "Usage remaining",
    rateLimitWeekly: "Weekly",
    reasoningEffortHigh: "High",
    rendererReadyFormat: "Renderer ready",
    removeAttachment: "Remove attachment",
    requestFailed: "Request failed",
    runningStatus: "Running",
    send: "Send",
    sentCharsFormat: "Sent %d chars",
    shellLabel: "Shell",
    shellSuccess: "Shell success",
    showLess: "Show less",
    showMore: "Show more",
    skillCodeReview: "Code review",
    skillMenuTitle: "Skill",
    skillPlan: "Plan",
    skillResearch: "Research",
    start: "Start",
    startingStatus: "Starting",
    stop: "Stop",
    stopped: "Stopped",
    stoppingStatus: "Stopping",
    tools: "Tools",
    voiceInput: "Voice input",
  };
}
