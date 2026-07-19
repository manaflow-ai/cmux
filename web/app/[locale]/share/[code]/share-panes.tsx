"use client";

// Workspace pane tree: recursive split layout plus the terminal pane canvas.
// Canvases paint imperatively from the ShareClient's grid models; React only
// re-renders on layout changes, never per grid frame.

import { createContext, useContext, useRef, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";

import type { ShareClient } from "./share-connection";
import type { LayoutNode, Participant } from "./share-protocol";
import { SharedComposer } from "./shared-composer";
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
  participants,
  selfUser,
}: {
  client: ShareClient;
  ws: string;
  node: LayoutNode | null;
  canType: boolean;
  participants: Participant[];
  selfUser: string | null;
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
          <LayoutView
            client={client}
            ws={ws}
            node={node.a}
            canType={canType}
            participants={participants}
            selfUser={selfUser}
          />
        </div>
        <div
          className={
            node.axis === "h" ? "w-px shrink-0 bg-border" : "h-px shrink-0 bg-border"
          }
        />
        <div style={{ flexBasis: `${(1 - ratio) * 100}%` }} className="min-h-0 min-w-0">
          <LayoutView
            client={client}
            ws={ws}
            node={node.b}
            canType={canType}
            participants={participants}
            selfUser={selfUser}
          />
        </div>
      </div>
    );
  }
  if (node.content === "terminal") {
    return <TerminalPane client={client} ws={ws} pane={node.pane} canType={canType} />;
  }
  if (node.content === "browser" || node.content === "agent") {
    return (
      <div className="flex h-full w-full flex-col">
        <div className="min-h-0 flex-1">
          <PixelPane
            client={client}
            ws={ws}
            pane={node.pane}
            interactive={canType && node.content === "browser"}
          />
        </div>
        {node.content === "agent" && canType ? (
          <SharedComposer
            client={client}
            field={node.pane}
            participants={participants}
            selfUser={selfUser}
          />
        ) : null}
      </div>
    );
  }
  return <PlaceholderPane ws={ws} pane={node.pane} label={t("panePlaceholder")} />;
}

function PlaceholderPane({
  ws,
  pane,
  label,
}: {
  ws: string;
  pane: string;
  label: string;
}): ReactNode {
  const registry = useContext(PaneRegistryContext);
  return (
    <div
      data-share-pane={paneKeyOf(ws, pane)}
      className="flex h-full w-full items-center justify-center bg-[#111] text-xs text-muted"
      ref={(el) => registry?.register(paneKeyOf(ws, pane), el)}
    >
      {label}
    </div>
  );
}

/**
 * Pixel-streamed pane (browser and other non-terminal kinds, slice 2).
 * Shows the placeholder copy until the first decoded frame arrives.
 */
function PixelPane({
  client,
  ws,
  pane,
  interactive,
}: {
  client: ShareClient;
  ws: string;
  pane: string;
  /** Slice 3: forward pointer/keyboard into the host's webview. */
  interactive: boolean;
}): ReactNode {
  const t = useTranslations("share");
  const registry = useContext(PaneRegistryContext);
  const cleanupRef = useRef<(() => void) | null>(null);
  const [hasFrame, setHasFrame] = useState(false);

  const mountCanvas = (canvas: HTMLCanvasElement | null): void => {
    cleanupRef.current?.();
    cleanupRef.current = null;
    if (!canvas) return;
    const model = client.pixelFor(ws, pane);
    const paint = (): void => {
      const image = model.image;
      if (!image) return;
      setHasFrame(true);
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
      if (!ctx) return;
      // Letterbox, preserving the host pane's aspect.
      const iw = "displayWidth" in image ? image.displayWidth : image.width;
      const ih = "displayHeight" in image ? image.displayHeight : image.height;
      const scale = Math.min((cssW * dpr) / iw, (cssH * dpr) / ih);
      const dw = iw * scale;
      const dh = ih * scale;
      ctx.fillStyle = "#111111";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(image, (canvas.width - dw) / 2, (canvas.height - dh) / 2, dw, dh);
    };
    const unsubscribe = model.subscribe(paint);
    const resizeObserver = new ResizeObserver(paint);
    if (canvas.parentElement) resizeObserver.observe(canvas.parentElement);
    paint();
    cleanupRef.current = () => {
      unsubscribe();
      resizeObserver.disconnect();
    };
  };

  return (
    <div
      data-share-pane={paneKeyOf(ws, pane)}
      ref={(el) => registry?.register(paneKeyOf(ws, pane), el)}
      className="relative h-full w-full overflow-hidden bg-[#111]"
    >
      <canvas ref={mountCanvas} className="absolute inset-0 h-full w-full" />
      {interactive ? (
        <div
          role="application"
          aria-label={pane}
          tabIndex={0}
          className="absolute inset-0 outline-none focus:ring-1 focus:ring-[#2d8cff]/60"
          onPointerDown={(e) => {
            e.currentTarget.focus();
            client.sendPointer({ t: "pointer", ws, pane, action: "down", ...relPos(e), button: e.button });
          }}
          onPointerUp={(e) =>
            client.sendPointer({ t: "pointer", ws, pane, action: "up", ...relPos(e), button: e.button })
          }
          onPointerMove={(e) =>
            client.sendPointer({ t: "pointer", ws, pane, action: "move", ...relPos(e) })
          }
          onWheel={(e) =>
            client.sendPointer({
              t: "pointer",
              ws,
              pane,
              action: "wheel",
              ...relPos(e),
              dx: e.deltaX,
              dy: e.deltaY,
            })
          }
          onKeyDown={(e) => {
            if (e.metaKey) return; // leave browser/system shortcuts alone
            e.preventDefault();
            client.sendWebKey(webKeyMessage(ws, pane, e, true));
          }}
          onKeyUp={(e) => {
            if (e.metaKey) return;
            client.sendWebKey(webKeyMessage(ws, pane, e, false));
          }}
        />
      ) : null}
      {!hasFrame ? (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center text-xs text-muted">
          {t("browserPanePlaceholder")}
        </div>
      ) : !interactive ? (
        <span className="pointer-events-none absolute right-1.5 top-1.5 rounded bg-black/50 px-1.5 py-0.5 text-[9px] text-neutral-400">
          {t("pixelViewOnlyBadge")}
        </span>
      ) : null}
    </div>
  );
}

function relPos(e: { clientX: number; clientY: number; currentTarget: HTMLElement }): {
  x: number;
  y: number;
} {
  const rect = e.currentTarget.getBoundingClientRect();
  return {
    x: Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)),
    y: Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)),
  };
}

function webKeyMessage(
  ws: string,
  pane: string,
  e: {
    key: string;
    code: string;
    altKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
    shiftKey: boolean;
  },
  down: boolean,
): Extract<import("./share-protocol").GuestMessage, { t: "webkey" }> {
  return {
    t: "webkey",
    ws,
    pane,
    key: e.key,
    code: e.code,
    down,
    ...(e.altKey ? { alt: true } : {}),
    ...(e.ctrlKey ? { ctrl: true } : {}),
    ...(e.metaKey ? { meta: true } : {}),
    ...(e.shiftKey ? { shift: true } : {}),
  };
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
      />
    </div>
  );
}
