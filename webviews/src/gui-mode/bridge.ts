import { callNative } from "../agent-session/shared/bridge";

export type GuiModeCopy = {
  errorMessage: string;
  homeTitle: string;
  promptPlaceholder: string;
  submit: string;
  submitting: string;
  taskPromptLabel: string;
  taskTitle: string;
};

export type GuiModeContext = {
  copy: GuiModeCopy;
  page: "home" | "task-worktree-pr";
  prompt: string;
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

export async function submitGuiModePrompt(prompt: string): Promise<{ workspaceId: string }> {
  return callNativeWithTimeout<{ workspaceId: string }>("guiMode.submit", { prompt }, 12000);
}

function callNativeWithTimeout<T>(
  method: string,
  params: Record<string, unknown>,
  timeoutMs: number,
): Promise<T> {
  return Promise.race([
    callNative<T>(method, params),
    new Promise<T>((_, reject) => {
      window.setTimeout(() => reject(new Error("Native bridge timed out.")), timeoutMs);
    }),
  ]);
}
