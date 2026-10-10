import React from "react";
import type { AcpmuxSnapshot } from "./model";
import { FolderIcon } from "./NewTabPage";
import { ProjectChooser, type Project } from "./ProjectChooser";
import { type StringKey, useT } from "./i18n";
import { isAgentHome, projectLabel } from "./sessionList";

/// Empty-state copy: keys of the pane's string table.
export const EMPTY_STATE_LABELS = {
  prompt: "empty.prompt",
  /// `{project}` is replaced by the session's folder name, drawn underlined.
  promptIn: "empty.promptIn",
} as const satisfies Record<string, StringKey>;

/// The hero's folder: the sidebar's project label, or nothing for no folder or the home folder.
export function projectName(cwd: string | undefined): string | undefined {
  if (!cwd?.replace(/\/+$/, "") || isAgentHome(cwd)) return undefined;
  const label = projectLabel(cwd);
  return label === "~" ? undefined : label;
}

/// A new chat has no turns, rows or queued work. The host can identify an unsent
/// chat before a summary exists; attached chats use their own session's summary.
/// A daemon that doesn't count turns still exposes older history for an old session.
export function isNewChat(snapshot: AcpmuxSnapshot, newSession = false): boolean {
  const summary = snapshot.summary;
  // The host knows a direct chat is new before an agent can produce a summary.
  // Keep its conversion and project controls usable while that agent starts.
  if (newSession && !summary && !snapshot.sessionId && !snapshot.canLoadOlder)
    return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0;
  // A harness switch's new chat has no session yet; its summary is the one the switch draws.
  if (!summary || (summary.sessionId !== snapshot.sessionId && !snapshot.switching)) return false;
  if (/^(connecting|disconnected|failed)/.test(snapshot.connection)) return false;
  const turns = summary.turnCount ?? (snapshot.canLoadOlder ? 1 : 0);
  return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0 && turns === 0;
}

/// The hero's project picker (cx-9g0w): the chat's folder choices and what a pick does.
export type EmptyStateProjects = {
  projects: Project[];
  /// The chat's project folder; none in no project (the agent-home folder).
  current?: string;
  currentPeer?: string;
  onPick(cwd: string, peer?: string): void;
  onBrowse?(): void;
  onNoProject?(): void;
};

/// A new chat's hero, centered in place of the empty transcript and kept quiet:
/// a small prompt glyph and one line naming the session's project. With `picker` the project's
/// name is a picker (ChatGPT style): a pick moves the new chat to that folder.
export function EmptyState({ project, picker }: { project?: string; picker?: EmptyStateProjects }) {
  const t = useT();
  const [before, after] = t(EMPTY_STATE_LABELS.promptIn).split("{project}");
  const chooser = picker && (
    <ProjectChooser
      projects={picker.projects}
      current={picker.current}
      currentPeer={picker.currentPeer}
      {...(project ? { currentLabel: project } : {})}
      icon={<FolderIcon />}
      onPick={picker.onPick}
      onBrowse={picker.onBrowse}
      onNoProject={picker.onNoProject}
      side="bottom"
      inline
    />
  );
  return (
    <div className="acpmux-empty">
      <svg
        className="acpmux-empty-glyph"
        width={36}
        height={36}
        viewBox="0 0 36 36"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.5}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <rect x="4.75" y="6.75" width="26.5" height="22.5" rx="6" />
        <path d="m11.5 14.5 3.5 3.5-3.5 3.5M18.5 22h6" />
      </svg>
      <h2 className="acpmux-empty-title">
        {project ? (
          <>
            {before}
            {chooser ?? <span className="acpmux-empty-project">{project}</span>}
            {after}
          </>
        ) : (
          t(EMPTY_STATE_LABELS.prompt)
        )}
      </h2>
      {/* No project yet: the picker sits under the question, so a folder can still be chosen. */}
      {!project && chooser && <div className="acpmux-empty-choose">{chooser}</div>}
    </div>
  );
}
