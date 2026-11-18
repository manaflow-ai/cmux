// An MCP App view (`text/html;profile=mcp-app`) in the chat's render frame
// (conversation/renderFrame.ts, AgentPaneRenderFrame.swift: its own origin, `sandbox allow-scripts`,
// no same-origin). The frame writes the view's HTML into itself, so the view's `window.parent` is
// this page; every JSON-RPC message it posts is forwarded whole to acpmux (`uiSurfaceBridge`),
// whose mediator (cmux-ui-surfaces) classifies it, and its answer is posted back. The page decides
// nothing about a message beyond its shape. One ordering rule is kept here as well as in Rust: the
// host sends the view nothing of its own (tool input, tool result) before the view's
// `ui/notifications/initialized`; until then such notifications wait in order. A reply to the
// view's own request (its `ui/initialize`) is an answer, not a host message, and goes at once.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { renderFrameCSS } from "../conversation/renderBase";
import { readUiSurfacePending, type UiSurfacePending } from "./model";

export const MCP_APP_INITIALIZED = "ui/notifications/initialized";
/// Rust clamps a view's size to this range (DESIGN "MCP Apps bridge"); the page's default height.
export const FRAME_MIN_HEIGHT = 40;
export const FRAME_MAX_HEIGHT = 1200;
export const FRAME_DEFAULT_HEIGHT = 320;

type JsonRpc = { jsonrpc: "2.0"; id?: string | number; method?: string };

/// Whether `data` is a JSON-RPC 2.0 message (a request, notification or response).
export function isJsonRpc(data: unknown): data is JsonRpc {
  return typeof data === "object" && data !== null && (data as { jsonrpc?: unknown }).jsonrpc === "2.0";
}

/// acpmux's answer to one forwarded message (the bridge contract, prototype):
///   reply   the JSON-RPC response to the view's request, posted back as is
///   notify  host notifications for the view (`ui/notifications/tool-input`, `tool-result`)
///   height  the view's size, already clamped by Rust
///   blocked plain text the card shows: the message was refused
///   pending a confirm strip Rust wrote for what the view asked to send (nothing sent yet)
///   draft   composer text the view offered; the person presses Send
export type BridgeAnswer = {
  reply?: unknown;
  notify?: unknown[];
  height?: number;
  blocked?: string;
  pending?: UiSurfacePending;
  draft?: string;
};

export function readBridgeAnswer(value: unknown): BridgeAnswer {
  if (typeof value !== "object" || value === null) return {};
  const answer = value as Record<string, unknown>;
  const pending = readUiSurfacePending(answer.pending);
  return {
    ...(isJsonRpc(answer.reply) ? { reply: answer.reply } : {}),
    ...(Array.isArray(answer.notify) ? { notify: answer.notify.filter(isJsonRpc) } : {}),
    ...(typeof answer.height === "number" && Number.isFinite(answer.height) ? { height: answer.height } : {}),
    ...(typeof answer.blocked === "string" && answer.blocked ? { blocked: answer.blocked } : {}),
    ...(pending ? { pending } : {}),
    ...(typeof answer.draft === "string" && answer.draft ? { draft: answer.draft } : {}),
  };
}

/// What the card does with a view's asks beyond the frame itself.
export type FrameHost = { onPending(pending: UiSurfacePending): void; onDraft(text: string): void };

/// The bridge's state machine, apart from the DOM: `receive` takes one message from the view.
export function createFrameBridge(options: {
  forward(message: JsonRpc): Promise<unknown>;
  post(message: unknown): void;
  onHeight(height: number): void;
  onBlocked(reason: string): void;
  host?: FrameHost;
}) {
  let initialized = false;
  let closed = false;
  const waiting: unknown[] = [];
  const notify = (messages: unknown[]) => {
    if (!initialized) {
      waiting.push(...messages);
      return;
    }
    for (const message of messages) options.post(message);
  };
  return {
    receive(message: unknown) {
      if (closed || !isJsonRpc(message)) return;
      // Forwarded before the page marks it: the view's own `initialized` is the boundary, and what
      // Rust sends in answer to it is the first host message the view sees.
      const opened = message.method === MCP_APP_INITIALIZED && message.id === undefined;
      void options.forward(message).then(
        (raw) => {
          if (closed) return;
          if (opened && !initialized) {
            initialized = true;
            notify(waiting.splice(0));
          }
          const answer = readBridgeAnswer(raw);
          if (answer.reply !== undefined) options.post(answer.reply);
          if (answer.notify?.length) notify(answer.notify);
          if (answer.height !== undefined) options.onHeight(answer.height);
          if (answer.blocked) options.onBlocked(answer.blocked);
          if (answer.pending) options.host?.onPending(answer.pending);
          if (answer.draft) options.host?.onDraft(answer.draft);
        },
        (error: unknown) => {
          if (closed) return;
          // A request the host could not answer still gets an answer, so the view never hangs.
          if (message.id !== undefined)
            options.post({
              jsonrpc: "2.0",
              id: message.id,
              error: { code: -32603, message: error instanceof Error ? error.message : String(error) },
            });
        },
      );
    },
    get initialized() {
      return initialized;
    },
    close() {
      closed = true;
      waiting.length = 0;
    },
  };
}

/// The view's HTML with its CSP (`_meta.ui.csp`, built by Rust) first in the document: a meta
/// policy only narrows the frame's own (`connect-src 'none'` and the rest), never widens it.
export function framedHtml(html: string, csp: string | undefined): string {
  if (!csp) return html;
  const content = csp.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  const meta = `<meta http-equiv="Content-Security-Policy" content="${content}">`;
  // Inside the head when there is one, else after the doctype, so the document keeps its mode.
  const at = /<head\b[^>]*>/i.exec(html) ?? /^\s*<!doctype[^>]*>/i.exec(html);
  return at ? html.slice(0, at.index + at[0].length) + meta + html.slice(at.index + at[0].length) : meta + html;
}

/// Feeds an MCP App's HTML to a render frame and runs its bridge to acpmux while mounted.
export function useSurfaceFrame(
  html: string,
  csp: string | undefined,
  initialHeight: number | undefined,
  forward: (message: unknown) => Promise<unknown>,
  host?: FrameHost,
  /// Given a poster (a confirmed action's `reply` to the view) while mounted, null after.
  onPost?: (post: ((message: unknown) => void) | null) => void,
) {
  const frame = useRef<HTMLIFrameElement>(null);
  // The latest host and forward for the bridge the effect below keeps for the frame's life, synced
  // after each commit, never written during render.
  const hostRef = useRef(host);
  const [height, setHeight] = useState(() =>
    Math.min(FRAME_MAX_HEIGHT, Math.max(FRAME_MIN_HEIGHT, initialHeight ?? FRAME_DEFAULT_HEIGHT)),
  );
  const [blocked, setBlocked] = useState<string>();
  const forwardRef = useRef(forward);
  useLayoutEffect(() => {
    hostRef.current = host;
    forwardRef.current = forward;
  }, [host, forward]);
  useEffect(() => {
    const target = () => frame.current?.contentWindow ?? null;
    const bridge = createFrameBridge({
      forward: (message) => forwardRef.current(message),
      post: (message) => target()?.postMessage(message, "*"),
      onHeight: (next) => setHeight(Math.min(FRAME_MAX_HEIGHT, Math.max(FRAME_MIN_HEIGHT, Math.ceil(next)))),
      onBlocked: setBlocked,
      host: {
        onPending: (pending) => hostRef.current?.onPending(pending),
        onDraft: (text) => hostRef.current?.onDraft(text),
      },
    });
    const postToView = (message: unknown) => {
      if (isJsonRpc(message)) target()?.postMessage(message, "*");
    };
    onPost?.(postToView);
    const source = framedHtml(html, csp);
    const onMessage = (event: MessageEvent) => {
      const view = target();
      if (!view || event.source !== view) return;
      const data: unknown = event.data;
      if (isJsonRpc(data)) return bridge.receive(data);
      if (typeof data === "object" && data !== null && (data as { type?: unknown }).type === "cmux-render-ready")
        view.postMessage({ type: "cmux-render", html: source, css: renderFrameCSS() }, "*");
      // The frame's own `cmux-render-size` is not the view's size: an MCP App says its size through
      // `ui/notifications/size-changed`, which Rust clamps.
    };
    addEventListener("message", onMessage);
    return () => {
      bridge.close();
      onPost?.(null);
      removeEventListener("message", onMessage);
    };
  }, [html, csp, onPost]);
  return { frame, height, blocked };
}
