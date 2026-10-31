// Merge on the PR chip's status (cx-ncc.77.4, Codex desktop's): a pull request that is open, every
// check passed, nothing in conflict and no review outstanding offers Merge. It asks once more in
// place (no dialog), then the App merges that pull request at the head this Mac has, or says why
// not; a base branch with a merge queue takes it into the queue. The App checks all of it again
// with GitHub before it merges. The chip keeps where the merge stands, so closing the popover
// mid-merge never offers a second one.
import { useEffect, useRef } from "react";
import { StableLabel } from "../../../ui/StableLabel";
import { useT } from "../i18n";
import type { HeaderPullRequest } from "./headerState";

export type Merging =
  | { step: "idle" | "confirm" | "merging" | "merged" | "queued" }
  | { step: "failed"; message: string };
/// What the App's merge answered: merged, or taken into a merge queue.
export type MergeResult = { queued: boolean };

/// Whether the page offers Merge for `pullRequest`.
export function readyToMerge(pullRequest: HeaderPullRequest) {
  return (
    pullRequest.state === "open" &&
    pullRequest.mergeable === "mergeable" &&
    pullRequest.review !== "changes_requested" &&
    pullRequest.review !== "review_required" &&
    (pullRequest.checks.state === "passing" || pullRequest.checks.state === "none")
  );
}

export function PullRequestMerge({
  pullRequest,
  merging,
  setMerging,
  merge,
}: {
  pullRequest: HeaderPullRequest;
  merging: Merging;
  setMerging: (merging: Merging) => void;
  merge: (pullRequest: { number: number; url: string }) => Promise<MergeResult>;
}) {
  const t = useT();
  const box = useRef<HTMLDivElement>(null);
  // The control the reader pressed is replaced; the next one takes focus, when focus was here.
  useEffect(() => {
    const active = document.activeElement;
    if (!box.current || (active && active !== document.body && !box.current.contains(active))) return;
    box.current.querySelector<HTMLElement>("[data-focus-next]")?.focus();
  }, [merging.step]);
  // A merge under way or done stays in view, though the pull request is no longer ready.
  if (merging.step === "idle" && !readyToMerge(pullRequest)) return null;
  const run = () => {
    setMerging({ step: "merging" });
    merge({ number: pullRequest.number, url: pullRequest.url }).then(
      (result) => setMerging({ step: result.queued ? "queued" : "merged" }),
      (error: unknown) =>
        setMerging({
          step: "failed",
          message: error instanceof Error && error.message ? error.message : t("header.prMergeFailed"),
        }),
    );
  };
  return (
    <div ref={box} className="acpmux-pr-merge" data-step={merging.step}>
      {merging.step === "merged" || merging.step === "queued" ? (
        // A status region: it says the result, and focus stays with the popover.
        <output>{t(merging.step === "merged" ? "header.prMerged" : "header.prMergeQueued")}</output>
      ) : merging.step === "confirm" || merging.step === "merging" ? (
        <>
          <span className="acpmux-pr-merge-question">
            {t("header.prMergeQuestion", { number: pullRequest.number })}
          </span>
          <div className="acpmux-pr-merge-buttons">
            <button
              type="button"
              className="acpmux-pr-merge-cancel"
              data-focus-next=""
              aria-disabled={merging.step === "merging" ? true : undefined}
              onClick={() => merging.step === "confirm" && setMerging({ step: "idle" })}
            >
              {t("header.prMergeCancel")}
            </button>
            <button
              type="button"
              className="acpmux-pr-merge-confirm"
              aria-disabled={merging.step === "merging" ? true : undefined}
              onClick={() => merging.step === "confirm" && run()}
            >
              <StableLabel
                label={merging.step === "merging" ? t("header.prMerging") : t("header.prMergeConfirm")}
                alternatives={[t("header.prMergeConfirm"), t("header.prMerging")]}
              />
            </button>
          </div>
        </>
      ) : (
        <>
          {merging.step === "failed" && <output role="alert">{merging.message}</output>}
          <button
            type="button"
            className="acpmux-pr-merge-start"
            data-focus-next=""
            onClick={() => setMerging({ step: "confirm" })}
          >
            {t("header.prMerge")}
          </button>
        </>
      )}
    </div>
  );
}
