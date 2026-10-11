// Merge on the PR chip's status (cx-ncc.77.4, Codex desktop's): a pull request that is open, every
// check passed, nothing in conflict and no changes requested offers Merge. It asks once more in
// place (no dialog), then the App merges that pull request at the head this Mac has, or says why
// not. The App checks all of it again with GitHub before it merges.
import { useState } from "react";
import { useT } from "../i18n";
import type { HeaderPullRequest } from "./headerState";

type Merging = { step: "idle" | "confirm" | "merging" | "merged" } | { step: "failed"; message: string };

/// Whether the page offers Merge for `pullRequest`.
export function readyToMerge(pullRequest: HeaderPullRequest) {
  return (
    pullRequest.state === "open" &&
    pullRequest.mergeable === "mergeable" &&
    pullRequest.review !== "changes_requested" &&
    (pullRequest.checks.state === "passing" || pullRequest.checks.state === "none")
  );
}

export function PullRequestMerge({
  pullRequest,
  merge,
}: {
  pullRequest: HeaderPullRequest;
  merge: (number: number) => Promise<unknown>;
}) {
  const t = useT();
  const [merging, setMerging] = useState<Merging>({ step: "idle" });
  // A merge under way or done stays in view, though the pull request is no longer ready.
  if (merging.step === "idle" && !readyToMerge(pullRequest)) return null;
  const run = () => {
    setMerging({ step: "merging" });
    merge(pullRequest.number).then(
      () => setMerging({ step: "merged" }),
      (error: unknown) =>
        setMerging({
          step: "failed",
          message: error instanceof Error && error.message ? error.message : t("header.prMergeFailed"),
        }),
    );
  };
  return (
    <div className="acpmux-pr-merge" data-step={merging.step}>
      {merging.step === "merged" ? (
        <output>{t("header.prMerged")}</output>
      ) : merging.step === "confirm" || merging.step === "merging" ? (
        <>
          <span className="acpmux-pr-merge-question">
            {t("header.prMergeQuestion", { number: pullRequest.number })}
          </span>
          <div className="acpmux-pr-merge-buttons">
            <button
              type="button"
              className="acpmux-pr-merge-cancel"
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
              {merging.step === "merging" ? t("header.prMerging") : t("header.prMergeConfirm")}
            </button>
          </div>
        </>
      ) : (
        <>
          {merging.step === "failed" && <output role="alert">{merging.message}</output>}
          <button type="button" className="acpmux-pr-merge-start" onClick={() => setMerging({ step: "confirm" })}>
            {t("header.prMerge")}
          </button>
        </>
      )}
    </div>
  );
}
