import type {
  AcpmuxSessionOffer,
  AcpmuxOfferResult,
  AcpmuxBackgroundState,
  AcpmuxBackgroundTask,
  AcpmuxCompaction,
  AcpmuxPlanEntry,
} from "../model";

/// Claude Code says it is still compacting every 30 seconds (2.1.305): a running note this soon
/// after a row's last one is that compaction going on; a later one is a new compaction.
export const COMPACTION_REPEAT_WINDOW = 90_000;

/// A compaction's next running note on its row: what the row knew (a wrapper's reason), still running.
export function stillRunning(prior: AcpmuxCompaction, next: AcpmuxCompaction): AcpmuxCompaction {
  const { inferred: _inferred, ...known } = prior;
  return { ...known, ...next };
}

/// A `compaction` update's state, sizes and, for a failed one, why; undefined for a state
/// acpmux does not send.
export function compactionOf(update: any): AcpmuxCompaction | undefined {
  const state = update?.state;
  if (state !== "running" && state !== "completed" && state !== "failed") return undefined;
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
  return {
    state,
    ...(typeof update.reason === "string" && update.reason ? { reason: update.reason } : {}),
    ...(state === "failed" && typeof update.error === "string" && update.error.trim()
      ? { error: update.error.trim() }
      : {}),
    ...(count(update.preTokens) !== undefined ? { preTokens: count(update.preTokens) } : {}),
    ...(count(update.postTokens) !== undefined ? { postTokens: count(update.postTokens) } : {}),
  };
}

/// A `background_task_update`'s shell and how it ended; undefined when it names neither.
/// A `session_offer` record's offer, or undefined when it lacks an id, title, prompt or folder.
export function sessionOffer(msg: any): AcpmuxSessionOffer | undefined {
  const field = (key: string) => (typeof msg?.[key] === "string" ? (msg[key] as string) : "");
  const [offerId, title, prompt, cwd] = ["offerId", "title", "prompt", "cwd"].map(field);
  if (!offerId || !title || !prompt || !cwd) return undefined;
  return {
    offerId,
    title,
    prompt,
    cwd,
    worktree: msg.worktree === true,
    ...(field("harness") ? { harness: field("harness") } : {}),
    ...(field("model") ? { model: field("model") } : {}),
    ...(field("groupId") ? { groupId: field("groupId") } : {}),
  };
}

/// The started offer a `user_message` brings the result of (`_meta.provenance`, kind
/// `offer_result`), or undefined for any other prompt.
export function offerResult(msg: any): AcpmuxOfferResult | undefined {
  const provenance = msg?._meta?.provenance;
  if (provenance?.kind !== "offer_result") return undefined;
  const [offerId, childSessionId, title] = [provenance.offerId, provenance.childSessionId, provenance.title];
  if (typeof offerId !== "string" || typeof childSessionId !== "string" || typeof title !== "string" || !title)
    return undefined;
  return { offerId, childSessionId, title };
}

/// A background shell's update: running in the background, or how it ended.
export type BackgroundUpdate = Omit<AcpmuxBackgroundTask, "state"> & {
  state: AcpmuxBackgroundState["state"];
};

export function backgroundTask(update: any, at?: number): BackgroundUpdate | undefined {
  const state = update.state;
  if (typeof update.toolCallId !== "string" || !["running", "completed", "failed", "stopped"].includes(state))
    return undefined;
  const ownerId =
    typeof update.ownerId === "string"
      ? update.ownerId
      : typeof update.subagentSessionId === "string"
        ? update.subagentSessionId
        : typeof update.subagent === "string"
          ? update.subagent
          : typeof update?._meta?.acpmux?.subagent === "string"
            ? update._meta.acpmux.subagent
            : undefined;
  const ownerTitle =
    typeof update.ownerTitle === "string"
      ? update.ownerTitle.trim()
      : typeof update.subagentTitle === "string"
        ? update.subagentTitle.trim()
        : undefined;
  const startedAt = typeof update.startedAt === "number" ? update.startedAt : undefined;
  const endedAt = state === "running" ? undefined : typeof update.endedAt === "number" ? update.endedAt : at;
  return {
    toolCallId: update.toolCallId,
    command: typeof update.command === "string" ? update.command : "",
    ...(ownerId ? { ownerId } : {}),
    ...(ownerTitle ? { ownerTitle } : {}),
    ...(typeof update.description === "string" && update.description.trim()
      ? { description: update.description.trim() }
      : {}),
    ...(startedAt !== undefined ? { startedAt } : {}),
    ...(endedAt !== undefined ? { endedAt } : {}),
    state,
    ...(typeof update.reason === "string" && update.reason ? { reason: update.reason } : {}),
    ...(typeof update.summary === "string" && update.summary ? { summary: update.summary } : {}),
    ...(Number.isInteger(update.exitCode) ? { exitCode: update.exitCode as number } : {}),
  };
}

/// Older task_started records put the SDK's description in the command field. A completion
/// notice can still name that task explicitly, even when the original Bash call was never saved.
export function backgroundNoticeLabel(task: BackgroundUpdate): string | undefined {
  const summary = task.summary;
  if (!summary || summary.length > 4096) return undefined;
  const notice =
    /^Background command "([^\r\n]+)" (completed|failed|was stopped)(?: \(exit code -?\d+\)| with exit code -?\d+)?$/.exec(
      summary,
    );
  if (!notice) return undefined;
  const state = notice[2] === "was stopped" ? "stopped" : notice[2];
  return state === task.state ? notice[1]?.trim() || undefined : undefined;
}

/// An ACP `plan` update's entries as a todo list; an entry without text is left out.
export function planEntries(entries: unknown): AcpmuxPlanEntry[] {
  if (!Array.isArray(entries)) return [];
  return entries.flatMap((entry) => {
    const content = typeof entry?.content === "string" ? entry.content.trim() : "";
    if (!content) return [];
    const status = entry.status === "completed" || entry.status === "in_progress" ? entry.status : "pending";
    return [{ content, status }];
  });
}
