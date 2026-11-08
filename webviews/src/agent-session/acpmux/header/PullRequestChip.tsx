// The chat branch's pull request in the header (cx-tcwj, Codex desktop's PR chip): its number, a
// dot for its checks, and a name that says both. A click opens its status (cx-ncc.77.1): the title,
// linking the pull request, its state and review, and each check, failing first, linking its run.
// The App pushes it with the header state, again while checks run and when a turn ends. A green
// one offers Merge (PullRequestMerge.tsx, cx-ncc.77.4).
import { useEffect, useRef, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import type { HeaderPullRequest } from "./headerState";
import { PullRequestMerge, readyToMerge, type MergeResult, type Merging } from "./PullRequestMerge";

const STATES: Record<string, StringKey> = {
  open: "header.prState.open",
  draft: "header.prState.draft",
  merged: "header.prState.merged",
  closed: "header.prState.closed",
};
const BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
};
const REVIEWS: Record<string, StringKey> = {
  approved: "header.prReview.approved",
  changes_requested: "header.prReview.changesRequested",
  review_required: "header.prReview.required",
};

export function PullRequestChip({
  pullRequest,
  onMerge,
  onFixChecks,
  onAddressComments,
}: {
  pullRequest: HeaderPullRequest;
  /// Merge (PullRequestMerge.tsx); absent where the chat can't merge from here.
  onMerge?: (pullRequest: { number: number; url: string }) => Promise<MergeResult>;
  /// Reads the failing run logs and sends a focused prompt to this chat.
  onFixChecks?: (pullRequest: HeaderPullRequest) => Promise<void>;
  /// Reads unresolved review threads and sends them to this chat.
  onAddressComments?: (pullRequest: HeaderPullRequest) => Promise<void>;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  // Where Merge stands for this pull request, kept here: the popover's content unmounts on close.
  const [merge, setMerge] = useState<{ url: string; merging: Merging }>();
  const [action, setAction] = useState<"fixing" | "addressing" | undefined>();
  const [actionError, setActionError] = useState<string>();
  const [watch, setWatch] = useState<{ token: string; state: "armed" | "merging" | "merged" | "queued" | "failed" }>();
  const merging = merge?.url === pullRequest.url ? merge.merging : { step: "idle" as const };
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  const { number, checks } = pullRequest;
  const state = STATES[pullRequest.state] ? t(STATES[pullRequest.state]!) : pullRequest.state;
  const failed = pullRequest.checkList.filter((check) => check.state === "failed").length;
  const label =
    checks.total === 0
      ? t("header.pullRequestLabel", { number, state })
      : failed > 0
        ? t("header.pullRequestLabelFailing", { number, state, passed: checks.passed, total: checks.total, failed })
        : t("header.pullRequestLabelChecks", { number, state, passed: checks.passed, total: checks.total });
  const review = REVIEWS[pullRequest.review];
  const watchToken = pullRequest.headSha ?? pullRequest.updatedAt ?? `${pullRequest.url}:${pullRequest.number}`;
  useEffect(() => {
    if (!watch || watch.token === watchToken) return;
    setWatch(undefined);
  }, [watch, watchToken]);
  useEffect(() => {
    if (!watch || watch.state !== "armed" || !onMerge || !readyToMerge(pullRequest)) return;
    setWatch({ ...watch, state: "merging" });
    onMerge({ number: pullRequest.number, url: pullRequest.url }).then(
      (result) => setWatch({ token: watch.token, state: result.queued ? "queued" : "merged" }),
      () => setWatch({ token: watch.token, state: "failed" }),
    );
  }, [onMerge, pullRequest, watch]);
  const runAction = (kind: "fixing" | "addressing", run?: (pr: HeaderPullRequest) => Promise<void>) => {
    if (!run || action) return;
    setAction(kind);
    setActionError(undefined);
    run(pullRequest).then(
      () => setAction(undefined),
      (error: unknown) => {
        setAction(undefined);
        setActionError(error instanceof Error && error.message ? error.message : t("header.prActionFailed"));
      },
    );
  };
  const armMerge = () => {
    if (!onMerge || watch) return;
    setWatch({ token: watchToken, state: "armed" });
  };
  return (
    <>
      <button
        ref={(element) => {
          buttonRef.current = element;
          setButton(element);
        }}
        type="button"
        className="acpmux-header-tool acpmux-header-pr"
        data-state={pullRequest.state}
        data-checks={checks.state}
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...trigger}
      >
        <Icon name="git.pullrequest" size={13} />#{number}
      </button>
      <Popover
        open={open}
        // The chip owns opening; Base UI only reports dismissals (Escape and outside press).
        onOpenChange={(next) => {
          if (!next) setOpen(false);
        }}
        anchor={button}
        label={label}
        className="acpmux-pr-status"
        side="bottom"
        finalFocus={buttonRef}
      >
        <a className="acpmux-pr-title" href={pullRequest.url}>
          {pullRequest.title || `#${number}`}
        </a>
        <div className="acpmux-pr-facts">
          <span className="acpmux-pr-state" data-state={pullRequest.state}>
            {BADGES[pullRequest.state] ? t(BADGES[pullRequest.state]!) : pullRequest.state} #{number}
          </span>
          {review && (
            <span className="acpmux-pr-review" data-review={pullRequest.review}>
              {t(review)}
            </span>
          )}
          {pullRequest.mergeable === "conflicting" && (
            <span className="acpmux-pr-conflicts">{t("header.prConflicts")}</span>
          )}
        </div>
        {pullRequest.checkList.length === 0 ? (
          <div className="acpmux-pr-none">{t("header.prNoChecks")}</div>
        ) : (
          <ul className="acpmux-pr-checks" aria-label={t("header.prChecks")}>
            {pullRequest.checkList.map((check, index) => (
              <li
                key={`${check.name}\u0000${index}`}
                className="acpmux-pr-check"
                data-state={check.state}
                // A failure the base branch's tip has too is nobody's to fix here, so its dot is a
                // warning rather than a danger and the row says why.
                data-on-base={check.onBase === true ? "" : undefined}
              >
                {check.url ? <a href={check.url}>{check.name}</a> : <span>{check.name}</span>}
                {check.onBase === true && <span className="acpmux-pr-check__onBase">{t("header.prCheckOnBase")}</span>}
              </li>
            ))}
          </ul>
        )}
        {onMerge && (
          <PullRequestMerge
            pullRequest={pullRequest}
            merging={merging}
            setMerging={(next) => setMerge({ url: pullRequest.url, merging: next })}
            merge={onMerge}
          />
        )}
        {(onFixChecks || onAddressComments || onMerge) && (
          <div className="acpmux-pr-actions">
            {onFixChecks && failed > 0 && (
              <button type="button" disabled={action !== undefined} onClick={() => runAction("fixing", onFixChecks)}>
                {action === "fixing" ? t("header.prFixingChecks") : t("header.prFixChecks")}
              </button>
            )}
            {onAddressComments && (
              <button type="button" disabled={action !== undefined} onClick={() => runAction("addressing", onAddressComments)}>
                {action === "addressing" ? t("header.prAddressingComments") : t("header.prAddressComments")}
              </button>
            )}
            {onMerge && !watch && (
              <button type="button" onClick={armMerge}>
                {t("header.prMergeWhenReady")}
              </button>
            )}
            {watch?.state === "armed" && <output>{t("header.prMergeWatchArmed")}</output>}
            {watch?.state === "merging" && <output>{t("header.prMerging")}</output>}
            {watch?.state === "merged" && <output>{t("header.prMerged")}</output>}
            {watch?.state === "queued" && <output>{t("header.prMergeQueued")}</output>}
            {watch?.state === "failed" && <output role="alert">{t("header.prMergeFailed")}</output>}
            {actionError && <output role="alert">{actionError}</output>}
          </div>
        )}
      </Popover>
    </>
  );
}
