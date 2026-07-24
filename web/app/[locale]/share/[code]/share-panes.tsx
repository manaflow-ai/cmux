"use client";

// Recursive split layout for the terminal-only viewer. Terminal canvases
// paint imperatively from grid models; every other leaf stays present as a
// stable, noninteractive placeholder so the host's split geometry is exact.

import {
  createContext,
  useCallback,
  useContext,
  useRef,
  type ReactNode,
} from "react";
import { useTranslations } from "next-intl";

import type { ShareClient } from "./share-connection";
import type { LayoutNode } from "./share-protocol";
import { paintGrid } from "./terminal-grid";
import { keyEventToBytes } from "./terminal-keys";

export interface PaneRectRegistry {
  register(paneKey: string, el: HTMLElement | null): void;
  get(paneKey: string): HTMLElement | null;
  subscribe(listener: () => void): () => void;
  getRevision(): number;
}

interface PaneResizeObserver {
  observe(element: HTMLElement): void;
  unobserve(element: HTMLElement): void;
  disconnect(): void;
}

type PaneResizeObserverFactory = (
  listener: () => void,
) => PaneResizeObserver;

export function createPaneRectRegistry(
  createResizeObserver: PaneResizeObserverFactory = (listener) =>
    new ResizeObserver(listener),
): PaneRectRegistry {
  const panes = new Map<string, HTMLElement>();
  const listeners = new Set<() => void>();
  let revision = 0;
  const publish = (): void => {
    revision += 1;
    for (const listener of listeners) listener();
  };
  const resizeObserver = createResizeObserver(publish);
  return {
    register(paneKey, el) {
      const previous = panes.get(paneKey) ?? null;
      if (previous === el) return;
      if (previous) resizeObserver.unobserve(previous);
      if (el) {
        panes.set(paneKey, el);
        resizeObserver.observe(el);
      } else {
        panes.delete(paneKey);
      }
      publish();
    },
    get(paneKey) {
      return panes.get(paneKey) ?? null;
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getRevision() {
      return revision;
    },
  };
}

export interface AnimationFrameScheduler {
  schedule(): void;
  cancel(): void;
}

export function createAnimationFrameScheduler(
  requestFrame: (callback: () => void) => number,
  cancelFrame: (id: number) => void,
  paint: () => void,
): AnimationFrameScheduler {
  let pendingFrame: number | null = null;
  return {
    schedule() {
      if (pendingFrame !== null) return;
      pendingFrame = requestFrame(() => {
        pendingFrame = null;
        paint();
      });
    },
    cancel() {
      if (pendingFrame === null) return;
      cancelFrame(pendingFrame);
      pendingFrame = null;
    },
  };
}

const PaneRegistryContext = createContext<PaneRectRegistry | null>(null);
export const PaneRegistryProvider = PaneRegistryContext.Provider;

export const paneKeyOf = (ws: string, pane: string): string => JSON.stringify([ws, pane]);

export function paneRefFromKey(value: string): [string, string] | null {
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed) &&
      parsed.length === 2 &&
      typeof parsed[0] === "string" &&
      typeof parsed[1] === "string"
      ? [parsed[0], parsed[1]]
      : null;
  } catch {
    return null;
  }
}

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
    <PlaceholderPane
      content={node.content}
      label={
        node.content === "browser" ? t("browserPanePlaceholder") : t("panePlaceholder")
      }
    />
  );
}

function PlaceholderPane({
  content,
  label,
}: {
  content: Exclude<Extract<LayoutNode, { kind: "pane" }>["content"], "terminal">;
  label: string;
}): ReactNode {
  return (
    <div
      data-share-placeholder={content}
      className="flex h-full w-full items-center justify-center bg-[#111] text-xs text-muted"
    >
      {label}
    </div>
  );
}

/**
 * One terminal pane. The callback ref owns grid and resize subscriptions, so
 * mounting/unmounting is the complete lifecycle without a component effect.
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
  const paneKey = paneKeyOf(ws, pane);

  const registerPane = useCallback(
    (element: HTMLElement | null): void => registry?.register(paneKey, element),
    [paneKey, registry],
  );
  const mountCanvas = useCallback(
    (canvas: HTMLCanvasElement | null): void => {
      cleanupRef.current?.();
      cleanupRef.current = null;
      if (!canvas) return;
      const model = client.gridFor(ws, pane);
      const paintNow = (): void => {
        const box = canvas.parentElement;
        if (!box) return;
        const dpr = window.devicePixelRatio || 1;
        const cssW = box.clientWidth;
        const cssH = box.clientHeight;
        if (cssW === 0 || cssH === 0) return;
        if (
          canvas.width !== Math.round(cssW * dpr) ||
          canvas.height !== Math.round(cssH * dpr)
        ) {
          canvas.width = Math.round(cssW * dpr);
          canvas.height = Math.round(cssH * dpr);
        }
        const context = canvas.getContext("2d");
        if (context) paintGrid(context, model, cssW, cssH, dpr);
      };
      const scheduler = createAnimationFrameScheduler(
        (callback) => window.requestAnimationFrame(() => callback()),
        (id) => window.cancelAnimationFrame(id),
        paintNow,
      );
      const unsubscribeGrid = client.subscribeGrid(ws, pane, scheduler.schedule);
      const resizeObserver = new ResizeObserver(scheduler.schedule);
      if (canvas.parentElement) resizeObserver.observe(canvas.parentElement);
      scheduler.schedule();
      cleanupRef.current = () => {
        unsubscribeGrid();
        resizeObserver.disconnect();
        scheduler.cancel();
      };
    },
    [client, pane, ws],
  );

  return (
    <div
      data-share-pane={paneKey}
      ref={registerPane}
      className={`relative h-full w-full overflow-hidden outline-none ${
        canType ? "focus-within:ring-1 focus-within:ring-[#2d8cff]/60" : ""
      }`}
    >
      <canvas ref={mountCanvas} className="absolute inset-0 h-full w-full" />
      <div
        role={canType ? "textbox" : "presentation"}
        aria-label={pane}
        tabIndex={canType ? 0 : -1}
        className={`absolute inset-0 outline-none ${canType ? "cursor-text" : "cursor-default"}`}
        onKeyDown={(event) => {
          if (!canType) return;
          const bytes = keyEventToBytes(event);
          if (bytes !== null) {
            event.preventDefault();
            client.sendInput(ws, pane, bytes);
          }
        }}
        onPaste={(event) => {
          if (!canType) return;
          const text = event.clipboardData.getData("text");
          if (text) {
            event.preventDefault();
            client.sendInput(ws, pane, text);
          }
        }}
      />
    </div>
  );
}
