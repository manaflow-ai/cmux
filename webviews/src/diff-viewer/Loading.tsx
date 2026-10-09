// Owns the diff viewer's loading placeholders: the file list and diff skeletons and the
// loading layer.
import type { DiffViewerLabelResolver } from "../labels";
import type { DiffViewerStatus } from "../status";

const fileSkeletonWidths = ["82%", "64%", "76%", "58%", "70%", "46%"];
const diffSkeletonWidths = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
export function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div
          key={`${width}-${index}`}
          className="grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]"
        >
          <span className="size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span
            className="h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70"
            style={{ width: index % 2 === 0 ? "34px" : "24px" }}
          />
        </div>
      ))}
    </div>
  );
}

function LoadingDiffSkeleton() {
  return (
    <div
      className="diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3"
      aria-hidden="true"
    >
      <div className="mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3">
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" />
      </div>
      <div className="space-y-[13px] px-3 py-1">
        {diffSkeletonWidths.map((width, index) => (
          <div key={`${width}-${index}`} className="grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4">
            <span className="h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" />
            <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          </div>
        ))}
      </div>
    </div>
  );
}

export function LoadingLayer({ label, status }: { label: DiffViewerLabelResolver; status: DiffViewerStatus }) {
  if (!status.loading && !status.pending && !status.statusOnly && !status.error) {
    return null;
  }
  return (
    <div id="loading-layer" aria-live="polite">
      <div id="status" data-error={status.error ? "true" : "false"} data-pending={status.pending ? "true" : "false"}>
        <span id="status-icon" aria-hidden="true" />
        <span id="status-text">{status.message || label("loadingDiff")}</span>
      </div>
      {status.loading || status.pending ? <LoadingDiffSkeleton /> : null}
    </div>
  );
}
