import React from "react";

/// The git-branch glyph Claude and ChatGPT draw for a branch, one glyph for every branch NEXT draws
/// (the composer's branch, the folder picker's worktree and branch rows). Leo, 2026-11-22
/// (ask-f87d5d43b4): "use the same branch icon as chatgpt and claude". A trunk with one branch
/// curving off to a node at its top right.
export function BranchGlyph({ className = "acpmux-icon", size = 14 }: { className?: string; size?: number }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M4.5 2.5v8" />
      <circle cx="11.5" cy="4.5" r="1.75" />
      <circle cx="4.5" cy="12.25" r="1.75" />
      <path d="M11.5 6.25a5.25 5.25 0 0 1-5.25 5.25" />
    </svg>
  );
}
