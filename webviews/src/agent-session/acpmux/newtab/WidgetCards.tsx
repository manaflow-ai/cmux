// The New Tab widget view (Debug Settings `newTab.widgets`, Leo 2026-10-18): soft cards under the
// create actions. Projects: this Mac, then its recent projects, the one a chat starts in checked; a
// pick is the location strip's. Needs you: the chats waiting on the user or that hit an error, each
// opened by a click and put away by its ×; a pointer over one shows its whole title and why.
import { useMemo, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import type { Project } from "../ProjectChooser";
import { Tooltip } from "../../../ui/Tooltip";
import { useNt } from "./strings";
import { attentionChats, loadDismissed, recentProjects, saveDismissed, type AttentionChat } from "./widgets";

export function WidgetCards({
  sessions,
  projects,
  folder,
  machineName,
  onProject,
  onOpen,
}: {
  sessions: AcpmuxSnapshot["sessions"];
  projects: readonly Project[];
  /// The folder a prompt starts in (the location strip's), checked in the Projects card.
  folder?: string;
  machineName?: string;
  onProject(cwd: string): void;
  onOpen(sessionId: string): void;
}) {
  const nt = useNt();
  const t = useT();
  const [dismissed, setDismissed] = useState(loadDismissed);
  const shownProjects = useMemo(() => recentProjects(projects, sessions), [projects, sessions]);
  const chats = useMemo(() => attentionChats(sessions, dismissed), [sessions, dismissed]);
  const dismiss = (chat: AttentionChat) => {
    const next = new Set(dismissed);
    next.add(chat.key);
    saveDismissed(next);
    setDismissed(next);
  };
  const stateLabel = (chat: AttentionChat) => (chat.state === "failed" ? t("header.failed") : nt(`card.${chat.state}`));
  if (!shownProjects.length && !chats.length) return null;
  return (
    <div className="nt-widgets">
      {shownProjects.length > 0 && (
        <section className="nt-widget" aria-label={nt("projects")}>
          <div className="nt-widget-row nt-widget-machine">
            <Icon name="machine.mac" size={16} className="nt-widget-icon" />
            <span className="nt-widget-label">{machineName ?? t("composer.thisMac")}</span>
          </div>
          <hr className="nt-widget-rule" />
          {shownProjects.map((project) => {
            const picked = project.cwd === folder;
            return (
              <button
                key={project.cwd}
                type="button"
                className="nt-widget-row"
                aria-pressed={picked}
                onClick={() => onProject(project.cwd)}
              >
                <Icon name="folder" size={16} className="nt-widget-icon" />
                <span className="nt-widget-label">{project.label}</span>
                {picked && <CheckMark />}
              </button>
            );
          })}
        </section>
      )}
      {chats.length > 0 && (
        <section className="nt-widget nt-widget-attention" aria-label={nt("widgets.attention")}>
          {chats.map((chat) => (
            <div key={chat.key} className="nt-widget-chat" data-state={chat.state}>
              {/* tooltip-allow: Leo's widget reference (2026-10-18) shows a hover card with the chat's whole title and why it needs the user, more than the cut row says. */}
              <Tooltip
                side="top"
                label={
                  <span className="nt-widget-tip">
                    <span className="nt-widget-tip-title">{chat.title}</span>
                    <span className="nt-widget-tip-detail">{chat.detail ?? stateLabel(chat)}</span>
                  </span>
                }
              >
                <button
                  type="button"
                  className="nt-widget-chat-open"
                  aria-label={nt("card.open", { title: chat.title })}
                  onClick={() => onOpen(chat.sessionId)}
                >
                  <span className="nt-widget-state">{stateLabel(chat)}</span>
                  <span className="nt-widget-title">{chat.title}</span>
                </button>
              </Tooltip>
              <button
                type="button"
                className="nt-widget-dismiss"
                aria-label={nt("widgets.dismiss", { title: chat.title })}
                onClick={() => dismiss(chat)}
              >
                <Icon name="action.close" size={14} />
              </button>
            </div>
          ))}
        </section>
      )}
    </div>
  );
}

function CheckMark() {
  return (
    <svg className="nt-widget-check" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M3.5 8.5L6.5 11.5L12.5 4.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
