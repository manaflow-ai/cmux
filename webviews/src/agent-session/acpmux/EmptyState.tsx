import React from "react";
import type { AcpmuxSnapshot } from "./model";
import { type StringKey, useT } from "./i18n";
import { projectLabel } from "./sessionList";

/// Empty-state copy: keys of the pane's string table.
export const EMPTY_STATE_LABELS = {
  prompt: "empty.prompt",
  /// `{project}` is replaced by the session's folder name, drawn underlined.
  promptIn: "empty.promptIn",
} as const satisfies Record<string, StringKey>;

/// The hero's folder: the sidebar's project label, or nothing for no folder or the home folder.
export function projectName(cwd: string | undefined): string | undefined {
  if (!cwd?.replace(/\/+$/, "")) return undefined;
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

/// A new chat's hero, centered in place of the empty transcript and kept quiet:
/// a small prompt glyph and one line naming the session's project.
export function EmptyState({ project, onNew, onImport }: { project?: string; onNew?(): void; onImport?(): void }) {
  const t = useT();
  const [before, after] = t(EMPTY_STATE_LABELS.promptIn).split("{project}");
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
            <span className="acpmux-empty-project">{project}</span>
            {after}
          </>
        ) : (
          t(EMPTY_STATE_LABELS.prompt)
        )}
      </h2>
      <div className="acpmux-empty-actions">
        <button type="button" className="acpmux-empty-new" data-action="new" onClick={onNew}>
          {t("empty.new")}
        </button>
        <button type="button" className="acpmux-empty-import" data-action="import" onClick={onImport}>
          {t("empty.import")}
        </button>
      </div>
    </div>
  );
}
