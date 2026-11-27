// A read op as signals: value, problem, loading. It re-reads when its params
// signal changes or when one of `events` fires (no timers, no polling). The
// newest request wins; an older reply that arrives late is dropped.

import { CHANGED, classify, type Problem } from "./ops.ts"

export interface Query<T> {
  (): T | undefined
  problem(): Problem | null
  loading(): boolean
  refresh(): void
}

export function query<T>(op: string, params: () => Record<string, unknown> = () => ({}), events: readonly string[] = [CHANGED]): Query<T> {
  const [value, setValue] = signal<T | undefined>(undefined)
  const [problem, setProblem] = signal<Problem | null>(null)
  const [loading, setLoading] = signal(true)
  let latest = 0
  let current: Record<string, unknown> = {}
  const load = () => {
    const mine = ++latest
    setLoading(true)
    cmux
      .call<T>(op, current)
      .then((v) => {
        if (mine !== latest) return
        setValue(() => v)
        setProblem(null)
      })
      .catch((e: unknown) => {
        if (mine === latest) setProblem(classify(e))
      })
      .finally(() => {
        if (mine === latest) setLoading(false)
      })
  }
  for (const stream of events) cmux.events.on(stream, load)
  effect(() => {
    current = params()
    load()
  })
  return Object.assign(() => value(), { problem, loading, refresh: load })
}

/** A query that never loads. */
export const idle = <T>(): Query<T> => Object.assign(() => undefined as T | undefined, { problem: () => null, loading: () => false, refresh: () => undefined })
