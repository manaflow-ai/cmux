// Apply on the worktree pill's popover (cx-lyqio.4, Codex/Conductor style): the chat's work, every
// change its worktree made since its base, lands in the main checkout as uncommitted changes
// (`git.worktree.apply`). It says how much landed, or inline why nothing did; the session host
// changes nothing when it refuses. The pill keeps where it stands, so closing the popover mid-apply
// never offers a second one.
import { useT, type StringKey } from "../i18n";
import type { HeaderWorktree } from "./WorktreePill";

export type Applying =
  | { step: "idle" | "applying" }
  | { step: "applied"; count: number }
  | { step: "failed"; message: string };

/// The session host's MutationResult for an apply: how many files landed.
function appliedCount(value: unknown): number | undefined {
  const raw = (value && typeof value === "object" ? value : {}) as { value?: { files?: unknown } };
  return Array.isArray(raw.value?.files) ? raw.value.files.length : undefined;
}

/// Why an apply was refused, in the pane's words: the host's machine reason, its paths and base.
function refusal(error: unknown, worktree: HeaderWorktree, t: ReturnType<typeof useT>): string {
  const details = ((error as { details?: unknown } | null)?.details ?? {}) as {
    reason?: unknown;
    extra?: { files?: unknown };
  };
  const files = Array.isArray(details.extra?.files)
    ? details.extra.files.filter((file) => typeof file === "string")
    : [];
  const keys: Record<string, StringKey> = {
    does_not_apply: "header.worktreeApplyConflicts",
    nothing_to_apply: "header.worktreeApplyNothing",
  };
  if (details.reason === "main_checkout_changed" && files.length > 0)
    return t("header.worktreeApplyChanged", { main: worktree.mainRoot, files: files.join(", ") });
  const key = typeof details.reason === "string" ? keys[details.reason] : undefined;
  return key ? t(key, { main: worktree.mainRoot, base: worktree.base }) : t("header.worktreeApplyFailed");
}

export function WorktreeApply({
  worktree,
  applying,
  setApplying,
  apply,
}: {
  worktree: HeaderWorktree;
  applying: Applying;
  setApplying: (applying: Applying) => void;
  apply: () => Promise<unknown>;
}) {
  const t = useT();
  const run = () => {
    if (applying.step === "applying") return;
    setApplying({ step: "applying" });
    apply().then(
      (value) => setApplying({ step: "applied", count: appliedCount(value) ?? 0 }),
      (error: unknown) => setApplying({ step: "failed", message: refusal(error, worktree, t) }),
    );
  };
  return (
    <div className="acpmux-worktree-apply">
      {applying.step === "applied" ? (
        <output>
          {applying.count === 1
            ? t("header.worktreeApplied.one", { main: worktree.mainRoot })
            : t("header.worktreeApplied.other", { main: worktree.mainRoot, count: applying.count })}
        </output>
      ) : (
        <button type="button" disabled={applying.step === "applying"} onClick={run}>
          {applying.step === "applying" ? t("header.worktreeApplying") : t("header.worktreeApply")}
        </button>
      )}
      {applying.step === "failed" && <span role="alert">{applying.message}</span>}
    </div>
  );
}
