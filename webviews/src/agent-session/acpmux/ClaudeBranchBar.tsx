// The branch bar over the composer, as Claude Code desktop draws it: "main ← claude/branch +N -N
// Create PR" in one quiet line (claudeLook.css). The branch is the chat's (`summary.branch`), the
// counts are every edit the chat's tool calls made (diff.ts `turnFiles` over all its rows), and
// Create PR asks the agent to open one. A chat with an open pull request names it instead. A chat
// with no branch draws nothing.
import { useMemo } from "react";
import { turnFiles } from "./diff";
import { useT } from "./i18n";
import { Icon } from "./icons/Icon";
import type { AcpmuxRow } from "./model";

/// The prompt Create PR sends.
// l10n-allow: the agent's instruction, not shown as UI copy.
export const CREATE_PR_PROMPT = "Create a pull request for this branch.";

export function ClaudeBranchBar({
  branch,
  base = "main",
  rows,
  pullRequest,
  disabled,
  onCreatePr,
}: {
  branch?: string;
  base?: string;
  rows: AcpmuxRow[];
  pullRequest?: { number: number; title?: string };
  disabled?: boolean;
  onCreatePr?: () => void;
}) {
  const t = useT();
  const totals = useMemo(() => {
    let additions = 0;
    let deletions = 0;
    for (const file of turnFiles(rows)) {
      additions += file.additions;
      deletions += file.deletions;
    }
    return { additions, deletions };
  }, [rows]);
  if (!branch || branch === base) return null;
  return (
    <div className="acpmux-claude-branch-bar" data-cmux-component="ClaudeBranchBar">
      <Icon name="git.branch" size={13} />
      <span className="acpmux-claude-branch-bar__base">{base}</span>
      <span className="acpmux-claude-branch-bar__arrow" aria-hidden="true">
        ←
      </span>
      <span className="acpmux-claude-branch-bar__head" title={branch}>
        {branch}
      </span>
      {(totals.additions > 0 || totals.deletions > 0) && (
        <span className="acpmux-claude-branch-bar__counts">
          <span className="cv-edit-diff__add">+{totals.additions}</span>
          <span className="cv-edit-diff__del">-{totals.deletions}</span>
        </span>
      )}
      {pullRequest ? (
        <span className="acpmux-claude-branch-bar__pr" title={pullRequest.title}>
          #{pullRequest.number}
        </span>
      ) : (
        onCreatePr && (
          <button
            type="button"
            className="acpmux-claude-branch-bar__create ui-btn"
            disabled={disabled}
            onClick={onCreatePr}
          >
            {t("changes.createPullRequest")}
          </button>
        )
      )}
    </div>
  );
}
