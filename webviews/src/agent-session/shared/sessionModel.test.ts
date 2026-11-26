import { expect, test } from "bun:test";
import { makeClientId } from "./ids";
import {
  autoStartProvider,
  canSelectProvider,
  canStopProvider,
  formatTemplate,
  initialState,
  messageForError,
  reduceSession,
  sendInput,
  shouldAutoStartProvider,
  statusLabel,
  type Action,
} from "./sessionModel";
import type { AppContext, ProviderInfo } from "./types";

const theme = {
  isDark: true,
  pageBackground: "transparent",
  surfaceBackground: "rgba(0, 0, 0, 0.3)",
  surfaceElevatedBackground: "rgba(0, 0, 0, 0.4)",
  inputBackground: "rgba(0, 0, 0, 0.2)",
  border: "rgba(255, 255, 255, 0.1)",
  borderStrong: "rgba(255, 255, 255, 0.2)",
  text: "rgba(255, 255, 255, 1)",
  mutedText: "rgba(255, 255, 255, 0.6)",
  softText: "rgba(255, 255, 255, 0.8)",
  accent: "rgba(138, 180, 248, 1)",
  accentSoft: "rgba(138, 180, 248, 0.2)",
  danger: "rgba(255, 141, 126, 1)",
  shadow: "rgba(0, 0, 0, 0.2)",
};

const context: AppContext = {
  panelId: "panel-1",
  workspaceId: "workspace-1",
  renderer: "react",
  initialProviderId: "codex",
  copy: {
    start: "Start",
    stop: "Stop",
    send: "Send",
    provider: "Provider",
    rateLimits: "Rate limits",
    rateLimitUsageRemaining: "Usage remaining",
    rateLimitPrimary: "Primary",
    rateLimitSecondary: "Secondary",
    rateLimitWeekly: "Weekly",
    rateLimitMonthly: "Monthly",
    rateLimitDaysFormat: "%@d",
    rateLimitHoursFormat: "%@h",
    rateLimitMinutesFormat: "%@m",
    rateLimitResets: "resets",
    voiceInput: "Voice input",
    promptPlaceholder: "Ask anything",
    attachFile: "Attach file",
    addFilesAndMore: "Add files and more",
    addPhotosAndFiles: "Add photos & files",
    removeAttachment: "Remove attachment",
    copyOutput: "Copy output",
    copyAssistantMessage: "Copy",
    copiedAssistantMessage: "Copied",
    copyUserMessage: "Copy message",
    copiedUserMessage: "Copied",
    shellLabel: "Shell",
    copyShellContents: "Copy shell contents",
    copiedShellContents: "Copied shell contents",
    collapseShell: "Collapse shell",
    shellSuccess: "Success",
    showMore: "Show more",
    showLess: "Show less",
    browseWeb: "Browse web",
    autoContext: "Context",
    includeIdeContext: "Include IDE context",
    ideContext: "IDE context",
    tools: "Tools",
    changePermissions: "Change permissions",
    permissionsDefault: "Default permissions",
    permissionsFullAccess: "Full access",
    permissionsAutoReview: "Auto-review",
    permissionsCustom: "Custom (config.toml)",
    reasoningEffortHigh: "High",
    mentionMenuTitle: "Mention",
    mentionCurrentWorkspace: "Current workspace",
    skillMenuTitle: "Skills",
    composerNoResults: "No results",
    planMode: "Plan mode",
    planSuggestionAction: "Use plan mode",
    planSuggestionDismiss: "Dismiss suggestion",
    planSuggestionShortcut: "Shift + Tab",
    planSuggestionTitle: "Create a plan",
    skillPlan: "Plan",
    skillCodeReview: "Code review",
    skillResearch: "Research",
    loadingStatus: "Loading",
    idleStatus: "Idle",
    startingStatus: "Starting",
    runningStatus: "Running",
    stoppingStatus: "Stopping",
    failedStatus: "Failed",
    rendererReadyFormat: "%@ ready",
    stopped: "Stopped",
    sentCharsFormat: "Sent %d chars",
    providerStarted: "Provider started",
    providerExitedFormat: "Provider exited %d",
    requestFailed: "Native bridge request failed.",
  },
  theme,
};

const providers: ProviderInfo[] = [
  {
    id: "codex",
    displayName: "Codex",
    executableName: "codex",
    transportKind: "stdio-jsonrpc",
    arguments: ["app-server", "--listen", "stdio://"],
    autoStart: true,
  },
  {
    id: "claude",
    displayName: "Claude Code",
    executableName: "claude",
    transportKind: "stdio-jsonl",
    arguments: ["-p"],
    autoStart: false,
  },
];

test("provider started event records running session", () => {
  const starting = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "starting" },
  );
  const state = reduceSession(starting, {
    type: "event",
    event: {
      type: "provider.started",
      providerId: "codex",
      sessionId: "session-1",
      executablePath: "/usr/local/bin/codex",
      arguments: ["app-server", "--listen", "stdio://"],
    },
  });

  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.log.at(-1)?.text).toBe("Provider started");
});

test("rate limit row event updates context", () => {
  const initial = reduceSession(initialState("react"), { type: "context", context });
  const state = reduceSession(initial, {
    type: "event",
    event: {
      type: "app.rateLimitRows",
      rateLimitRows: [
        {
          role: "primary",
          remainingPercent: 42,
          resetsAt: 1_850_000_000,
        },
      ],
    },
  });

  expect(state.context?.rateLimitRows).toEqual([
    {
      role: "primary",
      remainingPercent: 42,
      resetsAt: 1_850_000_000,
    },
  ]);
});

test("provider output is appended without changing running session", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "claude",
      sessionId: "session-1",
      stream: "stdout",
      text: "{\"type\":\"assistant\"}",
    },
  });

  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.log.at(-1)?.level).toBe("stdout");
  expect(state.transcript.at(-1)).toMatchObject({
    isComplete: false,
    role: "assistant",
    sessionId: "session-1",
    sentAtMs: expect.any(Number),
    text: "{\"type\":\"assistant\"}",
  });
});

test("provider output log entries are byte bounded", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "a".repeat(1024 * 1024),
    },
  });

  const logText = state.log.at(-1)?.text ?? "";
  expect(logText.length).toBeLessThanOrEqual(8 * 1024);
  expect(logText.startsWith("[earlier log output truncated]\n")).toBe(true);
});

test("provider stdout deltas append to the current assistant transcript turn", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const first = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "hello",
    },
  });
  const second = reduceSession(first, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: " world",
    },
  });

  expect(second.transcript).toHaveLength(1);
  expect(second.transcript[0]).toMatchObject({
    isComplete: false,
    role: "assistant",
    sentAtMs: first.transcript[0]?.sentAtMs,
    text: "hello world",
  });
});

test("provider turn completion marks the active assistant transcript complete", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const withOutput = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "done",
    },
  });
  const completed = reduceSession(withOutput, {
    type: "event",
    event: {
      type: "provider.turnComplete",
      providerId: "codex",
      sessionId: "session-1",
    },
  });

  expect(completed.status).toBe("running");
  expect(completed.runningSessionId).toBe("session-1");
  expect(completed.transcript[0]).toMatchObject({
    isComplete: true,
    role: "assistant",
    text: "done",
  });
});

test("provider exit marks assistant transcript complete", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const withOutput = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "done",
    },
  });
  const exited = reduceSession(withOutput, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 0,
    },
  });

  expect(exited.transcript[0]).toMatchObject({
    isComplete: true,
    role: "assistant",
    text: "done",
  });
});

test("provider activity updates a single transcript turn by activity id", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const started = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
      detail: "bun test",
    },
  });
  const withOutput = reduceSession(started, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
      outputDelta: "ok\\n",
    },
  });
  const completed = reduceSession(withOutput, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "completed",
      action: "Ran",
      detail: "bun test",
    },
  });

  expect(completed.transcript).toHaveLength(1);
  expect(completed.transcript[0]).toMatchObject({
    role: "activity",
    text: "Ran",
    detail: "bun test",
    output: "ok\\n",
    activityKind: "command",
    activityStatus: "completed",
  });
});

test("provider activity output is retained with a bounded tail", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const started = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
    },
  });
  const first = reduceSession(started, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
      outputDelta: "a".repeat(70_000),
    },
  });
  const second = reduceSession(first, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "completed",
      action: "Ran",
      outputDelta: "tail",
    },
  });

  const output = second.transcript[0]?.output ?? "";
  expect(output.length).toBeLessThanOrEqual(64 * 1024);
  expect(output.startsWith("[earlier command output truncated]\n")).toBe(true);
  expect(output.endsWith("tail")).toBe(true);
});

test("sent action appends a user transcript turn", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
    input: "hello codex",
  };
  const state = reduceSession(running, {
    type: "sent",
    sessionId: "session-1",
    sentAtMs: 1_850_000_000_000,
    text: "hello codex",
    submittedInput: "hello codex",
  });

  expect(state.input).toBe("");
  expect(state.transcript.at(-1)).toMatchObject({
    role: "user",
    sentAtMs: 1_850_000_000_000,
    text: "hello codex",
  });
});

test("sent action keeps displayed attachments separate from provider prompt text", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
    input: "describe this",
  };
  const attachment = {
    id: "attachment-1",
    kind: "image" as const,
    label: "moon.jpeg",
    path: "/tmp/moon.jpeg",
    dataUrl: "data:image/jpeg;base64,abc",
  };
  const state = reduceSession(running, {
    type: "sent",
    attachments: [attachment],
    displayText: "describe this",
    sessionId: "session-1",
    text: "[moon.jpeg](/tmp/moon.jpeg)\n\ndescribe this",
    submittedInput: "describe this",
  });

  expect(state.input).toBe("");
  expect(state.log.at(-1)?.text).toBe("Sent 42 chars");
  expect(state.transcript.at(-1)).toMatchObject({
    role: "user",
    text: "describe this",
    attachments: [attachment],
  });
});

test("stderr output appends a warning notice transcript turn", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stderr",
      text: "warning text",
    },
  });

  expect(state.transcript.at(-1)).toMatchObject({
    role: "notice",
    tone: "warning",
    text: "warning text",
  });
});

test("provider output for a different session is ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "claude",
      sessionId: "session-x",
      stream: "stdout",
      text: "{\"type\":\"assistant\"}",
    },
  });

  expect(state).toBe(running);
});

test("unknown provider events are ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: { type: "provider.unknown", sessionId: "session-1" } as never,
  });

  expect(state).toBe(running);
});

test("accepted start reply tracks session before provider started event", () => {
  const starting = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "starting" },
  );
  const accepted = reduceSession(starting, { type: "startAccepted", sessionId: "session-1" });

  expect(accepted.status).toBe("starting");
  expect(accepted.runningSessionId).toBe("session-1");
  expect(canStopProvider(accepted)).toBe(true);

  const failed = reduceSession(accepted, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "opencode",
      sessionId: "session-1",
      status: 1,
    },
  });

  expect(failed.status).toBe("failed");
  expect(failed.runningSessionId).toBeUndefined();
});

test("provider exit during pending start is applied before start reply", () => {
  const starting = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "starting" },
  );
  const failed = reduceSession(starting, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-early-exit",
      status: 1,
    },
  });

  expect(failed.status).toBe("failed");
  expect(failed.runningSessionId).toBeUndefined();
  expect(failed.log.at(-1)?.text).toBe("Provider exited 1");

  const staleAccepted = reduceSession(failed, { type: "startAccepted", sessionId: "session-early-exit" });
  expect(staleAccepted.status).toBe("failed");
  expect(staleAccepted.runningSessionId).toBeUndefined();
});

test("stale exit from a previous seen session is ignored during pending start", () => {
  const loaded = reduceSession(initialState("react"), { type: "context", context });
  const firstStart = reduceSession(loaded, { type: "starting" });
  const accepted = reduceSession(firstStart, { type: "startAccepted", sessionId: "session-1" });
  const exited = reduceSession(accepted, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 0,
    },
  });
  const restarting = reduceSession(exited, { type: "starting" });
  const state = reduceSession(restarting, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 1,
    },
  });

  expect(state).toBe(restarting);
  expect(state.status).toBe("starting");
});

test("provider exit for a different session is ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "claude",
      sessionId: "session-x",
      status: 143,
    },
  });

  expect(state).toBe(running);
});

test("auto start is enabled for idle auto-start providers after context and providers load", () => {
  const stateWithContext = reduceSession(initialState("react"), { type: "context", context });
  const state = reduceSession(stateWithContext, { type: "providers", providers });

  expect(shouldAutoStartProvider(state)).toBe(true);
});

test("auto start is disabled after a provider has already been attempted", () => {
  const state = reduceSession(
    reduceSession(reduceSession(initialState("react"), { type: "context", context }), {
      type: "providers",
      providers,
    }),
    { type: "autoStartAttempted", providerId: "codex" },
  );

  expect(shouldAutoStartProvider(state)).toBe(false);
});

test("auto start attempts are remembered per provider switch", () => {
  const loaded = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "providers", providers },
  );
  const attemptedCodex = reduceSession(loaded, { type: "autoStartAttempted", providerId: "codex" });
  const selectedClaude = reduceSession(attemptedCodex, { type: "selectProvider", providerId: "claude" });
  const selectedCodexAgain = reduceSession(selectedClaude, { type: "selectProvider", providerId: "codex" });

  expect(shouldAutoStartProvider(selectedCodexAgain)).toBe(false);
});

test("auto start sends provider start from an explicit snapshot", async () => {
  const loaded = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "providers", providers },
  );
  const actions: Action[] = [];
  const messages: Array<{ method: string; params: Record<string, unknown> }> = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message as { method: string; params: Record<string, unknown> });
            return { ok: true, value: { sessionId: "session-auto" } };
          },
        },
      },
    },
  };

  try {
    await autoStartProvider(loaded, (action) => actions.push(action));
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(actions.map((action) => action.type)).toEqual(["autoStartAttempted", "starting", "startAccepted"]);
  expect(actions[0]).toEqual({ type: "autoStartAttempted", providerId: "codex" });
  expect(messages[0]?.method).toBe("provider.start");
  expect(messages[0]?.params.providerId).toBe("codex");
});

test("sent input only clears the submitted value", () => {
  const loaded = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const typed = reduceSession(loaded, { type: "setInput", input: "new draft" });
  const state = reduceSession(typed, {
    type: "sent",
    sessionId: "session-1",
    text: "old draft",
    submittedInput: "old draft",
  });

  expect(state.input).toBe("new draft");
  expect(state.log.at(-1)?.text).toBe("Sent 9 chars");
});

test("late sent replies do not overwrite a requested stop", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
    input: "draft",
  };
  const state = reduceSession(stopping, {
    type: "sent",
    sessionId: "session-1",
    text: "draft",
    submittedInput: "draft",
  });

  expect(state).toBe(stopping);
});

test("send waits until provider is running after start is accepted", async () => {
  const loaded = reduceSession(initialState("react"), { type: "context", context });
  const starting = {
    ...reduceSession(loaded, { type: "setInput", input: "hello" }),
    status: "starting" as const,
    runningSessionId: "session-1",
  };
  const actions: Action[] = [];
  const messages: unknown[] = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message);
            return { ok: false, error: { userMessage: "Provider not ready" } };
          },
        },
      },
    },
  };

  try {
    await sendInput(starting, (action) => actions.push(action));
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(messages).toHaveLength(0);
  expect(actions).toHaveLength(0);
});

test("send includes selected permission mode", async () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    input: "needs access",
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const messages: Array<{ method: string; params: Record<string, unknown> }> = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message as { method: string; params: Record<string, unknown> });
            return { ok: true, value: { sent: true } };
          },
        },
      },
    },
  };

  try {
    await sendInput(running, () => {}, { permissionMode: "full-access" });
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(messages[0]?.method).toBe("provider.writeLine");
  expect(messages[0]?.params.permissionMode).toBe("full-access");
});

test("stop preserves running session until provider exit arrives", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const stopping = reduceSession(running, { type: "stopping", sessionId: "session-1" });

  expect(stopping.status).toBe("stopping");
  expect(stopping.runningSessionId).toBe("session-1");
  expect(stopping.requestedStopSessionId).toBe("session-1");
  expect(statusLabel(stopping)).toBe("Stopping");
});

test("requested stop exits return to idle even with signal status", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 15,
    },
  });

  expect(state.status).toBe("idle");
  expect(state.runningSessionId).toBeUndefined();
  expect(state.requestedStopSessionId).toBeUndefined();
  expect(state.log.at(-1)?.text).toBe("Stopped");
});

test("late stop failures do not overwrite a clean stop exit", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const stopped = reduceSession(stopping, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 15,
    },
  });
  const state = reduceSession(stopped, {
    type: "stopFailed",
    sessionId: "session-1",
    message: "The agent session is no longer available.",
  });

  expect(state.status).toBe("idle");
  expect(state.runningSessionId).toBeUndefined();
  expect(state.log.at(-1)?.text).toBe("Stopped");
});

test("late send failures do not overwrite a requested stop", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "sendFailed",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state).toBe(stopping);
});

test("session-scoped failures do not overwrite a requested stop", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "failedForSession",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state).toBe(stopping);
});

test("bridge request errors use copy from session state", () => {
  const state = reduceSession(initialState("react"), {
    type: "context",
    context: {
      ...context,
      copy: { ...context.copy, requestFailed: "Localized bridge failure." },
    },
  });

  expect(messageForError(new Error("Native bridge request failed."), state)).toBe("Localized bridge failure.");
});

test("send failures for the active running session keep stop available", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "sendFailed",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("session-1");
  expect(canStopProvider(state)).toBe(true);
});

test("transient provider busy send failures keep the session running", async () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    input: "second turn",
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const actions: Action[] = [];
  const messages: unknown[] = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message);
            return {
              ok: false,
              error: {
                code: "providerNotReady",
                userMessage: "The provider is not ready yet.",
              },
            };
          },
        },
      },
    },
  };

  try {
    const sent = await sendInput(running, (action) => actions.push(action));
    expect(sent).toBe(false);
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(messages).toHaveLength(1);
  expect(actions).toHaveLength(0);
});

test("stop failures for an active session keep stop available", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "stopFailed",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.requestedStopSessionId).toBeUndefined();
  expect(canStopProvider(state)).toBe(true);
});

test("provider started during a requested stop is ignored", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "event",
    event: {
      type: "provider.started",
      providerId: "codex",
      sessionId: "session-1",
      executablePath: "/usr/local/bin/codex",
      arguments: ["app-server", "--listen", "stdio://"],
    },
  });

  expect(state).toBe(stopping);
});

test("format templates honor positional specifiers", () => {
  expect(formatTemplate("%2$@ %1$d", [7, "files"])).toBe("files 7");
});

test("failed calls with an active session keep stop available", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const failed = reduceSession(running, { type: "failed", message: "Native bridge request failed." });

  expect(failed.status).toBe("failed");
  expect(failed.runningSessionId).toBe("session-1");
  expect(canStopProvider(failed)).toBe(true);
});

test("claude does not auto start", () => {
  const claudeContext = { ...context, initialProviderId: "claude" as const };
  const state = reduceSession(
    reduceSession(initialState("react"), { type: "context", context: claudeContext }),
    { type: "providers", providers },
  );

  expect(shouldAutoStartProvider(state)).toBe(false);
});

test("provider selection is blocked while a failed session is still active", () => {
  const failedWithActiveSession = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "failed" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(failedWithActiveSession, { type: "selectProvider", providerId: "claude" });

  expect(canSelectProvider(failedWithActiveSession)).toBe(false);
  expect(state.selectedProviderId).toBe("codex");
});

test("provider selection is allowed after a failed start without an active session", () => {
  const failedWithoutSession = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "failed" as const,
  };
  const state = reduceSession(failedWithoutSession, { type: "selectProvider", providerId: "claude" });

  expect(canSelectProvider(failedWithoutSession)).toBe(true);
  expect(state.selectedProviderId).toBe("claude");
});

test("client ids do not require crypto.randomUUID", () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "crypto");
  Object.defineProperty(globalThis, "crypto", {
    configurable: true,
    value: {
      getRandomValues(bytes: Uint8Array) {
        bytes.fill(7);
        return bytes;
      },
    },
  });

  try {
    expect(makeClientId()).toMatch(/^[0-9a-f-]{36}$/);
    const loaded = reduceSession(initialState("react"), { type: "context", context });
    expect(loaded.log[0]?.id).toMatch(/^[0-9a-f-]{36}$/);
  } finally {
    if (descriptor) {
      Object.defineProperty(globalThis, "crypto", descriptor);
    } else {
      delete (globalThis as { crypto?: unknown }).crypto;
    }
  }
});
