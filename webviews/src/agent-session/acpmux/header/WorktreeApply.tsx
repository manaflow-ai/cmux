// Apply on the worktree pill's popover (cx-lyqio.4, Codex/Conductor style): the chat's work, every
// change its worktree made since its base, lands in the main checkout as uncommitted changes
// (`git.worktree.apply`). It says how much landed, or inline why nothing did; the session host
// changes nothing when it refuses. The pill keeps where it stands, so closing the popover mid-apply
// never offers a second one.
import { StableLabel } from "../../../ui/StableLabel";
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
function named(files: string[]): string {
  const shown = files.slice(0, MAX_NAMED_FILES).join(", ");
  return files.length > MAX_NAMED_FILES ? `${shown} +${files.length - MAX_NAMED_FILES}` : shown;
}

/// Why an apply was refused, in the pane's words: the host's machine reason, its paths and base.
function refusal(error: unknown, worktree: HeaderWorktree, t: ReturnType<typeof useT>): string {
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
        ? t("header.worktreeApplyChanged", { main, files: named(files) })
        : t("header.worktreeApplyFailed");
    case "interrupted":
      return t("header.worktreeApplyInterrupted", { main, files: named(files) });
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

export function WorktreeApply({
  worktree,
  applying,
  setApplying,
  apply,
  busy,
}: {
  worktree: HeaderWorktree;
  applying: Applying;
  setApplying: (applying: Applying) => void;
  apply: (key: string) => Promise<unknown>;
  /// Remove is running: the two never run at once.
  busy?: boolean;
}) {
  const t = useT();
  const run = () => {
    if (busy || applying.step === "applying") return;
    const key = (applying.step === "applied" ? undefined : applying.key) ?? crypto.randomUUID();
    setApplying({ step: "applying", key });
    apply(key).then(
      (value) => {
        const count = appliedCount(value);
        setApplying(
          count === undefined
            ? { step: "failed", message: t("header.worktreeApplyFailed"), key }
            : { step: "applied", count },
        );
      },
      (error: unknown) => setApplying({ step: "failed", message: refusal(error, worktree, t), key }),
    );
  };
  return (
    <div className="acpmux-worktree-apply">
      {applying.step === "applied" && (
        <output>
          {applying.count === 1
            ? t("header.worktreeApplied.one", { main: worktree.mainRoot })
            : t("header.worktreeApplied.other", { main: worktree.mainRoot, count: applying.count })}
        </output>
      )}
      {/* Work the agent does later applies again, as a new action. */}
      <button type="button" disabled={busy || applying.step === "applying"} onClick={run}>
        <StableLabel
          label={applying.step === "applying" ? t("header.worktreeApplying") : t("header.worktreeApply")}
          alternatives={[t("header.worktreeApply"), t("header.worktreeApplying")]}
        />
      </button>
      {applying.step === "failed" && <span role="alert">{applying.message}</span>}
    </div>
  );
}
