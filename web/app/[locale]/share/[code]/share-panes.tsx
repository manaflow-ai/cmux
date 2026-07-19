"use client";

// Workspace pane tree: recursive split layout plus the terminal pane canvas.
// Canvases paint imperatively from the ShareClient's grid models; React only
// re-renders on layout changes, never per grid frame.

import { createContext, useContext, useRef, type ReactNode } from "react";
import { useTranslations } from "next-intl";

import type { ShareClient } from "./share-connection";
import type { LayoutNode } from "./share-protocol";
import { paintGrid } from "./terminal-grid";
import { keyEventToBytes } from "./terminal-keys";

export interface PaneRectRegistry {
  register(paneKey: string, el: HTMLElement | null): void;
  get(paneKey: string): HTMLElement | null;
}

export function createPaneRectRegistry(): PaneRectRegistry {
  const panes = new Map<string, HTMLElement>();
  return {
    register(paneKey, el) {
      if (el) panes.set(paneKey, el);
      else panes.delete(paneKey);
    },
    get(paneKey) {
      return panes.get(paneKey) ?? null;
    },
  };
}

const PaneRegistryContext = createContext<PaneRectRegistry | null>(null);
export const PaneRegistryProvider = PaneRegistryContext.Provider;

export const paneKeyOf = (ws: string, pane: string) => `${ws} ${pane}`;

export function LayoutView({
  client,
  ws,
  node,
  canType,
}: {
  client: ShareClient;
  ws: string;
  node: LayoutNode | null;
  canType: boolean;
}): ReactNode {
  const t = useTranslations("share");
  if (!node) {
    return (
      <div className="flex h-full w-full items-center justify-center text-xs text-muted">
        {t("emptyWorkspace")}
      </div>
    );
  }
  if (node.kind === "split") {
    const ratio = Math.min(0.95, Math.max(0.05, node.ratio));
    return (
      <div className={`flex h-full w-full ${node.axis === "h" ? "flex-row" : "flex-col"}`}>
        <div style={{ flexBasis: `${ratio * 100}%` }} className="min-h-0 min-w-0">
          <LayoutView client={client} ws={ws} node={node.a} canType={canType} />
        </div>
        <div
          className={
            node.axis === "h" ? "w-px shrink-0 bg-border" : "h-px shrink-0 bg-border"
          }
        />
        <div style={{ flexBasis: `${(1 - ratio) * 100}%` }} className="min-h-0 min-w-0">
          <LayoutView client={client} ws={ws} node={node.b} canType={canType} />
        </div>
      </div>
    );
  }
  if (node.content === "terminal") {
    return <TerminalPane client={client} ws={ws} pane={node.pane} canType={canType} />;
  }
  return (
    <div
      data-share-pane={paneKeyOf(ws, node.pane)}
      className="flex h-full w-full items-center justify-center bg-[#111] text-xs text-muted"
      ref={usePaneRegistration(ws, node.pane)}
    >
      {node.content === "browser" ? t("browserPanePlaceholder") : t("panePlaceholder")}
    </div>
  );
}

function usePaneRegistration(ws: string, pane: string): (el: HTMLElement | null) => void {
  const registry = useContext(PaneRegistryContext);
  const key = paneKeyOf(ws, pane);
  return (el) => registry?.register(key, el);
}

/**
 * One terminal pane: a canvas painted from the grid model. Lifecycle is
 * driven entirely by the mount callback ref (no useEffect): mounting wires
 * grid + resize listeners, unmounting tears them down.
 */
function TerminalPane({
  client,
  ws,
  pane,
  canType,
}: {
  client: ShareClient;
  ws: string;
  pane: string;
  canType: boolean;
}): ReactNode {
  const registry = useContext(PaneRegistryContext);
  const cleanupRef = useRef<(() => void) | null>(null);

  const mountCanvas = (canvas: HTMLCanvasElement | null): void => {
    cleanupRef.current?.();
    cleanupRef.current = null;
    if (!canvas) return;
    const model = client.gridFor(ws, pane);
    const paint = (): void => {
      const box = canvas.parentElement;
      if (!box) return;
      const dpr = window.devicePixelRatio || 1;
      const cssW = box.clientWidth;
      const cssH = box.clientHeight;
      if (cssW === 0 || cssH === 0) return;
      if (canvas.width !== Math.round(cssW * dpr) || canvas.height !== Math.round(cssH * dpr)) {
        canvas.width = Math.round(cssW * dpr);
        canvas.height = Math.round(cssH * dpr);
      }
      const ctx = canvas.getContext("2d");
      if (ctx) paintGrid(ctx, model, cssW, cssH, dpr);
    };
    const unsubscribeGrid = client.subscribeGrid(ws, pane, paint);
    const resizeObserver = new ResizeObserver(paint);
    if (canvas.parentElement) resizeObserver.observe(canvas.parentElement);
    paint();
    cleanupRef.current = () => {
      unsubscribeGrid();
      resizeObserver.disconnect();
    };
  };

  return (
    <div
      data-share-pane={paneKeyOf(ws, pane)}
      ref={(el) => registry?.register(paneKeyOf(ws, pane), el)}
      className={`relative h-full w-full overflow-hidden outline-none ${
        canType ? "focus-within:ring-1 focus-within:ring-[#2d8cff]/60" : ""
      }`}
    >
      <canvas ref={mountCanvas} className="absolute inset-0 h-full w-full" />
      <div
        role={canType ? "textbox" : "presentation"}
        aria-label={pane}
        tabIndex={canType ? 0 : -1}
        className="absolute inset-0 cursor-text outline-none"
        onKeyDown={(e) => {
          if (!canType) return;
          const bytes = keyEventToBytes(e);
          if (bytes !== null) {
            e.preventDefault();
            client.sendInput(ws, pane, bytes);
          }
        }}
        onPaste={(e) => {
          if (!canType) return;
          const text = e.clipboardData.getData("text");
          if (text) {
            e.preventDefault();
            client.sendInput(ws, pane, text);
          }
        }}
        onPointerMove={(e) => {
          const rect = e.currentTarget.getBoundingClientRect();
          client.sendCursor({
            ws,
            pane,
            x: Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)),
            y: Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)),
          });
        }}
        onPointerLeave={() => client.sendCursor(null)}
      />
    </div>
  );
}
