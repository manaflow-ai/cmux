import { useReducer, useRef, type TouchEvent } from "react";
import type { Id } from "cmux/browser";
import { t } from "../i18n";
import { contextMenuReducer } from "../lib/contextMenu";
import { renameCanCommit, renameReducer } from "../lib/rename";
import { screenSelection, type WorkspaceView } from "../lib/tree";
import { useContextTrigger } from "../hooks/useContextTrigger";
import { ContextMenu } from "./ContextMenu";
import { InlineRename } from "./InlineRename";

interface SidebarProps {
  open: boolean;
  workspaces: WorkspaceView[];
  onClose(): void;
  onSelect(workspaceId: Id, screenId: Id, surface: Id | null): void;
  onNewWorkspace(): void;
  onNewScreen(workspace: Id): void;
  onCloseWorkspace(workspace: Id): void;
  onRenameWorkspace(workspace: Id, name: string): void;
}

interface WorkspaceRowProps {
  workspace: WorkspaceView;
  onSelect(workspaceId: Id, screenId: Id, surface: Id | null): void;
  onNewScreen(workspace: Id): void;
  onClose(workspace: Id): void;
  onRename(workspace: Id, name: string): void;
}

function WorkspaceRow({ workspace, onSelect, onNewScreen, onClose, onRename }: WorkspaceRowProps) {
  const [menu, dispatchMenu] = useReducer(contextMenuReducer, { open: false });
  const [rename, dispatchRename] = useReducer(renameReducer, null);
  const trigger = useContextTrigger((point) => dispatchMenu({ type: "open", point }));
  const activeScreen = workspace.screens.find((screen) => screen.active) ?? workspace.screens[0];
  const commit = () => {
    if (!renameCanCommit(rename)) return;
    onRename(workspace.id, rename.value.trim());
    dispatchRename({ type: "commit" });
  };

  return (
    <div
      className={`workspace-row${workspace.active ? " active" : ""}`}
      {...trigger}
      onClick={() => {
        if (activeScreen) onSelect(...screenSelection(activeScreen));
      }}
      role="button"
      tabIndex={0}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key === "Enter" || event.key === " ") event.currentTarget.click();
      }}
    >
      <span className="workspace-rail" aria-hidden="true">▎</span>
      <span className="workspace-name">
        {rename?.kind === "workspace" && rename.id === workspace.id ? (
          <InlineRename
            value={rename.value}
            onChange={(value) => dispatchRename({ type: "change", value })}
            onCommit={commit}
            onCancel={() => dispatchRename({ type: "cancel" })}
          />
        ) : workspace.name}
      </span>
      <span className="workspace-subtitle">{workspace.subtitle}</span>
      {workspace.screens.some((screen) => screen.unread) && <span className="unread-dot" title={t("unread")} />}
      <span
        className="drawer-screen-list"
        onContextMenu={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
      >
        {workspace.screens.map((screen, index) => (
          <button
            aria-label={t("screen", { number: index + 1 })}
            className={`drawer-screen-chip${screen.active ? " active" : ""}`}
            key={screen.id}
            onClick={(event) => {
              event.stopPropagation();
              onSelect(...screenSelection(screen));
            }}
            type="button"
          >
            {index + 1}
          </button>
        ))}
        <button
          aria-label={t("newScreen")}
          className="drawer-screen-chip new"
          onClick={(event) => {
            event.stopPropagation();
            onNewScreen(workspace.id);
          }}
          type="button"
        >
          +
        </button>
      </span>
      {menu.open && (
        <ContextMenu
          point={menu.point}
          onClose={() => dispatchMenu({ type: "close" })}
          items={[
            {
              label: t("renameWorkspace"),
              onSelect: () => dispatchRename({ type: "begin", target: { kind: "workspace", id: workspace.id, value: workspace.name } }),
            },
            { label: t("newScreen"), onSelect: () => onNewScreen(workspace.id) },
            { label: t("closeWorkspace"), danger: true, onSelect: () => onClose(workspace.id) },
          ]}
        />
      )}
    </div>
  );
}

export function Sidebar({
  open,
  workspaces,
  onClose,
  onSelect,
  onNewWorkspace,
  onNewScreen,
  onCloseWorkspace,
  onRenameWorkspace,
}: SidebarProps) {
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
      <header>{t("workspaces")}</header>
      <nav aria-label={t("workspaces")}>
        <div className="workspace-list">
          {workspaces.length === 0 && <p className="empty-sidebar">{t("noSessions")}</p>}
          {workspaces.map((workspace) => (
            <WorkspaceRow
              key={workspace.id}
              workspace={workspace}
              onSelect={onSelect}
              onNewScreen={onNewScreen}
              onClose={onCloseWorkspace}
              onRename={onRenameWorkspace}
            />
          ))}
          <button className="new-workspace" onClick={onNewWorkspace} type="button">+ {t("newWorkspace")}</button>
        </div>
      </nav>
    </aside>
  );
}
