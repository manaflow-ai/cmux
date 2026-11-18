/// The studio look's words and glyphs (look/README.md): what the reference app says where cmux
/// says something else. This branch is the look, so the pane reads these directly.
export const STUDIO = {
  /// The composer's empty prompt and the New Tab field's, as the reference writes it.
  placeholder: "Ask anything. @ files, $ skills, / commands",
  /// The separator in the header's "project / chat title".
  crumbSlash: "/",
  /// The running tray's folded head over subagents only: "Waiting on 4 subagents".
  waitingOn: (n: number) => `Waiting on ${n} subagents`,
  /// A subagent batch's two words: "4 subagents", then "4 working" in the primary colour.
  subagents: (n: number) => (n === 1 ? "1 subagent" : `${n} subagents`),
  working: (n: number) => `${n} working`,
  /// The summary card's rows the reference app draws over its changes.
  openInEditor: "Open in editor",
  worktree: "Setup Worktree",
  commit: "Commit",
  lineage: "Lineage",
  lineageRunning: (n: number) => `Lineage · ${n} running`,
} as const;
