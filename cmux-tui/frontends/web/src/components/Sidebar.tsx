import { useRef, type TouchEvent } from "react";
import type { Id } from "cmux/browser";
import { t } from "../i18n";
import type { WorkspaceView } from "../lib/tree";

interface SidebarProps {
  open: boolean;
  workspaces: WorkspaceView[];
  onClose(): void;
  onSelect(workspaceIndex: number, screenIndex: number, surface: Id | null): void;
}

export function Sidebar({ open, workspaces, onClose, onSelect }: SidebarProps) {
  const touchStartX = useRef<number | null>(null);
  const startSwipe = (event: TouchEvent) => {
    touchStartX.current = event.changedTouches[0]?.clientX ?? null;
  };
  const finishSwipe = (event: TouchEvent) => {
    const start = touchStartX.current;
    touchStartX.current = null;
    const end = event.changedTouches[0]?.clientX;
    if (start !== null && end !== undefined && start - end > 50) onClose();
  };

  return (
    <aside className={`sidebar${open ? " open" : ""}`} onTouchStart={startSwipe} onTouchEnd={finishSwipe}>
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
