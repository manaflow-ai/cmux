// Page side of the proposed web pane bridge (interfaces/web-bridge.ts).
// Identical in first-party-apps/{monaco,codemirror}/src/shared.
//
// `createBridge(transport)` gives the page a small `cmux`-like client: call an
// op, subscribe to a stream, emit interface events, finish host commands. The
// host answers through `bridge.receive(message)`, which the page installs as
// `window.__cmuxBridgeReceive`.

import type { EditorProps, EditorTheme } from "../interfaces/editor.ts"
import type { BridgeError, BridgeTransport, HostToPane, PaneToHost } from "../interfaces/web-bridge.ts"

export class BridgeCallError extends Error {
  constructor(readonly code: string, message: string, readonly retryable = false, readonly details?: unknown) {
    super(message)
  }
}

export interface InitMessage {
  app: { id: string; version: string }
  pane: string
  locale: string
  theme: EditorTheme
  settings: Record<string, unknown>
  props: EditorProps
  embedded: boolean
  reduceMotion: boolean
}

export interface BridgeHandlers {
  init?(m: InitMessage): void
  props?(p: EditorProps): void
  theme?(t: EditorTheme): void
  settings?(s: Record<string, unknown>): void
  command?(command: string, args: Record<string, unknown>): unknown
  visibility?(visible: boolean): void
}

export interface Bridge {
  call<T = unknown>(op: string, params?: unknown): Promise<T>
  on(stream: string, filter: unknown, fn: (payload: unknown) => void): () => void
  emit(event: { type: string; [k: string]: unknown }): void
  log(level: "debug" | "info" | "warn" | "error", message: string): void
  receive(message: HostToPane | string): void
  handlers: BridgeHandlers
}

export function createBridge(transport: BridgeTransport, handlers: BridgeHandlers = {}): Bridge {
  let nextId = 1
  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: BridgeCallError) => void }>()
  const subs = new Map<number, (payload: unknown) => void>()
  const post = (m: PaneToHost) => transport.post(m)
  const toError = (e: BridgeError) => new BridgeCallError(e.code, e.message, !!e.retryable, e.details)

  const bridge: Bridge = {
    handlers,
    call<T>(op: string, params: unknown = {}) {
      const id = nextId++
      return new Promise<T>((resolve, reject) => {
        pending.set(id, { resolve: resolve as (v: unknown) => void, reject })
        post({ v: 1, kind: "call", id, op, params })
      })
    },
    on(stream, filter, fn) {
      const id = nextId++
      subs.set(id, fn)
      post({ v: 1, kind: "subscribe", id, stream, filter })
      return () => {
        if (subs.delete(id)) post({ v: 1, kind: "unsubscribe", id })
      }
    },
    emit(event) {
      post({ v: 1, kind: "emit", event })
    },
    log(level, message) {
      post({ v: 1, kind: "log", level, message })
    },
    receive(raw) {
      const m = (typeof raw === "string" ? JSON.parse(raw) : raw) as HostToPane
      if (!m || m.v !== 1) return
      switch (m.kind) {
        case "result": {
          const p = pending.get(m.id)
          if (!p) return
          pending.delete(m.id)
          if (m.ok) p.resolve(m.value)
          else p.reject(toError(m.error))
          return
        }
        case "event":
          subs.get(m.id)?.(m.payload)
          return
        case "init":
          bridge.handlers.init?.(m)
          return
        case "props":
          bridge.handlers.props?.(m.props)
          return
        case "theme":
          bridge.handlers.theme?.(m.theme)
          return
        case "settings":
          bridge.handlers.settings?.(m.settings)
          return
        case "visibility":
          bridge.handlers.visibility?.(m.visible)
          return
        case "command": {
          const fn = bridge.handlers.command
          const finish = (ok: boolean, value?: unknown, error?: BridgeError) => post({ v: 1, kind: "commandDone", id: m.id, ok, value, error })
          if (!fn) return finish(false, undefined, { code: "command.unknown", message: m.command })
          Promise.resolve()
            .then(() => fn(m.command, m.args ?? {}))
            .then(
              (v) => finish(true, v ?? null),
              (e) => finish(false, undefined, { code: e instanceof BridgeCallError ? e.code : "command.failed", message: e instanceof Error ? e.message : String(e) })
            )
          return
        }
      }
    }
  }
  return bridge
}

/** The host transport in a cmux web pane: `window.webkit.messageHandlers.cmux`. Null outside cmux. */
export function hostTransport(w: unknown = globalThis): BridgeTransport | null {
  const handler = (w as { webkit?: { messageHandlers?: { cmux?: { postMessage(m: unknown): void } } } }).webkit?.messageHandlers?.cmux
  return handler ? { post: (m) => handler.postMessage(JSON.stringify(m)) } : null
}
