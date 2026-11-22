// Every op call goes through `call`, which turns a rejection into a value so
// views can show what is missing (`operation.unsupported`, `scope.missing`)
// instead of failing. The skill.*, mcp_server.* and diff.* ops are proposals (README).

export type OpError = { code: string; message: string; missing: boolean; op: string }
export type OpResult<T> = { ok: true; value: T } | { ok: false; error: OpError }

const MISSING = new Set(["operation.unsupported", "scope.missing"])

export function toOpError(e: unknown, op: string): OpError {
  const err = e as { code?: unknown; message?: unknown } | null
  const code = typeof err?.code === "string" ? err.code : "internal"
  const message = typeof err?.message === "string" ? err.message : String(e)
  return { code, message, missing: MISSING.has(code), op }
}

export async function call<T>(name: string, params: Record<string, unknown> = {}, options: CmuxCallOptions = {}): Promise<OpResult<T>> {
  try {
    return { ok: true, value: (await cmux.call(name, params, options)) as T }
  } catch (e) {
    return { ok: false, error: toOpError(e, name) }
  }
}
