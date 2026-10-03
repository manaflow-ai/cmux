// The card above a git scope's diffs when the host left untracked files out to stay
// responsive. Copy cleanup command copies `git clean -nd`, a dry run that lists the untracked
// files the scope left out (the host counts the ones .gitignore does not cover, so `-X`, which
// lists only ignored files, would list none of them); Refresh asks for the scope again.
import { AlertCircle } from "../changeIcons";
import { copyText } from "../conversation/clipboard";

export function TrackedOnlyBanner({ skipped, onRefresh }: { skipped: number; onRefresh: () => void }) {
  const files = skipped === 1 ? "file" : "files";
  return (
    <div className="acpmux-changes-banner">
      <AlertCircle className="acpmux-changes-banner-icon" />
      {/* Only the message is announced, not the buttons beside it. An <output> holds only
          phrasing content, and the message holds blocks. */}
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
      <div className="acpmux-changes-banner-text" role="status">
        <div className="acpmux-changes-banner-title">Showing tracked changes only</div>
        <div className="acpmux-changes-banner-body">
          {`The Changes tab skipped ${skipped.toLocaleString("en-US")} untracked ${files} to stay responsive. If these files are generated, clean them up and refresh`}
        </div>
      </div>
      <span className="acpmux-changes-banner-divider" />
      <button type="button" className="acpmux-changes-banner-action" onClick={() => void copyText("git clean -nd")}>
        Copy cleanup command
      </button>
      <button type="button" className="acpmux-changes-banner-refresh" onClick={onRefresh}>
        Refresh
      </button>
    </div>
  );
}
