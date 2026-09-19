import { callNative, NativeBridgeError } from "../agent-session/shared/bridge";

export type GuiModeCopy = {
  cancel: string;
  cancellationUnconfirmed: string;
  errorMessage: string;
  homeTitle: string;
  noProvidersFound: string;
  promptPlaceholder: string;
  providerLabel: string;
  providerSearchPlaceholder: string;
  runtimeLabel: string;
  setupCommandLabel: string;
  submit: string;
  submitting: string;
  taskCommandLabel: string;
  taskPromptLabel: string;
  taskTitle: string;
  chatMode?: string;
  terminalMode?: string;
  terminalPlaceholder?: string;
  terminalErrorMessage?: string;
  modelLabel?: string;
  reasoningLabel?: string;
  reasoningLow?: string;
  reasoningMedium?: string;
  reasoningHigh?: string;
  reasoningExtraHigh?: string;
  permissionLabel?: string;
  permissionDefault?: string;
  permissionFullAccess?: string;
  permissionAutoReview?: string;
  permissionCustom?: string;
  contextLabel?: string;
  currentFolder?: string;
  localLabel?: string;
  voiceTitle?: string;
  voiceDescription?: string;
  voiceAction?: string;
  folderFallback?: string;
  emptyTitle?: string;
  emptySubtitle?: string;
  modeLabel?: string;
  reasoningDefault?: string;
};

export type GuiModeMode = "chat" | "terminal";

export type GuiModeModel = {
  displayName: string;
  id: string;
  providerId: string;
  reasoningEfforts: string[];
};

export type GuiModeProvider = {
  accentColor: string;
  capabilities: string[];
  detail: string;
  displayName: string;
  id: string;
  runtimeMode: string;
  setupCommand: string;
  supportLabel: string;
  taskCommandPreview: string;
};

export type GuiModeContext = {
  copy: GuiModeCopy;
  page: "home" | "task-worktree-pr";
  prompt: string;
  providers: GuiModeProvider[];
  selectedProviderId: string;
  selectedModelId?: string;
  selectedReasoningEffort?: string;
  models?: GuiModeModel[];
  workingDirectory?: string;
  gitBranch?: string;
};

export type GuiModeAppContext = {
  guiMode?: GuiModeContext;
};

export type GuiModeBootstrap = {
  context: GuiModeContext;
  loadingMessage: string;
  errorMessage: string;
};

declare global {
  interface Window {
    cmuxGuiModeBootstrap?: GuiModeBootstrap;
  }
}

export function readGuiModeBootstrap(): GuiModeBootstrap | undefined {
  return typeof window === "undefined" ? undefined : window.cmuxGuiModeBootstrap;
}

export function isGuiModeBridgeTimeout(error: unknown): boolean {
  return error instanceof NativeBridgeError && error.code === "timeout";
}

export async function loadGuiModeContext(): Promise<GuiModeContext> {
  const bootstrap = readGuiModeBootstrap();
  if (bootstrap) return bootstrap.context;
  const context = await callNativeWithTimeout<GuiModeAppContext>("app.context", {}, 4000);
  if (!context.guiMode) {
    throw new Error("Missing GUI mode context.");
  }
  return context.guiMode;
}

export async function submitGuiModePrompt(
  prompt: string,
  providerId: string,
  requestId: string = makeGuiModeRequestId(),
  options: { modelId?: string; reasoningEffort?: string; permissionMode?: string } = {},
): Promise<{ workspaceId: string }> {
  return callNativeWithTimeout<{ workspaceId: string }>(
    "guiMode.submit",
    { prompt, providerId, requestId, ...options },
    30000,
  );
}

export type GuiModeTerminalResult = {
  workingDirectory: string;
  gitBranch?: string;
  output: string;
  exitCode: number;
};

export async function executeGuiModeTerminal(
  command: string,
  requestId: string = makeGuiModeRequestId(),
): Promise<GuiModeTerminalResult> {
  return callNativeWithTimeout<GuiModeTerminalResult>(
    "guiMode.executeTerminal", { command, requestId }, 65000,
  );
}

export function cancelGuiModeTerminal(requestId: string): Promise<unknown> {
  return callNative("guiMode.cancelTerminal", { requestId });
}

export async function cancelGuiModeSubmit(requestId: string): Promise<{ cancelled: true }> {
  const result = await callNativeWithTimeout<{ cancelled?: boolean }>("guiMode.cancel", { requestId }, 3000);
  if (result.cancelled !== true) {
    throw new NativeBridgeError("Native cancellation was not accepted.", "cancellationNotConfirmed");
  }
  return { cancelled: true };
}

export function makeGuiModeRequestId(): string {
  return `gui-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function callNativeWithTimeout<T>(
  method: string,
  params: Record<string, unknown>,
  timeoutMs: number,
): Promise<T> {
  let timeoutId: number | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timeoutId = window.setTimeout(() => reject(new NativeBridgeError("Native bridge timed out.", "timeout")), timeoutMs);
  });
  return Promise.race([callNative<T>(method, params), timeout]).finally(() => {
    if (timeoutId !== undefined) {
      window.clearTimeout(timeoutId);
    }
  });
}
