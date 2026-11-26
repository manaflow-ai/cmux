// The Environment card and the changes pill (`agentPane.display.environmentCard` and
// `agentPane.display.changesPill`, both off by default; chatDisplay.ts), after the Codex app's
// Environment panel at the chat's top right and its "1 file changed +2 -2" over the composer. Each
// row is an action cmux already has, so a look can show them in that shape:
// - Changes: the chat folder's lines (Session Info's Changes row, changeCounts.ts), which open the
//   folder's diff beside the chat (the header's Changes).
// - The branch, or Worktree for a chat in a linked worktree (the header's worktree pill reads the same
//   `git.status`); a label, as Session Info's branch row is.
// - Commit or push: the diff tab's Commit form and Push, opened as the palette's Commit opens them.
// - Create pull request: the host's `git.pullRequest`, the changes view's Create PR (it pushes the
//   branch first and opens the pull request in the browser).
// A folder in no repository has no card. Codex's Create branch has no cmux action yet, so no row.
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { Counts } from "../changes/Counts";
import { PullRequestActionStatus, type PullRequestAction } from "../../../diff-viewer/PullRequestAction";
import type { ChangeCounts } from "./changeCounts";
import type { CardBranch } from "./environmentCardModel";
import "./environmentCard.css";

const ROW_ICON = rowIconSize(12);

function CardRow({
  icon,
  label,
  onClick,
  disabled = false,
  children,
}: {
  icon: string;
  label: string;
  onClick?: () => void;
  disabled?: boolean;
  children?: React.ReactNode;
}) {
  const content = (
    <>
      <Icon name={icon} size={ROW_ICON} row fit />
      <span className="acpmux-env-card__label">{label}</span>
      {children && <span className="acpmux-env-card__end">{children}</span>}
    </>
  );
  return (
    <li>
      {onClick ? (
        <button type="button" className="acpmux-env-card__row" disabled={disabled} onClick={onClick}>
          {content}
        </button>
      ) : (
        <span className="acpmux-env-card__row" data-static="">
          {content}
        </span>
      )}
    </li>
  );
}

export function EnvironmentCard({
  branch,
  changes,
  onOpenChanges,
  onCommitOrPush,
  pullRequest,
}: {
  /// The chat folder's branch (environmentCardModel.ts `useCardBranch`); undefined draws no card.
  branch?: CardBranch;
  changes?: ChangeCounts;
  onOpenChanges?: () => void;
  onCommitOrPush?: () => void;
  pullRequest?: PullRequestAction;
}) {
  const t = useT();
  if (!branch) return null;
  const title = t("rail.environment");
  const branchName = branch.worktree ? t("offer.options.worktree") : branch.branch;
  return (
    <section className="acpmux-env-card" aria-label={title}>
      <h2 className="acpmux-env-card__title">{title}</h2>
      <ul className="acpmux-env-card__rows">
        <CardRow icon="diff.file" label={t("header.changes")} onClick={changes ? onOpenChanges : undefined}>
          {changes && <Counts additions={changes.additions} deletions={changes.deletions} />}
        </CardRow>
        {branchName && (
          <CardRow icon={branch.worktree ? "git.worktree" : "git.branch"} label={branchName}>
            {branch.worktree && branch.branch && <span className="acpmux-env-card__note">{branch.branch}</span>}
          </CardRow>
        )}
        {onCommitOrPush && (
          <CardRow icon="action.sync" label={t("environmentCard.commitOrPush")} onClick={onCommitOrPush} />
        )}
        {pullRequest?.available && (
          <CardRow
            icon="brand.github"
            label={t("environmentCard.createPullRequest")}
            onClick={pullRequest.run}
            disabled={pullRequest.busy || branch.detached || !branch.branch}
          />
        )}
      </ul>
      {pullRequest && <PullRequestActionStatus action={pullRequest} />}
    </section>
  );
}

/// "1 file changed +2 -2" over the composer; a click opens the diff beside the chat.
export function ChangesPill({ changes, onOpen }: { changes?: ChangeCounts; onOpen?: () => void }) {
  const t = useT();
  if (!changes) return null;
  const files = changes.files ?? 0;
  const label =
    files === 1
      ? t("environmentCard.filesChanged.one")
      : files > 1
        ? t("environmentCard.filesChanged.other", { n: files })
        : t("header.changes");
  return (
    <div className="acpmux-changes-pill-row">
      <button type="button" className="acpmux-changes-pill" onClick={onOpen} disabled={!onOpen}>
        <span>{label}</span>
        <Counts additions={changes.additions} deletions={changes.deletions} />
      </button>
    </div>
  );
}
