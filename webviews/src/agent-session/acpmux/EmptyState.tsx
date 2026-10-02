import React from "react";

/// Empty-state copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const EMPTY_STATE_LABELS = {
  prompt: "What should we build?",
  /// `{project}` is replaced by the session's folder name, drawn underlined.
  promptIn: "What should we build in {project}?",
};

/// The folder name of a session's working directory, or nothing for the root or no directory.
export function projectName(cwd: string | undefined): string | undefined {
  const name = cwd?.replace(/[\\/]+$/, "").split(/[\\/]/).pop();
  return name || undefined;
}

/// A new chat's hero, centered over the empty transcript as Codex's home and
/// new-chat screens draw it, quieter: a small prompt glyph and one line naming
/// the session's project.
export function EmptyState({ project }: { project?: string }) {
  const [before, after] = EMPTY_STATE_LABELS.promptIn.split("{project}");
  return <div className="acpmux-empty">
    <svg className="acpmux-empty-glyph" width={36} height={36} viewBox="0 0 36 36" fill="none" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <rect x="4.75" y="6.75" width="26.5" height="22.5" rx="6" />
      <path d="m11.5 14.5 3.5 3.5-3.5 3.5M18.5 22h6" />
    </svg>
    <h2 className="acpmux-empty-title">{project ? <>{before}<span className="acpmux-empty-project">{project}</span>{after}</> : EMPTY_STATE_LABELS.prompt}</h2>
  </div>;
}
