import React from "react";
import { projectName } from "./EmptyState";
import type { AcpmuxSnapshot } from "./model";

/// Context-row copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const CONTEXT_LABELS = {
  project: "Project",
  branch: "Branch",
  worktree: "Worktree",
  noWorktree: "Works in the project folder, not a git worktree",
  on: "On",
  off: "Off",
};

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// Where the session runs, on the tray behind the composer: the project, the
/// machine and the branch as filled pills, and at the right whether the
/// session works in its own git worktree.
/// Each pill shows only when the daemon reports it.
export function ComposerContext({ summary }: { summary?: Summary }) {
  const project = projectName(summary?.cwd);
  const host = summary?.host;
  const branch = summary?.branch;
  if (!project && !host && !branch) return null;
  const worktree = summary?.worktree;
  return (
    <div className="acpmux-composer-context">
      {project && (
        <span className="acpmux-context-chip" title={`${CONTEXT_LABELS.project}: ${summary?.cwd}`}>
          <FolderIcon />
          <span>{project}</span>
        </span>
      )}
      {host && (
        <span className="acpmux-context-chip">
          {summary?.hostKind === "cloud" ? <CloudIcon /> : <LaptopIcon />}
          <span>{host}</span>
        </span>
      )}
      {branch && (
        <span className="acpmux-context-chip" title={`${CONTEXT_LABELS.branch}: ${branch}`}>
          {worktree ? <WorktreeIcon /> : <BranchIcon />}
          <span>{branch}</span>
        </span>
      )}
      {branch && (
        <span
          className={`acpmux-context-worktree${worktree ? " acpmux-on" : ""}`}
          title={worktree ? `${CONTEXT_LABELS.worktree}: ${worktree}` : CONTEXT_LABELS.noWorktree}
        >
          <span>{CONTEXT_LABELS.worktree}</span>
          <span
            className="acpmux-switch"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="img"
            aria-label={worktree ? CONTEXT_LABELS.on : CONTEXT_LABELS.off}
          />
        </span>
      )}
    </div>
  );
}

// Tray glyphs (16px box, stroke in currentColor), at the composer's icon weight.
function Icon({ children }: { children: React.ReactNode }) {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}
const FolderIcon = () => (
  <Icon>
    <path d="M2.25 4.75c0-.83.67-1.5 1.5-1.5h2.6l1.4 1.5h4.5c.83 0 1.5.67 1.5 1.5v5.5c0 .83-.67 1.5-1.5 1.5h-8.5c-.83 0-1.5-.67-1.5-1.5Z" />
    <path d="M2.25 6.75h11.5" />
  </Icon>
);
const LaptopIcon = () => (
  <Icon>
    <rect x="3.25" y="3.75" width="9.5" height="6.5" rx="1" />
    <path d="M1.75 12.25h12.5" />
  </Icon>
);
const CloudIcon = () => (
  <Icon>
    <path d="M4.75 12.25a2.75 2.75 0 0 1-.4-5.47 3.75 3.75 0 0 1 7.2-.78 3.13 3.13 0 0 1 .2 6.25Z" />
  </Icon>
);
const BranchIcon = () => (
  <Icon>
    <circle cx="5" cy="3.75" r="1.5" />
    <circle cx="5" cy="12.25" r="1.5" />
    <circle cx="11" cy="5.75" r="1.5" />
    <path d="M5 5.25v5.5M11 7.25c0 2.5-6 1.5-6 3.5" />
  </Icon>
);
const WorktreeIcon = () => (
  <Icon>
    <circle cx="4.75" cy="3.75" r="1.5" />
    <circle cx="4.75" cy="12.25" r="1.5" />
    <circle cx="11.25" cy="12.25" r="1.5" />
    <path d="M4.75 5.25v5.5M4.75 7.5c0 2 6.5 1.25 6.5 3.25" />
  </Icon>
);
