// cmux-extension-sdk/web: the client for an extension's web pane (`render: web`).
//
// A web pane is an HTML page the extension ships in its package. cmux shows it in a tab, on the
// page's own origin (`cmux-page://<publisher>.<name>/`), with a strict Content Security Policy:
// the page loads only the extension's own files, makes no network request and opens no frame.
// It reaches cmux only through `call` below, which goes through the same scoped door as the
// extension's script: each call is checked against the scopes the person granted, is answered
// later (no call blocks), is at most 256 KiB, and a page makes at most 200 calls a second.
// A call outside the granted scopes rejects with `scope.missing`.
//
// The page follows cmux's theme through CSS variables cmux keeps current (`--cmux-text`,
// `--cmux-text-secondary`, `--cmux-accent`, `--cmux-separator`, `--cmux-surface-background`),
// and `cmux ext dev` reloads it in place on every save.
//
//     // cmux-app.json
//     "runtime": { "web": { "root": "web" } },
//     "implements": { "cmux.pane/1": { "web": "web/index.html", "title": "My pane" } },
//     "scopes": { "workspace:read": "List your workspaces." }
//
//     // web/page.ts, bundled to web/page.js
//     import { call } from "cmux-extension-sdk/web"
//     const { workspaces } = await call<{ workspaces: { id: string; name: string }[] }>("workspace.list")

/** Why cmux refused or failed a call: `scope.missing`, `rate.limited`, `operation.unsupported`, ... */
export class CmuxCallError extends Error {
  readonly code: string
  readonly retryable: boolean

  constructor(code: string, message: string, retryable: boolean) {
    super(message ? `${code}: ${message}` : code)
    this.name = "CmuxCallError"
    this.code = code
    this.retryable = retryable
  }
}

type Reply = { t: "ok"; id: number; value: unknown } | { t: "err"; id: number; code: string; message?: string; retryable?: boolean }

interface PageHost {
  postMessage(message: unknown): Promise<Reply>
}

function pageHost(): PageHost {
  const host = (globalThis as { webkit?: { messageHandlers?: { cmuxPage?: PageHost } } }).webkit?.messageHandlers?.cmuxPage
  if (!host) throw new CmuxCallError("page.unhosted", "this page is not open in cmux", false)
  return host
}

let nextId = 0

/**
 * Calls a cmux op as this extension (`workspace.list`, `app.storage.get`, ...), the same ops and
 * scopes as `cmux.call` in an extension's script. Resolves with the op's value; rejects with a
 * {@link CmuxCallError}.
 */
export async function call<T = unknown>(op: string, params: Record<string, unknown> = {}): Promise<T> {
  nextId += 1
  // The page's ops live in its own namespace on the bridge: its origin's host.
  const reply = await pageHost().postMessage({ t: "call", id: nextId, op: `${location.host}.${op}`, params })
  if (reply.t === "ok") return reply.value as T
  throw new CmuxCallError(reply.code, reply.message ?? "", reply.retryable ?? false)
}

/** This page's app storage (scope `storage:local`): small JSON values kept per extension. */
export const storage = {
  get: <T = unknown>(key: string): Promise<T | null> => call<T | null>("app.storage.get", { key }),
  set: (key: string, value: unknown): Promise<unknown> => call("app.storage.set", { key, value }),
}
