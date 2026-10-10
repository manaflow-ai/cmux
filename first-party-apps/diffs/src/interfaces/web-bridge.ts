// PROPOSED web pane bridge (app platform critique C6).
// Vendored copy; identical in first-party-apps/{diffs,codemirror}.
//
// A web pane is a sandboxed WKWebView that loads the app's bundle from the
// `cmux-app://<app id>/` scheme with CSP `default-src 'self'` and no network.
// It talks to the host through one JSON message channel:
//   page -> host: window.webkit.messageHandlers.cmux.postMessage(PaneToHost)
//   host -> page: window.__cmuxBridgeReceive(HostToPane)
// The host checks every call against the app's grant, stamps actor
// `app:<id>` and origin (`user` inside a user-input turn, else `script`),
// exactly as for the app's script VM. A pane mounted as an embed gets the
// embed's props and only the handles in them.

import type { EditorProps, EditorTheme } from "./editor.ts"

export const BRIDGE_VERSION = 1

export interface BridgeError {
  code: string
  message: string
  retryable?: boolean
  details?: unknown
}

/** Messages from the page to the host. */
export type PaneToHost =
  | { v: 1; kind: "call"; id: number; op: string; params: unknown; options?: { idempotencyKey?: string } }
  | { v: 1; kind: "subscribe"; id: number; stream: string; filter?: unknown }
  | { v: 1; kind: "unsubscribe"; id: number }
  /** Interface events for the embedding app or the host (cmux.editor/1 EditorEvent). */
  | { v: 1; kind: "emit"; event: { type: string; [k: string]: unknown } }
  /** The command finished (answer to a host `command`). */
  | { v: 1; kind: "commandDone"; id: number; ok: boolean; value?: unknown; error?: BridgeError }
  | { v: 1; kind: "log"; level: "debug" | "info" | "warn" | "error"; message: string }

/** Messages from the host to the page. */
export type HostToPane =
  | { v: 1; kind: "init"; app: { id: string; version: string }; pane: string; locale: string; theme: EditorTheme; settings: Record<string, unknown>; props: EditorProps; embedded: boolean; reduceMotion: boolean }
  | { v: 1; kind: "result"; id: number; ok: true; value: unknown }
  | { v: 1; kind: "result"; id: number; ok: false; error: BridgeError }
  | { v: 1; kind: "event"; id: number; payload: unknown }
  | { v: 1; kind: "props"; props: EditorProps }
  | { v: 1; kind: "theme"; theme: EditorTheme }
  | { v: 1; kind: "settings"; settings: Record<string, unknown> }
  /** An app command routed to the focused pane (Save, Revert, Toggle Read-Only). */
  | { v: 1; kind: "command"; id: number; command: string; args: Record<string, unknown> }
  /** The pane became hidden or visible; hidden panes stop work. */
  | { v: 1; kind: "visibility"; visible: boolean }

/** Transport the page uses; the host provides `window.webkit.messageHandlers.cmux`. */
export interface BridgeTransport {
  post(message: PaneToHost): void
}
