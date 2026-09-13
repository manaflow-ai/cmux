import { callNative } from "../agent-session/shared/bridge";

export type GuiModeCopy = {
  cancel: string;
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
};

export type GuiModeAppContext = {
  guiMode?: GuiModeContext;
};

export async function loadGuiModeContext(): Promise<GuiModeContext> {
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
): Promise<{ workspaceId: string }> {
  return callNative<{ workspaceId: string }>("guiMode.submit", { prompt, providerId, requestId });
}

export async function cancelGuiModeSubmit(requestId: string): Promise<void> {
  await callNativeWithTimeout("guiMode.cancel", { requestId }, 3000);
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
    timeoutId = window.setTimeout(() => reject(new Error("Native bridge timed out.")), timeoutMs);
  });
  return Promise.race([callNative<T>(method, params), timeout]).finally(() => {
    if (timeoutId !== undefined) {
      window.clearTimeout(timeoutId);
    }
  });
}
