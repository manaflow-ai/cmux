// cmux app runtime: engine-neutral (QuickJS-ng, JavaScriptCore, browsers, bun).
// Load order: this file, then the app's `main` (an IIFE that sets
// `__cmuxAppExports`), then the host calls `__cmuxAppInit`. ABI: ../ABI.md.

import { cmux, CmuxError, deliverEvent, fireTimer, log, resolveCall, state, type Native } from "./cmux.ts"
import { installCompat } from "./compat-sidebar-data.ts"
import { menuHandler, mount, mountExists, nodeRecord, sendPendingOps, setSceneSink, unmount } from "./materialize.ts"
import { batch, computed, effect, flush, signal, untrack } from "./reactive.ts"
import * as views from "./view.ts"

const g = globalThis as Record<string, unknown>
export const RUNTIME_VERSION = "1.0.0"

const exportsOf = (): Record<string, unknown> => (g.__cmuxAppExports as Record<string, unknown> | undefined) ?? {}

const describe = (e: unknown) => (e instanceof Error ? `${e.name === "Error" ? "" : `${e.name}: `}${e.message}` : String(e))

/** Every host entry point: run in a batch so all effects settle and ops leave in one message. */
function entry<T>(name: string, fn: () => T, fallback: T): T {
  try {
    return batch(fn)
  } catch (e) {
    log("error", `${name}: ${describe(e)}`)
    return fallback
  } finally {
    sendPendingOps()
  }
}

function runHandler(label: string, fn: (() => unknown) | undefined) {
  if (!fn) return
  try {
    const r = fn()
    if (r && typeof (r as Promise<unknown>).then === "function") (r as Promise<unknown>).catch((e) => log("error", `${label}: ${describe(e)}`))
  } catch (e) {
    log("error", `${label}: ${describe(e)}`)
  }
}

function install() {
  const native = g.__cmuxAppNative as Native | undefined
  if (native) state.native = native
  // Globals for app code (the old custom sidebar API plus `cmux`).
  Object.assign(g, views, { cmux, signal, computed, effect, untrack, CmuxError })
  if (typeof g.console === "undefined") {
    g.console = { log: (...a: unknown[]) => log("info", ...a), info: (...a: unknown[]) => log("info", ...a), warn: (...a: unknown[]) => log("warn", ...a), error: (...a: unknown[]) => log("error", ...a), debug: (...a: unknown[]) => log("debug", ...a) }
  }
  installCompat(g)
  setSceneSink((mountId, ops) => state.native?.scene(mountId, JSON.stringify(ops)))

  g.__cmuxAppInit = (initJSON: string) =>
    entry("init", () => {
      if (!state.native && g.__cmuxAppNative) state.native = g.__cmuxAppNative as Native
      const init = JSON.parse(initJSON || "{}") as { app?: { id: string; version: string }; settings?: Record<string, unknown>; apiVersion?: string; ops?: string[] }
      if (init.app) state.app = init.app
      if (init.apiVersion) state.apiVersion = init.apiVersion
      state.allowedOps = Array.isArray(init.ops) ? new Set(init.ops) : null
      state.settings[1](init.settings ?? {})
      return ""
    }, "init failed")

  g.__cmuxAppSetSettings = (json: string) => entry("settings", () => state.settings[1](JSON.parse(json || "{}")), undefined)

  g.__cmuxAppMount = (mountId: string, exportName: string, ctxJSON: string): string => {
    try {
      batch(() => {
        const render = exportsOf()[exportName]
        if (typeof render !== "function") throw new Error(`the app does not export a function named ${exportName}`)
        const ctx = JSON.parse(ctxJSON || "{}")
        mount(mountId, () => render(ctx))
      })
      return ""
    } catch (e) {
      unmount(mountId)
      const message = describe(e)
      log("error", `mount ${exportName}: ${message}`)
      return message || "render failed"
    } finally {
      sendPendingOps()
    }
  }

  g.__cmuxAppUnmount = (mountId: string) => entry("unmount", () => unmount(mountId), undefined)

  g.__cmuxAppDispatch = (mountId: string, nodeId: string, event: string, payloadJSON: string) =>
    entry("dispatch", () => {
      if (!mountExists(mountId)) return
      const record = nodeRecord(nodeId)
      if (!record || record.mount.id !== mountId) return
      const payload = payloadJSON ? JSON.parse(payloadJSON) : {}
      switch (event) {
        case "menu":
          runHandler("menu", menuHandler(record, Array.isArray(payload.path) ? payload.path : []) as (() => unknown) | undefined)
          break
        case "move": {
          const h = record.handlers.move as ((id: string, index: number, extra: unknown) => unknown) | undefined
          runHandler("move", h && (() => h(String(payload.id), Number(payload.index), payload.extra ?? {})))
          break
        }
        case "dragChange": {
          const h = record.handlers.dragChange as ((s: unknown) => unknown) | undefined
          runHandler("dragChange", h && (() => h(payload.state ?? null)))
          break
        }
        case "submit":
        case "edit": {
          const h = record.handlers[event] as ((t: string) => unknown) | undefined
          runHandler(event, h && (() => h(String(payload.text ?? ""))))
          break
        }
        default:
          runHandler(event, record.handlers[event] as (() => unknown) | undefined)
      }
    }, undefined)

  g.__cmuxAppRunCommand = (exportName: string, argsJSON: string, cbId: number) =>
    entry("command", () => {
      const fn = exportsOf()[exportName]
      const done = (ok: boolean, body: unknown) => state.native?.commandDone(cbId, ok, JSON.stringify(body ?? null))
      if (typeof fn !== "function") return done(false, { code: "export.missing", message: `the app does not export ${exportName}` })
      const failure = (e: unknown) => (e instanceof CmuxError ? { code: e.code, message: e.message, details: e.details ?? null } : { code: "command.failed", message: describe(e) })
      try {
        const r = fn(JSON.parse(argsJSON || "{}"), { app: state.app })
        Promise.resolve(r).then(
          (v) => done(true, { value: v ?? null }),
          (e) => done(false, failure(e))
        )
      } catch (e) {
        done(false, failure(e))
      }
    }, undefined)

  g.__cmuxAppResolve = (cbId: number, ok: boolean, json: string) => entry("resolve", () => resolveCall(cbId, ok, json), undefined)
  g.__cmuxAppEvent = (subId: number, json: string) => entry("event", () => deliverEvent(subId, json), undefined)
  g.__cmuxAppTimer = (timerId: number) => entry("timer", () => fireTimer(timerId), undefined)
  /** Hosts call this after draining the microtask queue when they want pending effects flushed now. */
  g.__cmuxAppFlush = () => entry("flush", flush, undefined)
  g.__cmuxAppRuntimeVersion = RUNTIME_VERSION
}

install()
