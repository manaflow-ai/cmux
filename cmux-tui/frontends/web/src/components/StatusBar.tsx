import { useReducer } from "react";
import type { Id } from "cmux/browser";
import { t } from "../i18n";
import { useContextTrigger } from "../hooks/useContextTrigger";
import { contextMenuReducer } from "../lib/contextMenu";
import { renameCanCommit, renameReducer } from "../lib/rename";
import { screenSelection, type ScreenView, type WorkspaceView } from "../lib/tree";
import { ContextMenu } from "./ContextMenu";
import { InlineRename } from "./InlineRename";

interface ScreenChipProps {
  screen: ScreenView;
  number: number;
  onSelect(): void;
  onClose(screen: Id): void;
  onRename(screen: Id, name: string): void;
}

function ScreenChip({ screen, number, onSelect, onClose, onRename }: ScreenChipProps) {
  const [menu, dispatchMenu] = useReducer(contextMenuReducer, { open: false });
  const [rename, dispatchRename] = useReducer(renameReducer, null);
  const trigger = useContextTrigger((point) => dispatchMenu({ type: "open", point }));
  const commit = () => {
    if (!renameCanCommit(rename)) return;
    onRename(screen.id, rename.value.trim());
    dispatchRename({ type: "commit" });
  };
  return (
    <span className="screen-chip-wrap" {...trigger}>
      {rename?.kind === "screen" && rename.id === screen.id ? (
        <InlineRename
          value={rename.value}
          onChange={(value) => dispatchRename({ type: "change", value })}
          onCommit={commit}
          onCancel={() => dispatchRename({ type: "cancel" })}
        />
      ) : (
        <button className={`screen-chip${screen.active ? " active" : ""}`} onClick={onSelect} type="button">
          {screen.statusLabel ?? number}
        </button>
      )}
      {menu.open && (
        <ContextMenu
          point={menu.point}
          onClose={() => dispatchMenu({ type: "close" })}
          items={[
            {
              label: t("renameScreen"),
              onSelect: () => dispatchRename({ type: "begin", target: { kind: "screen", id: screen.id, value: screen.label } }),
            },
            { label: t("closeScreen"), danger: true, onSelect: () => onClose(screen.id) },
          ]}
        />
      )}
    </span>
  );
}

interface StatusBarProps {
  workspace: WorkspaceView | null;
  session: string | null;
  onSelectScreen(workspaceId: Id, screenId: Id, surface: Id | null): void;
  onNewScreen(workspace: Id): void;
  onCloseScreen(screen: Id): void;
  onRenameScreen(screen: Id, name: string): void;
}

export function StatusBar({
  workspace,
  session,
  onSelectScreen,
  onNewScreen,
  onCloseScreen,
  onRenameScreen,
}: StatusBarProps) {
  return (
    <footer className="status-bar">
      <span className="screens-label">{t("screens")}</span>
      {workspace?.screens.map((screen, index) => (
        <ScreenChip
          key={screen.id}
          screen={screen}
          number={index + 1}
          onSelect={() => onSelectScreen(...screenSelection(screen))}
          onClose={onCloseScreen}
          onRename={onRenameScreen}
        />
      ))}
      {workspace && (
        <button className="new-screen" aria-label={t("newScreen")} onClick={() => onNewScreen(workspace.id)} type="button">+</button>
      )}
      <span className="session-badge">[{session ?? "—"}]</span>
    </footer>
  );
}
