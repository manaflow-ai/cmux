// A pull request's state as Changes draws it: by the glyph's shape, colored by the row
// (sessionInfo.css `[data-state]`), never by a word. Every state is a cmux pack icon, the same
// family as Sources' `git.pullrequest` and the Environment's `git.branch` (design/icons/source/
// agent-composer.json): open is `git.pullrequest`; merged curves its head into the base stem; a
// draft dots its head stem; closed (and an open one with conflicts) crosses out its head's arrow.
// The native panel draws the same names (native/changes.ts), so both read alike.
import { Icon } from "../icons/Icon";

export type PullRequestGlyphState = "open" | "draft" | "merged" | "closed" | "conflicting";

export const PULL_REQUEST_ICONS: Record<PullRequestGlyphState, string> = {
  open: "git.pullrequest",
  draft: "git.pullrequest.draft",
  merged: "git.pullrequest.merged",
  closed: "git.pullrequest.closed",
  conflicting: "git.pullrequest.closed",
};

export function PullRequestGlyph({ state, size }: { state: PullRequestGlyphState; size: number }) {
  return <Icon name={PULL_REQUEST_ICONS[state]} size={size} row className="acpmux-session-info-pr__glyph" />;
}
