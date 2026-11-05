// Remove on the worktree pill's popover (cx-lyqio.5, Codex/Conductor style): a worktree chat's
// cleanup. The session host removes the worktree and the branch New Worktree made
// (`git.worktree.remove`) and refuses while the worktree holds work found nowhere else: uncommitted
// changes, or commits on no other branch or remote. That refusal shows inline with "Remove anyway",
// the only way that work goes, and Keep. The pill keeps where it stands, like Apply.
import { StableLabel } from "../../../ui/StableLabel";
import { useT } from "../i18n";
import type { HeaderWorktree } from "./WorktreePill";

/// Where Remove stands. `key` is the action's idempotency key, kept for a retry of the same action:
/// a failed "Remove anyway" retries as "Remove anyway" under its key, so the host replays it. A
/// discard is another action than the Remove it follows, so it gets its own key.
export type Removing =
  | { step: "idle"; key?: string }
  | { step: "removing"; key: string; discard: boolean }
  | { step: "removed"; branch?: string }
  | { step: "unsaved"; message: string }
  | { step: "failed"; message: string; key: string; discard: boolean };

/// The session host's MutationResult for a removal: the branch, when it went too.
function removedBranch(value: unknown): { branch?: string } | undefined {
  const raw = (value && typeof value === "object" ? value : {}) as {
    value?: { root?: unknown; branch?: unknown; branch_deleted?: unknown };
  };
  if (typeof raw.value?.root !== "string") return undefined;
  const branch =
    raw.value.branch_deleted === true && typeof raw.value.branch === "string" ? raw.value.branch : undefined;
  return { branch };
}

/// The paths a refusal names: the first few, then how many more.
const MAX_NAMED_FILES = 5;
function named(files: string[], count: number): string {
  const shown = files.slice(0, MAX_NAMED_FILES).join(", ");
  const more = Math.max(count, files.length) - Math.min(files.length, MAX_NAMED_FILES);
  return more > 0 ? `${shown} +${more}` : shown;
}

/// Why the host kept the worktree: work found nowhere else (which "Remove anyway" may discard), or
/// undefined for any other refusal.
function unsaved(error: unknown, worktree: HeaderWorktree, t: ReturnType<typeof useT>): string | undefined {
  const details = ((error as { details?: unknown } | null)?.details ?? {}) as {
    reason?: unknown;
    extra?: { files?: unknown; count?: unknown; branch?: unknown };
  };
  switch (details.reason) {
    case "uncommitted_changes": {
      const files = Array.isArray(details.extra?.files)
        ? details.extra.files.filter((file): file is string => typeof file === "string")
        : [];
      const count = typeof details.extra?.count === "number" ? details.extra.count : files.length;
      return files.length > 0
        ? t("header.worktreeRemoveUncommitted", { files: named(files, count) })
        : t("header.worktreeRemoveUncommittedAny");
    }
    case "unpushed_commits": {
      const branch = typeof details.extra?.branch === "string" ? details.extra.branch : worktree.branch;
      return t("header.worktreeRemoveUnpushed", { branch });
    }
    default:
      return undefined;
  }
}

export function WorktreeRemove({
  worktree,
  removing,
  setRemoving,
  remove,
  busy,
}: {
  worktree: HeaderWorktree;
  removing: Removing;
  setRemoving: (removing: Removing) => void;
  remove: (key: string, discard: boolean) => Promise<unknown>;
  /// Apply is running: the two never run at once.
  busy?: boolean;
}) {
  const t = useT();
  const run = (discard: boolean) => {
    if (busy || removing.step === "removing" || removing.step === "removed") return;
    const retried = removing.step === "failed" && removing.discard === discard ? removing.key : undefined;
    const kept = removing.step === "idle" && !discard ? removing.key : undefined;
    const key = retried ?? kept ?? crypto.randomUUID();
    setRemoving({ step: "removing", key, discard });
    remove(key, discard).then(
      (value) => {
        const removed = removedBranch(value);
        setRemoving(
          removed
            ? { step: "removed", branch: removed.branch }
            : { step: "failed", message: t("header.worktreeRemoveFailed"), key, discard },
        );
      },
      (error: unknown) => {
        const message = discard ? undefined : unsaved(error, worktree, t);
        setRemoving(
          message
            ? { step: "unsaved", message }
            : { step: "failed", message: t("header.worktreeRemoveFailed"), key, discard },
        );
      },
    );
  };
  if (removing.step === "removed") {
    return (
      <div className="acpmux-worktree-apply acpmux-worktree-remove">
        <output>
          {removing.branch
            ? t("header.worktreeRemovedBranch", { branch: removing.branch })
            : t("header.worktreeRemoved")}
        </output>
      </div>
    );
  }
  // After "Remove anyway" the user already chose to discard: its retry and Keep stay offered.
  const discarding = removing.step === "unsaved" || (removing.step === "failed" && removing.discard);
  return (
    <div className="acpmux-worktree-apply acpmux-worktree-remove">
      {removing.step === "unsaved" && <span role="alert">{removing.message}</span>}
      {discarding ? (
        <div className="acpmux-worktree-remove-confirm">
          <button type="button" className="acpmux-worktree-remove-discard" disabled={busy} onClick={() => run(true)}>
            {t("header.worktreeRemoveAnyway")}
          </button>
          <button type="button" onClick={() => setRemoving({ step: "idle" })}>
            {t("header.worktreeRemoveKeep")}
          </button>
        </div>
      ) : (
        <button type="button" disabled={busy || removing.step === "removing"} onClick={() => run(false)}>
          <StableLabel
            label={removing.step === "removing" ? t("header.worktreeRemoving") : t("header.worktreeRemove")}
            alternatives={[t("header.worktreeRemove"), t("header.worktreeRemoving")]}
          />
        </button>
      )}
      {removing.step === "failed" && <span role="alert">{removing.message}</span>}
    </div>
  );
}
