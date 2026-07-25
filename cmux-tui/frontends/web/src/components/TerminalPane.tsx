import { memo, useCallback, useMemo, useReducer, useRef, useState } from "react";
import type { ClientInfo, CmuxClient, Id, LivePane, Tab } from "cmux/browser";
import { t } from "../i18n";
import type { PaneLayoutView } from "../lib/layout";
import { layoutToViewModel, visibleStackPanes } from "../lib/layout";
import type { ScreenView } from "../lib/tree";
import { contextMenuReducer } from "../lib/contextMenu";
import { clientSizingMenuItems, paneClientSummary } from "../lib/clientSizing";
import { renameCanCommit, renameReducer } from "../lib/rename";
import { splitDividerTarget, splitRatioFromPointer, splitRatioToCommit } from "../lib/splitDrag";
import { useContextTrigger } from "../hooks/useContextTrigger";
import { ByteTerminal } from "./ByteTerminal";
import { ContextMenu } from "./ContextMenu";
import { InlineRename } from "./InlineRename";
import { RenderTerminal } from "./RenderTerminal";

interface TerminalPaneProps {
  client: CmuxClient | null;
  clients: ClientInfo[];
  screen: ScreenView | null;
  onRefreshClients(): void;
  onSetClientSizing(client: Id, enabled: boolean): void;
  onUseOnlyClientSizing(client: Id): void;
  onUseAllClientSizing(): void;
  onDetachClient(client: Id): void;
  onSelectTab(pane: Id, index: number, surface: Id): void;
  onNewTab(pane: Id): void;
  onSplit(pane: Id, dir: "right" | "down"): void;
  onSetSplitRatio(split: Id, ratio: number): Promise<boolean>;
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

interface PaneLeafProps extends Omit<TerminalPaneProps, "screen" | "onSetSplitRatio"> {
  pane: LivePane | null;
  paneId: Id;
  active: boolean;
  zoomed: boolean;
  focusTerminalOnMount?: boolean;
}

function PaneLeaf({
  client,
  clients,
  pane,
  paneId,
  active,
  zoomed,
  focusTerminalOnMount = false,
  onSelectTab,
  onNewTab,
  onSplit,
  onSelectPane,
  onZoomPane,
  onClosePane,
  onCloseSurface,
  onRenamePane,
  onRenameSurface,
  onRefreshClients,
  onSetClientSizing,
  onUseOnlyClientSizing,
  onUseAllClientSizing,
  onDetachClient,
}: PaneLeafProps) {
  const [menu, dispatchMenu] = useReducer(contextMenuReducer, { open: false });
  const [clientMenu, dispatchClientMenu] = useReducer(contextMenuReducer, { open: false });
  const [rename, dispatchRename] = useReducer(renameReducer, null);
  const trigger = useContextTrigger((point) => {
    dispatchMenu({ type: "open", point });
    onRefreshClients();
  });
  const { onPointerDown: startLongPress, ...contextTrigger } = trigger;
  const [errorState, setErrorState] = useState<{
    client: CmuxClient | null;
    surface: Id | null;
    message: string;
  } | null>(null);
  const tab = pane?.tabs[pane.active_tab] ?? null;
  const surface = tab?.kind === "pty" && !tab.dead ? tab.surface : null;
  const clientSummary = paneClientSummary(clients, surface);
  const clientItems = clientSummary ? clientSizingMenuItems(clientSummary, {
    setParticipation: onSetClientSizing,
    useOnly: onUseOnlyClientSizing,
    useAll: onUseAllClientSizing,
    detach: onDetachClient,
  }) : [];
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
              focusOnMount={focusTerminalOnMount}
              onError={reportError}
            />
          ) : surface !== null ? (
            <ByteTerminal
              client={client}
              surface={surface}
              error={terminalError}
              focusOnMount={focusTerminalOnMount}
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
      <div className="pane-bottom">
        <span className="pane-corner" aria-hidden="true">└</span>
        {clientSummary && (
          <button
            aria-expanded={clientMenu.open}
            aria-haspopup="menu"
            className="pane-clients-trigger"
            onClick={(event) => {
              const rect = event.currentTarget.getBoundingClientRect();
              dispatchClientMenu({ type: "open", point: { x: rect.left, y: rect.bottom } });
              onRefreshClients();
            }}
            type="button"
          >
            {clientSummary.label}
          </button>
        )}
        <span className="pane-rule" />
        <span className="pane-corner" aria-hidden="true">┘</span>
      </div>
      {clientMenu.open && clientSummary && (
        <ContextMenu
          point={clientMenu.point}
          onClose={() => dispatchClientMenu({ type: "close" })}
          items={clientItems}
        />
      )}
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
            ...(clientSummary ? [{ label: clientSummary.label, children: clientItems }] : []),
            { label: t("closePane"), danger: true, onSelect: () => onClosePane(paneId) },
          ]}
        />
      )}
    </section>
  );
}

interface LayoutNodeProps extends Omit<TerminalPaneProps, "screen"> {
  node: PaneLayoutView;
  paneById: ReadonlyMap<Id, LivePane>;
  screen: ScreenView;
  basis?: number;
}

interface LayoutGroupNodeProps extends Omit<LayoutNodeProps, "node"> {
  node: Extract<PaneLayoutView, { type: "group" }>;
}

const KEYBOARD_RESIZE_DEBOUNCE_MS = 100;

interface LayoutStackNodeProps extends Omit<LayoutNodeProps, "node"> {
  node: Extract<PaneLayoutView, { type: "stack" }>;
}

interface StackPaneHeaderProps {
  label: string;
  pane: Id;
  onSelect(pane: Id): void;
}

const StackPaneHeader = memo(function StackPaneHeader({
  label,
  pane,
  onSelect,
}: StackPaneHeaderProps) {
  return (
    <div className="pane-leaf collapsed">
      <button
        aria-label={t("pane", { number: pane })}
        className="stack-pane-header"
        onClick={() => onSelect(pane)}
        type="button"
      >
        <span aria-hidden="true">┌</span>
        <span className="stack-pane-title">{label}</span>
        <span aria-hidden="true">┐</span>
      </button>
    </div>
  );
});

function LayoutStackNode({
  node,
  screen,
  paneById,
  basis,
  onSelectPane,
  ...actions
}: LayoutStackNodeProps) {
  const style = basis === undefined ? undefined : { flex: `0 0 ${basis}%` };
  const panes = visibleStackPanes(node.panes, node.expanded, null);
  const expandedIndex = panes.indexOf(node.expanded);
  const expandedPane = paneById.get(node.expanded) ?? null;
  const [focusRequest, setFocusRequest] = useState<Id | null>(null);
  const selectHeader = useCallback((pane: Id) => {
    setFocusRequest(pane);
    onSelectPane(pane);
  }, [onSelectPane]);
  const renderHeader = (pane: Id) => {
    const livePane = paneById.get(pane) ?? null;
    const activeTab = livePane?.tabs[livePane.active_tab] ?? null;
    const label = livePane?.name || activeTab?.name || activeTab?.title || t("pane", { number: pane });
    return <StackPaneHeader key={pane} label={label} pane={pane} onSelect={selectHeader} />;
  };
  return (
    <div className="pane-stack" style={style}>
      <div className="stack-pane-headers before">
        {panes.slice(0, expandedIndex).map(renderHeader)}
      </div>
      <div className="pane-leaf expanded" key={node.expanded}>
        <PaneLeaf
          {...actions}
          onSelectPane={onSelectPane}
          pane={expandedPane}
          paneId={node.expanded}
          active={screen.activePane === node.expanded}
          focusTerminalOnMount={focusRequest === node.expanded}
          zoomed={screen.zoomedPane === node.expanded}
        />
      </div>
      <div className="stack-pane-headers after">
        {panes.slice(expandedIndex + 1).map(renderHeader)}
      </div>
    </div>
  );
}

function LayoutGroupNode({ node, screen, paneById, basis, ...actions }: LayoutGroupNodeProps) {
  const style = basis === undefined ? undefined : { flex: `0 0 ${basis}%` };
  const authoritativeRatio = node.firstPercent / 100;
  const target = splitDividerTarget(node);
  const [previewRatio, setPreviewRatio] = useState<number | null>(null);
  const [pendingRatio, setPendingRatio] = useState<{
    requestId: number;
    validRatios: number[];
    ratio: number;
    split: Id;
  } | null>(null);
  const nextRequestId = useRef(0);
  const activeRequestId = useRef<number | null>(null);
  const keyboardGeneration = useRef(0);
  const keyboardResize = useRef<{
    desiredRatio: number;
    generation: number;
    inFlightRatio: number | null;
    scheduled: ReturnType<typeof setTimeout> | null;
    split: Id;
  } | null>(null);
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
  const keyboardRequestActive = keyboardResize.current?.split === target.split
    && (keyboardResize.current.inFlightRatio !== null || keyboardResize.current.scheduled !== null);
  const pendingConfirmed = !keyboardRequestActive
    && pendingRatio !== null
    && target.split === pendingRatio.split
    && Math.abs(authoritativeRatio - pendingRatio.ratio) <= 1e-6;
  const pendingValid = !pendingConfirmed
    && pendingRatio !== null
    && target.split === pendingRatio.split
    && pendingRatio.validRatios.some((ratio) => Math.abs(authoritativeRatio - ratio) <= 1e-6);
  const reconcileDividerRef = useCallback((divider: HTMLDivElement | null) => {
    if (divider === null) {
      keyboardGeneration.current += 1;
      keyboardResize.current = null;
      return;
    }
    if (!pendingConfirmed) return;
    activeRequestId.current = null;
    keyboardResize.current = null;
    setPendingRatio(null);
  }, [pendingConfirmed]);

  const firstRatio = previewRatio ?? (pendingValid && pendingRatio !== null ? pendingRatio.ratio : authoritativeRatio);
  const firstPercent = firstRatio * 100;
  const secondPercent = 100 - firstPercent;
  const dividerStyle = node.direction === "row"
    ? { left: `${firstPercent}%` }
    : { top: `${firstPercent}%` };

  const commitRatio = (previousRatio: number, nextRatio: number) => {
    const ratio = splitRatioToCommit(previousRatio, nextRatio);
    if (ratio === null) {
      setPreviewRatio(null);
      return;
    }
    const requestId = ++nextRequestId.current;
    activeRequestId.current = requestId;
    setPreviewRatio(null);
    setPendingRatio({
      requestId,
      validRatios: [previousRatio],
      ratio,
      split: target.split,
    });
    keyboardGeneration.current += 1;
    keyboardResize.current = null;
    void actions.onSetSplitRatio(target.split, ratio).catch(() => false).then((succeeded) => {
      if (succeeded || activeRequestId.current !== requestId) return;
      activeRequestId.current = null;
      setPendingRatio(null);
      setPreviewRatio(null);
    });
  };

  function scheduleKeyboardResize(resize: NonNullable<typeof keyboardResize.current>) {
    if (keyboardResize.current !== resize || keyboardGeneration.current !== resize.generation) return;
    if (resize.scheduled !== null) clearTimeout(resize.scheduled);
    resize.scheduled = setTimeout(() => {
      if (keyboardResize.current !== resize || keyboardGeneration.current !== resize.generation) return;
      resize.scheduled = null;
      pumpKeyboardResize(resize);
    }, KEYBOARD_RESIZE_DEBOUNCE_MS);
  }

  function pumpKeyboardResize(resize: NonNullable<typeof keyboardResize.current>) {
    if (keyboardResize.current !== resize || resize.inFlightRatio !== null) return;
    const ratio = resize.desiredRatio;
    resize.inFlightRatio = ratio;
    void actions.onSetSplitRatio(resize.split, ratio).catch(() => false).then((succeeded) => {
      if (keyboardResize.current !== resize || keyboardGeneration.current !== resize.generation) return;
      resize.inFlightRatio = null;
      if (!succeeded) {
        keyboardGeneration.current += 1;
        keyboardResize.current = null;
        activeRequestId.current = null;
        setPendingRatio(null);
        setPreviewRatio(null);
        return;
      }
      if (Math.abs(resize.desiredRatio - ratio) > 1e-6) {
        if (resize.scheduled === null) scheduleKeyboardResize(resize);
      } else {
        setPendingRatio((current) => current === null ? current : { ...current });
      }
    });
  }

  return (
    <div className={`pane-group ${node.direction}`} style={style}>
      <LayoutNode
        {...actions}
        node={node.first}
        screen={screen}
        paneById={paneById}
        basis={firstPercent}
      />
      <div
          aria-valuemax={95}
          aria-valuemin={5}
          aria-valuenow={Math.round(firstPercent)}
          aria-orientation={node.direction === "row" ? "vertical" : "horizontal"}
          className="split-divider"
          ref={reconcileDividerRef}
          role="separator"
          style={dividerStyle}
          tabIndex={0}
          onKeyDown={(event) => {
            const delta = node.direction === "row"
              ? event.key === "ArrowLeft" ? -0.05 : event.key === "ArrowRight" ? 0.05 : null
              : event.key === "ArrowUp" ? -0.05 : event.key === "ArrowDown" ? 0.05 : null;
            if (delta === null) return;
            event.preventDefault();
            event.stopPropagation();
            if (pendingRatio && !pendingValid && !pendingConfirmed) {
              activeRequestId.current = null;
              setPendingRatio(null);
              keyboardGeneration.current += 1;
              keyboardResize.current = null;
            }
            const existingResize = keyboardResize.current;
            const canReuseResize = existingResize?.split === target.split && (pendingValid || pendingConfirmed);
            const baseRatio = canReuseResize
              ? existingResize.desiredRatio
              : pendingValid && pendingRatio !== null
                ? pendingRatio.ratio
                : authoritativeRatio;
            const ratio = Math.max(0.05, Math.min(0.95, baseRatio + delta));
            if (Math.abs(ratio - baseRatio) <= 1e-6) return;
            const resize = canReuseResize
              ? existingResize
              : {
                  desiredRatio: baseRatio,
                  generation: ++keyboardGeneration.current,
                  inFlightRatio: null,
                  scheduled: null,
                  split: target.split,
                };
            resize.desiredRatio = ratio;
            keyboardResize.current = resize;
            const requestId = ++nextRequestId.current;
            activeRequestId.current = requestId;
            const validRatios = [authoritativeRatio, baseRatio, ratio];
            if (resize.inFlightRatio !== null) validRatios.push(resize.inFlightRatio);
            setPendingRatio({ requestId, validRatios, ratio, split: target.split });
            setPreviewRatio(null);
            scheduleKeyboardResize(resize);
          }}
          onPointerDown={(event) => {
            if (event.pointerType === "mouse" && event.button !== 0) return;
            if (pendingRatio && pendingValid) return;
            keyboardGeneration.current += 1;
            keyboardResize.current = null;
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
            commitRatio(currentDrag.initialRatio, nextRatio);
          }}
          onPointerCancel={(event) => {
            if (!drag.current || drag.current.pointerId !== event.pointerId) return;
            drag.current = null;
            setPreviewRatio(null);
          }}
        />
      <LayoutNode
        {...actions}
        node={node.second}
        screen={screen}
        paneById={paneById}
        basis={secondPercent}
      />
    </div>
  );
}

function LayoutNode({ node, screen, paneById, basis, ...actions }: LayoutNodeProps) {
  const style = basis === undefined ? undefined : { flex: `0 0 ${basis}%` };
  if (node.type === "group") {
    // Switching screens or replacing the authoritative split remounts the
    // group and drops drag/pending overlay state without an imperative reset.
    return (
      <LayoutGroupNode
        key={`${screen.id}:${node.split}`}
        {...actions}
        node={node}
        screen={screen}
        paneById={paneById}
        basis={basis}
      />
    );
  }
  if (node.type === "stack") {
    return (
      <LayoutStackNode
        {...actions}
        node={node}
        screen={screen}
        paneById={paneById}
        basis={basis}
      />
    );
  }
  return (
    <div className="pane-leaf" style={style}>
      <PaneLeaf
        {...actions}
        pane={paneById.get(node.pane) ?? null}
        paneId={node.pane}
        active={screen.activePane === node.pane}
        zoomed={screen.zoomedPane === node.pane}
      />
    </div>
  );
}

export function TerminalPane({ screen, ...props }: TerminalPaneProps) {
  const paneById = useMemo(
    () => new Map(screen?.panes.map((pane) => [pane.id, pane] as const) ?? []),
    [screen?.panes],
  );
  if (!screen) return <section className="terminal-empty terminal-root">{t("noSurface")}</section>;
  const node = layoutToViewModel(screen.layout, screen.zoomedPane, screen.activePane);
  return (
    <div className="pane-layout">
      <LayoutNode {...props} node={node} screen={screen} paneById={paneById} />
    </div>
  );
}
