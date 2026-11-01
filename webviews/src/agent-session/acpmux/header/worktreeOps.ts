import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { HeaderWorktree } from "./WorktreePill";

/// Where Apply stands. `key` is the action's idempotency key, kept until the host answers that it
/// applied: a retry after a reply that never came (or a timeout) is the same action, so the host
/// replays or finishes it instead of seeing the user's checkout already changed.
export type Applying =
  | { step: "idle"; key?: string }
  | { step: "applying"; key: string }
  | { step: "applied"; count: number }
  | { step: "failed"; message: string; key: string };

/// The session host's MutationResult for an apply: how many files landed.
function appliedCount(value: unknown): number | undefined {
  const raw = (value && typeof value === "object" ? value : {}) as { value?: { files?: unknown } };
  return Array.isArray(raw.value?.files) ? raw.value.files.length : undefined;
}

/// The paths a refusal names: the first few, then how many more.
const MAX_NAMED_FILES = 5;
function namedApply(files: string[]): string {
  const shown = files.slice(0, MAX_NAMED_FILES).join(", ");
  return files.length > MAX_NAMED_FILES ? `${shown} +${files.length - MAX_NAMED_FILES}` : shown;
}

/// Why an apply was refused, in the pane's words: the host's machine reason, its paths and base.
function applyRefusal(error: unknown, worktree: HeaderWorktree, t: ReturnType<typeof useT>): string {
  const details = ((error as { details?: unknown } | null)?.details ?? {}) as {
    reason?: unknown;
    extra?: { files?: unknown; base?: unknown };
  };
  const files = Array.isArray(details.extra?.files)
    ? details.extra.files.filter((file): file is string => typeof file === "string")
    : [];
  const base = typeof details.extra?.base === "string" ? details.extra.base : worktree.base;
  const main = worktree.mainRoot;
  switch (details.reason) {
    case "main_checkout_changed":
      return files.length > 0
        ? t("header.worktreeApplyChanged", { main, files: namedApply(files) })
        : t("header.worktreeApplyFailed");
    case "interrupted":
      return t("header.worktreeApplyInterrupted", { main, files: namedApply(files) });
    case "does_not_apply":
      return t("header.worktreeApplyConflicts", { main });
    case "nothing_to_apply":
      return base ? t("header.worktreeApplyNothing", { base }) : t("header.worktreeApplyFailed");
    case "unmerged":
      return t("header.worktreeApplyUnmerged");
    case "no_base":
      return t("header.worktreeApplyNoBase");
    default:
      return t("header.worktreeApplyFailed");
  }
}

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

function namedRemove(files: string[], count: number): string {
  const shown = files.slice(0, MAX_NAMED_FILES).join(", ");
  const more = Math.max(count, files.length) - Math.min(files.length, MAX_NAMED_FILES);
  return more > 0 ? `${shown} +${more}` : shown;
}

/// Why the host kept the worktree: work found nowhere else (which "Remove anyway" may discard), or
/// undefined for any other refusal.
function removeUnsaved(error: unknown, worktree: HeaderWorktree, t: ReturnType<typeof useT>): string | undefined {
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
        ? t("header.worktreeRemoveUncommitted", { files: namedRemove(files, count) })
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

export interface WorktreeAction {
  label: string;
  enabled: boolean;
  run(): void;
}
export interface WorktreeOps {
  identity: string;
  applying: Applying;
  removing: Removing;
  apply?: WorktreeAction;
  remove?: WorktreeAction;
  keep?: WorktreeAction;
  applyMessage?: string;
  removeMessage?: string;
  messages: string[];
  canRemove: boolean;
}
interface OperationRecord {
  identity: string;
  applying: Applying;
  removing: Removing;
}

/// One state machine serves the web popover and native menu. A new folder/branch gets a new
/// record, including when switching A → B → A; late replies cannot mutate the new record.
export function useWorktreeOps(
  worktree: HeaderWorktree | undefined,
  folder: string | undefined,
  onApply?: (key: string) => Promise<unknown>,
  onRemove?: (key: string, discard: boolean) => Promise<unknown>,
): WorktreeOps {
  const t = useT();
  const identity = worktree ? JSON.stringify([folder ?? worktree.mainRoot, worktree.branch]) : "";
  const current = useRef<OperationRecord | undefined>(undefined);
  const alive = useRef(true);
  const [, redraw] = useState(0);
  if (!current.current || current.current.identity !== identity)
    current.current = { identity, applying: { step: "idle" }, removing: { step: "idle" } };
  const record = current.current;
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const valid = () => alive.current && current.current === record;
  const changed = () => {
    if (valid()) redraw((value) => value + 1);
  };
  const busy = () => record.applying.step === "applying" || record.removing.step === "removing";
  const removed = () => record.removing.step === "removed";
  const runApply = () => {
    if (!valid() || !worktree || !onApply || busy() || removed()) return;
    const prior = record.applying;
    const key = (prior.step === "applied" ? undefined : prior.key) ?? crypto.randomUUID();
    record.applying = { step: "applying", key };
    changed();
    void (async () => {
      try {
        const value = await onApply(key);
        if (!valid()) return;
        const count = appliedCount(value);
        record.applying =
          count === undefined
            ? { step: "failed", message: t("header.worktreeApplyFailed"), key }
            : { step: "applied", count };
      } catch (error) {
        if (!valid()) return;
        record.applying = { step: "failed", message: applyRefusal(error, worktree, t), key };
      }
      changed();
    })();
  };
  const discardAllowed = () =>
    record.removing.step === "unsaved" || (record.removing.step === "failed" && record.removing.discard);
  const runRemove = (discard: boolean) => {
    if (!valid() || !worktree || !onRemove || busy() || removed() || discard !== discardAllowed()) return;
    const prior = record.removing;
    const retried = prior.step === "failed" && prior.discard === discard ? prior.key : undefined;
    const kept = prior.step === "idle" && !discard ? prior.key : undefined;
    const key = retried ?? kept ?? crypto.randomUUID();
    record.removing = { step: "removing", key, discard };
    changed();
    void (async () => {
      try {
        const value = await onRemove(key, discard);
        if (!valid()) return;
        const result = removedBranch(value);
        record.removing = result
          ? { step: "removed", branch: result.branch }
          : { step: "failed", message: t("header.worktreeRemoveFailed"), key, discard };
      } catch (error) {
        if (!valid()) return;
        const message = discard ? undefined : removeUnsaved(error, worktree, t);
        record.removing = message
          ? { step: "unsaved", message }
          : { step: "failed", message: t("header.worktreeRemoveFailed"), key, discard };
      }
      changed();
    })();
  };
  const { applying, removing } = record;
  const discarding = discardAllowed();
  const applyMessage =
    applying.step === "applied" && worktree
      ? applying.count === 1
        ? t("header.worktreeApplied.one", { main: worktree.mainRoot })
        : t("header.worktreeApplied.other", { main: worktree.mainRoot, count: applying.count })
      : applying.step === "failed"
        ? applying.message
        : undefined;
  const removeMessage =
    removing.step === "removed"
      ? removing.branch
        ? t("header.worktreeRemovedBranch", { branch: removing.branch })
        : t("header.worktreeRemoved")
      : removing.step === "unsaved" || removing.step === "failed"
        ? removing.message
        : undefined;
  return {
    identity,
    applying,
    removing,
    canRemove: !!onRemove,
    apply:
      worktree && onApply && !removed()
        ? {
            label: t(applying.step === "applying" ? "header.worktreeApplying" : "header.worktreeApply"),
            enabled: !busy(),
            run: runApply,
          }
        : undefined,
    remove:
      worktree && onRemove && !removed()
        ? {
            label: t(
              discarding
                ? "header.worktreeRemoveAnyway"
                : removing.step === "removing"
                  ? "header.worktreeRemoving"
                  : "header.worktreeRemove",
            ),
            enabled: !busy(),
            run: () => runRemove(discarding),
          }
        : undefined,
    keep:
      worktree && onRemove && discarding
        ? {
            label: t("header.worktreeRemoveKeep"),
            enabled: !busy(),
            run: () => {
              if (!valid() || busy()) return;
              record.removing = { step: "idle" };
              changed();
            },
          }
        : undefined,
    applyMessage,
    removeMessage,
    messages: [!removed() && applyMessage, removeMessage].filter((value): value is string => typeof value === "string"),
  };
}
