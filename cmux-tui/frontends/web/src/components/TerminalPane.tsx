import { useCallback, useReducer, useRef, useState } from "react";
import type { CmuxClient, Id, LivePane, Tab } from "cmux/browser";
import { t } from "../i18n";
import type { PaneLayoutView } from "../lib/layout";
import { layoutToViewModel } from "../lib/layout";
import type { ScreenView } from "../lib/tree";
import { contextMenuReducer } from "../lib/contextMenu";
import { renameCanCommit, renameReducer } from "../lib/rename";
import { splitDividerTarget, splitRatioFromPointer, splitRatioToCommit } from "../lib/splitDrag";
import { useContextTrigger } from "../hooks/useContextTrigger";
import { ByteTerminal } from "./ByteTerminal";
import { ContextMenu } from "./ContextMenu";
import { InlineRename } from "./InlineRename";
import { RenderTerminal } from "./RenderTerminal";

interface TerminalPaneProps {
  client: CmuxClient | null;
  screen: ScreenView | null;
  onSelectTab(pane: Id, index: number, surface: Id): void;
  onNewTab(pane: Id): void;
  onSplit(pane: Id, dir: "right" | "down"): void;
  onSetRatio(pane: Id, dir: "right" | "down", ratio: number): Promise<boolean>;
  onSelectPane(pane: Id): void;
  onZoomPane(pane: Id): void;
  onClosePane(pane: Id): void;
  onCloseSurface(surface: Id): void;
  onRenamePane(pane: Id, name: string): void;
  onRenameSurface(surface: Id, name: string): void;
}

interface TabButtonProps {
  tab: Tab;
  index: number;
  pane: LivePane;
  onSelect(): void;
  onNewTab(): void;
  onClose(surface: Id): void;
  onRename(surface: Id, name: string): void;
}

function TabButton({ tab, index, pane, onSelect, onNewTab, onClose, onRename }: TabButtonProps) {
  const [menu, dispatchMenu] = useReducer(contextMenuReducer, { open: false });
  const [rename, dispatchRename] = useReducer(renameReducer, null);
  const trigger = useContextTrigger((point) => dispatchMenu({ type: "open", point }));
  const titleWords = tab.title.toLowerCase().split(/[^a-z0-9_-]+/);
  const agent = ["claude", "codex", "opencode", "pi"].find((candidate) => titleWords.includes(candidate));
  const label = tab.name || `${index + 1}${agent ? ` ${agent}` : ""}`;
  const commit = () => {
    if (!renameCanCommit(rename)) return;
    onRename(tab.surface, rename.value.trim());
    dispatchRename({ type: "commit" });
  };

  return (
    <span className="tab-wrap" {...trigger}>
      {rename?.kind === "surface" && rename.id === tab.surface ? (
        <InlineRename
          value={rename.value}
          onChange={(value) => dispatchRename({ type: "change", value })}
          onCommit={commit}
          onCancel={() => dispatchRename({ type: "cancel" })}
        />
      ) : (
        <button className={pane.active_tab === index ? "active" : ""} onClick={onSelect} type="button">
          <span className="tab-rail" aria-hidden="true">{pane.active_tab === index ? "▎" : " "}</span>
          <span className="tab-label">{label}</span>
        </button>
      )}
      {menu.open && (
        <ContextMenu
          point={menu.point}
          onClose={() => dispatchMenu({ type: "close" })}
          items={[
            {
              label: t("renameTab"),
              onSelect: () => dispatchRename({ type: "begin", target: { kind: "surface", id: tab.surface, value: label } }),
            },
            { label: t("newTabRight"), onSelect: onNewTab },
            { label: t("closeTab"), danger: true, onSelect: () => onClose(tab.surface) },
          ]}
        />
      )}
    </span>
  );
}

interface PaneLeafProps extends Omit<TerminalPaneProps, "screen" | "onSetRatio"> {
  pane: LivePane | null;
  paneId: Id;
  active: boolean;
  zoomed: boolean;
}

function PaneLeaf({
  client,
  pane,
  paneId,
  active,
  zoomed,
  onSelectTab,
  onNewTab,
  onSplit,
  onSelectPane,
  onZoomPane,
  onClosePane,
  onCloseSurface,
  onRenamePane,
  onRenameSurface,
}: PaneLeafProps) {
  const [menu, dispatchMenu] = useReducer(contextMenuReducer, { open: false });
  const [rename, dispatchRename] = useReducer(renameReducer, null);
  const trigger = useContextTrigger((point) => dispatchMenu({ type: "open", point }));
  const { onPointerDown: startLongPress, ...contextTrigger } = trigger;
  const [errorState, setErrorState] = useState<{
    client: CmuxClient | null;
    surface: Id | null;
    message: string;
  } | null>(null);
  const tab = pane?.tabs[pane.active_tab] ?? null;
  const surface = tab?.kind === "pty" && !tab.dead ? tab.surface : null;
  const reportError = useCallback(
    (error: Error) => setErrorState({ client, surface, message: error.message }),
    [client, surface],
  );
  const terminalError = errorState !== null && errorState.client === client && errorState.surface === surface
    ? errorState.message
    : null;
  const commitPaneRename = () => {
    if (!renameCanCommit(rename)) return;
    onRenamePane(paneId, rename.value.trim());
    dispatchRename({ type: "commit" });
  };

  return (
    <section
      aria-label={t("pane", { number: paneId })}
      className={`terminal-panel${active ? " active-pane" : ""}`}
      {...contextTrigger}
      onPointerDown={(event) => {
        startLongPress(event);
        if ((event.target as HTMLElement).closest(".tab-bar, .extra-keys")) return;
        if (!active) onSelectPane(paneId);
      }}
    >
      <div className="tab-bar">
        <span className="pane-corner" aria-hidden="true">┌</span>
        {rename?.kind === "pane" && rename.id === paneId && (
          <InlineRename
            value={rename.value}
            onChange={(value) => dispatchRename({ type: "change", value })}
            onCommit={commitPaneRename}
            onCancel={() => dispatchRename({ type: "cancel" })}
          />
        )}
        {pane?.tabs.map((candidate, index) => (
          <TabButton
            key={candidate.surface}
            tab={candidate}
            index={index}
            pane={pane}
            onSelect={() => onSelectTab(paneId, index, candidate.surface)}
            onNewTab={() => onNewTab(paneId)}
            onClose={onCloseSurface}
            onRename={onRenameSurface}
          />
        ))}
        <button className="new-tab" aria-label={t("newTab")} onClick={() => onNewTab(paneId)} type="button"> + </button>
        <span className="pane-rule" aria-hidden="true" />
        <span className="pane-corner" aria-hidden="true">┐</span>
      </div>
      <div className="pane-body">
        <span className="pane-side" aria-hidden="true" />
        <div className="pane-content">
          {surface !== null && client !== null && (client.protocol ?? 0) >= 7 ? (
            <RenderTerminal
              client={client}
              surface={surface}
              active={active}
              error={terminalError}
              onError={reportError}
            />
          ) : surface !== null ? (
            <ByteTerminal
              client={client}
              surface={surface}
              error={terminalError}
              onError={reportError}
            />
          ) : (
            <div className="terminal-stage">
              {!tab && <div className="terminal-empty">{t("noSurface")}</div>}
              {tab?.kind === "browser" && <div className="terminal-empty">{t("browserSurface")}</div>}
              {terminalError && <div className="terminal-error" role="alert">{terminalError}</div>}
            </div>
          )}
        </div>
        <span className="pane-side" aria-hidden="true" />
      </div>
      <div className="pane-bottom" aria-hidden="true">
        <span className="pane-corner">└</span>
        <span className="pane-rule" />
        <span className="pane-corner">┘</span>
      </div>
      {menu.open && (
        <ContextMenu
          point={menu.point}
          onClose={() => dispatchMenu({ type: "close" })}
          items={[
            { label: t("splitRight"), onSelect: () => onSplit(paneId, "right") },
            { label: t("splitDown"), onSelect: () => onSplit(paneId, "down") },
            {
              label: t("renamePane"),
              onSelect: () => dispatchRename({ type: "begin", target: { kind: "pane", id: paneId, value: pane?.name || "" } }),
            },
            { label: zoomed ? t("restorePane") : t("zoomPane"), onSelect: () => onZoomPane(paneId) },
            { label: t("closePane"), danger: true, onSelect: () => onClosePane(paneId) },
          ]}
        />
      )}
    </section>
  );
}

interface LayoutNodeProps extends Omit<TerminalPaneProps, "screen"> {
  node: PaneLayoutView;
  screen: ScreenView;
  basis?: number;
}

interface LayoutGroupNodeProps extends Omit<LayoutNodeProps, "node"> {
  node: Extract<PaneLayoutView, { type: "group" }>;
}

function LayoutGroupNode({ node, screen, basis, ...actions }: LayoutGroupNodeProps) {
  const style = basis === undefined ? undefined : { flex: `0 0 ${basis}%` };
  const authoritativeRatio = node.firstPercent / 100;
  const target = splitDividerTarget(node);
  const [previewRatio, setPreviewRatio] = useState<number | null>(null);
  const [pendingRatio, setPendingRatio] = useState<{
    requestId: number;
    previousRatio: number;
    ratio: number;
    pane: Id;
    dir: "right" | "down";
  } | null>(null);
  const nextRequestId = useRef(0);
  const activeRequestId = useRef<number | null>(null);
  const drag = useRef<{
    pointerId: number;
    bounds: DOMRect;
    initialRatio: number;
    lastRatio: number;
  } | null>(null);

  // Derived, not effect-driven: a pending commit is only trusted while it
  // still addresses this divider and the authoritative ratio hasn't moved
  // off the snapshot it was based on. The moment the server's layout event
  // lands (confirm or foreign change), validity flips and the authoritative
  // ratio renders; the stale record is cleared lazily on the next pointerdown.
  const pendingValid = pendingRatio !== null
    && target !== null
    && target.pane === pendingRatio.pane
    && target.dir === pendingRatio.dir
    && Math.abs(authoritativeRatio - pendingRatio.previousRatio) <= 1e-6;

  const firstRatio = previewRatio ?? (pendingValid && pendingRatio !== null ? pendingRatio.ratio : authoritativeRatio);
  const firstPercent = firstRatio * 100;
  const secondPercent = 100 - firstPercent;
  const dividerStyle = node.direction === "row"
    ? { left: `${firstPercent}%` }
    : { top: `${firstPercent}%` };

  return (
    <div className={`pane-group ${node.direction}`} style={style}>
      <LayoutNode {...actions} node={node.first} screen={screen} basis={firstPercent} />
      {target && (
        <div
          aria-orientation={node.direction === "row" ? "vertical" : "horizontal"}
          className="split-divider"
          role="separator"
          style={dividerStyle}
          onPointerDown={(event) => {
            if (event.pointerType === "mouse" && event.button !== 0) return;
            if (pendingRatio && pendingValid) return;
            if (pendingRatio) {
              activeRequestId.current = null;
              setPendingRatio(null);
            }
            const group = event.currentTarget.parentElement;
            if (!group) return;
            event.preventDefault();
            event.stopPropagation();
            event.currentTarget.setPointerCapture(event.pointerId);
            drag.current = {
              pointerId: event.pointerId,
              bounds: group.getBoundingClientRect(),
              initialRatio: authoritativeRatio,
              lastRatio: authoritativeRatio,
            };
          }}
          onPointerMove={(event) => {
            if (!drag.current || drag.current.pointerId !== event.pointerId) return;
            event.preventDefault();
            const ratio = splitRatioFromPointer(node.direction, event, drag.current.bounds);
            if (ratio === null) return;
            drag.current.lastRatio = ratio;
            setPreviewRatio(ratio);
          }}
          onPointerUp={(event) => {
            const currentDrag = drag.current;
            if (!currentDrag || currentDrag.pointerId !== event.pointerId) return;
            event.preventDefault();
            event.stopPropagation();
            const pointerRatio = splitRatioFromPointer(node.direction, event, currentDrag.bounds);
            const nextRatio = pointerRatio ?? currentDrag.lastRatio;
            drag.current = null;
            if (event.currentTarget.hasPointerCapture(event.pointerId)) {
              event.currentTarget.releasePointerCapture(event.pointerId);
            }
            const ratio = splitRatioToCommit(currentDrag.initialRatio, nextRatio);
            if (ratio === null) {
              setPreviewRatio(null);
              return;
            }
            const requestId = ++nextRequestId.current;
            activeRequestId.current = requestId;
            setPreviewRatio(null);
            setPendingRatio({
              requestId,
              previousRatio: currentDrag.initialRatio,
              ratio,
              pane: target.pane,
              dir: target.dir,
            });
            void actions.onSetRatio(target.pane, target.dir, ratio).then((succeeded) => {
              if (succeeded || activeRequestId.current !== requestId) return;
              activeRequestId.current = null;
              setPendingRatio(null);
              setPreviewRatio(null);
            });
          }}
          onPointerCancel={(event) => {
            if (!drag.current || drag.current.pointerId !== event.pointerId) return;
            drag.current = null;
            setPreviewRatio(null);
          }}
        />
      )}
      <LayoutNode {...actions} node={node.second} screen={screen} basis={secondPercent} />
    </div>
  );
}

function LayoutNode({ node, screen, basis, ...actions }: LayoutNodeProps) {
  const style = basis === undefined ? undefined : { flex: `0 0 ${basis}%` };
  if (node.type === "group") {
    // Keyed by screen so switching screens remounts the group and drops any
    // drag/pending overlay state, replacing an imperative reset effect.
    return <LayoutGroupNode key={screen.id} {...actions} node={node} screen={screen} basis={basis} />;
  }
  return (
    <div className="pane-leaf" style={style}>
      <PaneLeaf
        {...actions}
        pane={screen.panes.find((pane) => pane.id === node.pane) ?? null}
        paneId={node.pane}
        active={screen.activePane === node.pane}
        zoomed={screen.zoomedPane === node.pane}
      />
    </div>
  );
}

export function TerminalPane({ screen, ...props }: TerminalPaneProps) {
  if (!screen) return <section className="terminal-empty terminal-root">{t("noSurface")}</section>;
  const node = layoutToViewModel(screen.layout, screen.zoomedPane);
  return <div className="pane-layout"><LayoutNode {...props} node={node} screen={screen} /></div>;
}
