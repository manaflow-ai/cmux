// The card above a git scope's diffs when the host left untracked files out to stay
// responsive. Copy cleanup command copies `git clean -ndX`, which only lists the ignored files
// git clean would remove; Refresh asks for the scope again.
import { AlertCircle } from "../changeIcons";
import { copyText } from "../conversation/clipboard";

export function TrackedOnlyBanner({ skipped, onRefresh }: { skipped: number; onRefresh: () => void }) {
  return (
    // An <output> holds only phrasing content, and this card holds blocks and buttons.
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="acpmux-changes-banner" role="status">
      <AlertCircle className="acpmux-changes-banner-icon" />
      <div className="acpmux-changes-banner-text">
        <div className="acpmux-changes-banner-title">Showing tracked changes only</div>
        <div className="acpmux-changes-banner-body">
          {`The Changes tab skipped ${skipped.toLocaleString("en-US")} untracked files to stay responsive. If these files are generated, clean them up and refresh`}
        </div>
      </div>
      <span className="acpmux-changes-banner-divider" />
      <button type="button" className="acpmux-changes-banner-action" onClick={() => void copyText("git clean -ndX")}>
        Copy cleanup command
      </button>
      <button type="button" className="acpmux-changes-banner-refresh" onClick={onRefresh}>
        Refresh
      </button>
    </div>
  );
}
