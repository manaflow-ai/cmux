// Merge on the PR chip's status (cx-ncc.77.4, Codex desktop's): a pull request that is open, every
// check passed, nothing in conflict and no review outstanding offers Merge. It asks once more in
// place (no dialog), then the App merges that pull request at the head this Mac has, or says why
// not; a base branch with a merge queue takes it into the queue. The App checks all of it again
// with GitHub before it merges. The chip keeps where the merge stands, so closing the popover
// mid-merge never offers a second one.
import { useEffect, useRef } from "react";
import { StableLabel } from "../../../ui/StableLabel";
import { useT } from "../i18n";
import type { PullRequestOps } from "./pullRequestOps";
export { readyToMerge } from "./pullRequestOps";

export type Merging =
  | { step: "idle" | "confirm" | "merging" | "merged" | "queued" }
  | { step: "failed"; message: string };
/// What the App's merge answered: merged, or taken into a merge queue.
export type MergeResult = { queued: boolean };

export function PullRequestMerge({ ops }: { ops: PullRequestOps }) {
  const t = useT();
  const { merging, start, confirm, cancel, question, messages } = ops;
  const box = useRef<HTMLDivElement>(null);
  // The control the reader pressed is replaced; the next one takes focus, when focus was here.
  useEffect(() => {
    const active = document.activeElement;
    if (!box.current || (active && active !== document.body && !box.current.contains(active))) return;
    box.current.querySelector<HTMLElement>("[data-focus-next]")?.focus();
  }, [merging.step]);
  if (!start && !confirm && !messages.length) return null;
  return (
    <div ref={box} className="acpmux-pr-merge" data-step={merging.step}>
      {merging.step === "merged" || merging.step === "queued" ? (
        // A status region: it says the result, and focus stays with the popover.
        <output>{messages[0]}</output>
      ) : merging.step === "confirm" || merging.step === "merging" ? (
        <>
          <span className="acpmux-pr-merge-question">{question}</span>
          <div className="acpmux-pr-merge-buttons">
            <button
              type="button"
              className="acpmux-pr-merge-cancel"
              data-focus-next=""
              aria-disabled={merging.step === "merging" ? true : undefined}
              onClick={cancel?.run}
            >
              {cancel?.label}
            </button>
            <button
              type="button"
              className="acpmux-pr-merge-confirm"
              aria-disabled={merging.step === "merging" ? true : undefined}
              onClick={confirm?.run}
            >
              {confirm && (
                <StableLabel label={confirm.label} alternatives={[t("header.prMergeConfirm"), t("header.prMerging")]} />
              )}
            </button>
          </div>
        </>
      ) : (
        <>
          {merging.step === "failed" && <output role="alert">{merging.message}</output>}
          <button type="button" className="acpmux-pr-merge-start" data-focus-next="" onClick={start?.run}>
            {start?.label}
          </button>
        </>
      )}
    </div>
  );
}
