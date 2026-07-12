import type { Id } from "cmux/browser";
import { t } from "../i18n";
import type { WorkspaceView } from "../lib/tree";

interface SidebarProps {
  workspaces: WorkspaceView[];
  onSelect(workspaceIndex: number, screenIndex: number, surface: Id | null): void;
}

export function Sidebar({ workspaces, onSelect }: SidebarProps) {
  return (
    <aside className="sidebar">
      <header><span className="traffic-dot" />{t("workspaces")}</header>
      <nav aria-label={t("workspaces")}>
        {workspaces.length === 0 && <p className="empty-sidebar">{t("noSessions")}</p>}
        {workspaces.map((workspace) => (
          <section key={workspace.id}>
            <h2>{workspace.name}</h2>
            {workspace.screens.map((screen, index) => (
              <button
                className={`screen-row${screen.active ? " active" : ""}`}
                key={screen.id}
                onClick={() => onSelect(screen.workspaceIndex, screen.screenIndex, screen.tab?.surface ?? null)}
                type="button"
              >
                <span className="screen-icon" aria-hidden="true">▱</span>
                <span>{screen.label || t("screen", { number: index + 1 })}</span>
                {screen.unread && <span className="unread-dot" title={t("unread")} />}
              </button>
            ))}
          </section>
        ))}
      </nav>
    </aside>
  );
}
