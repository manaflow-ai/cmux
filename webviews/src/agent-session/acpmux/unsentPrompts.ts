// The prompts the person sent that no agent has taken yet, kept by the app host so they outlive
// the page: a relaunch, a crash or an update. Leo, 2026-11-11: "when restarting ALL MY ... UNSENT
// ... GOT DELETED". The pane's web store does not survive a relaunch, and the host's prompt journal
// keeps only frames in flight to this Mac's own acpmux: a refused prompt (a remote chat's
// `remote.local_claude_session`, no answer in time, a dropped connection) lived only in the page.
//
// The page puts a prompt when it draws its row and takes it out only when an agent has it
// (acpmux's acknowledgement or its echo) or the person removed it or took it back into the
// composer. A refusal or an error never takes one out. Writes are per prompt, never a whole list,
// so a page that has not read a chat yet can never write an empty list over it
// (AgentPaneUnsentPrompts.swift).

import type { ComposerAttachment } from "./attachments";
import type { PromptDelivery } from "./model";

/// One kept prompt: what Retry sends and Edit gives back, and why it was not sent.
export type UnsentPromptRecord = {
  promptId: string;
  input: string;
  attachments: ComposerAttachment[];
  /// When the person sent it.
  at: number;
  /// The row's sentence for why it was not sent, as it was shown.
  error?: string;
  /// The refusal's cause, for the row's Details and its Retry rules (sendFailure.ts).
  failure?: Pick<PromptDelivery, "hop" | "code" | "reason" | "error" | "failedAt">;
};

/// The host's store of unsent prompts, by chat.
export type UnsentPromptStore = {
  read(sessionId: string): Promise<UnsentPromptRecord[]>;
  put(sessionId: string, record: UnsentPromptRecord): Promise<unknown>;
  remove(sessionId: string, promptId: string): Promise<unknown>;
};

const HOPS = new Set(["connection", "acpmux", "agent"]);

/// The records a host answered, each checked; anything else is left out.
export function parseUnsentPrompts(value: unknown): UnsentPromptRecord[] {
  const list = (value as { prompts?: unknown } | null)?.prompts;
  if (!Array.isArray(list)) return [];
  return list.flatMap((item): UnsentPromptRecord[] => {
    const record = item as Partial<UnsentPromptRecord> | null;
    if (!record || typeof record.promptId !== "string" || !record.promptId) return [];
    if (typeof record.input !== "string" || typeof record.at !== "number") return [];
    const attachments = Array.isArray(record.attachments)
      ? record.attachments.filter(
          (chip): chip is ComposerAttachment =>
            typeof chip?.id === "string" && typeof chip.kind === "string" && typeof chip.name === "string",
        )
      : [];
    const failure = record.failure && typeof record.failure === "object" ? record.failure : undefined;
    return [
      {
        promptId: record.promptId,
        input: record.input,
        attachments,
        at: record.at,
        ...(typeof record.error === "string" ? { error: record.error } : {}),
        ...(failure
          ? {
              failure: {
                ...(typeof failure.hop === "string" && HOPS.has(failure.hop) ? { hop: failure.hop } : {}),
                ...(typeof failure.code === "string" ? { code: failure.code } : {}),
                ...(typeof failure.reason === "string" ? { reason: failure.reason } : {}),
                ...(typeof failure.error === "string" ? { error: failure.error } : {}),
                ...(typeof failure.failedAt === "number" ? { failedAt: failure.failedAt } : {}),
              },
            }
          : {}),
      },
    ];
  });
}

/// The app host's store (`chat.unsentPrompt.put`, `chat.unsentPrompt.remove`,
/// `chat.unsentPrompts.get`). A host that keeps none (the gallery, an older app) reads none.
export function nativeUnsentPrompts(
  call: <T>(method: string, params: Record<string, unknown>) => Promise<T>,
): UnsentPromptStore {
  return {
    read: (sessionId) => call<unknown>("chat.unsentPrompts.get", { sessionId }).then(parseUnsentPrompts, () => []),
    put: (sessionId, record) => call("chat.unsentPrompt.put", { sessionId, prompt: record }),
    remove: (sessionId, promptId) => call("chat.unsentPrompt.remove", { sessionId, promptId }),
  };
}
