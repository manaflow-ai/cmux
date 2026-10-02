// Fine-grained reactive core (signals, effects, owner scopes), the same model as the old cmux
// JS sidebar runtime: signals, effects that track what they read, and owner
// scopes that dispose child effects. Effects never run per tick; a write marks
// the readers dirty and one flush re-runs exactly those readers.
//
// Flushing never uses timers (the VM has none): host entry points flush
// synchronously when they return, and writes from promise continuations
// schedule one flush on the microtask queue.

export type Read<T> = (() => T) & { readonly peek: () => T }
export type Write<T> = (next: T | ((prev: T) => T)) => void

interface Computation {
  fn: () => void
  sources: Set<Set<Computation>>
  owner: Owner | null
  disposed: boolean
}

export interface Owner {
  children: Set<Owner>
  computations: Set<Computation>
  cleanups: Array<() => void>
  parent: Owner | null
  disposed: boolean
}

let currentComputation: Computation | null = null
let currentOwner: Owner | null = null
const dirty = new Set<Computation>()
let flushing = false
let flushScheduled = false
let batchDepth = 0
const afterFlushHooks: Array<() => void> = []

/** Called after every flush (the scene layer sends its op batches here). */
export const onAfterFlush = (hook: () => void) => afterFlushHooks.push(hook)

export function createOwner(parent: Owner | null = currentOwner): Owner {
  const owner: Owner = { children: new Set(), computations: new Set(), cleanups: [], parent, disposed: false }
  parent?.children.add(owner)
  return owner
}

export function disposeOwner(owner: Owner): void {
  if (owner.disposed) return
  owner.disposed = true
  for (const child of owner.children) disposeOwner(child)
  owner.children.clear()
  for (const c of owner.computations) disposeComputation(c)
  owner.computations.clear()
  for (const cleanup of owner.cleanups.splice(0)) cleanup()
  owner.parent?.children.delete(owner)
}

/** Runs fn with `owner` as the current owner (effects created inside belong to it). */
export function runWithOwner<T>(owner: Owner | null, fn: () => T): T {
  const prev = currentOwner
  currentOwner = owner
  try {
    return fn()
  } finally {
    currentOwner = prev
  }
}

export const getOwner = () => currentOwner

export function onCleanup(fn: () => void): void {
  currentOwner?.cleanups.push(fn)
}

function disposeComputation(c: Computation) {
  c.disposed = true
  for (const source of c.sources) source.delete(c)
  c.sources.clear()
  dirty.delete(c)
}

function run(c: Computation) {
  if (c.disposed) return
  for (const source of c.sources) source.delete(c)
  c.sources.clear()
  const prevComputation = currentComputation
  const prevOwner = currentOwner
  currentComputation = c
  currentOwner = c.owner
  try {
    c.fn()
  } finally {
    currentComputation = prevComputation
    currentOwner = prevOwner
  }
}

export function signal<T>(initial: T, options: { equals?: (a: T, b: T) => boolean } = {}): [Read<T>, Write<T>] {
  let value = initial
  const readers = new Set<Computation>()
  const equals = options.equals ?? Object.is
  const read = (() => {
    if (currentComputation && !currentComputation.disposed) {
      readers.add(currentComputation)
      currentComputation.sources.add(readers)
    }
    return value
  }) as Read<T>
  ;(read as { peek: () => T }).peek = () => value
  const write: Write<T> = (next) => {
    const resolved = typeof next === "function" ? (next as (prev: T) => T)(value) : next
    if (equals(value, resolved)) return
    value = resolved
    for (const reader of readers) dirty.add(reader)
    scheduleFlush()
  }
  return [read, write]
}

/** An effect that runs now and again whenever a signal it read changes. */
export function effect(fn: () => void): () => void {
  const c: Computation = { fn, sources: new Set(), owner: currentOwner, disposed: false }
  currentOwner?.computations.add(c)
  run(c)
  return () => disposeComputation(c)
}

/** A derived signal; recomputes eagerly when its sources change and only notifies when its value changes. */
export function computed<T>(fn: () => T): Read<T> {
  const [read, write] = signal<T>(undefined as T)
  effect(() => write(fn()))
  return read
}

/** Runs fn without tracking reads. */
export function untrack<T>(fn: () => T): T {
  const prev = currentComputation
  currentComputation = null
  try {
    return fn()
  } finally {
    currentComputation = prev
  }
}

/** Defers flushing until fn returns (host entry points use this). */
export function batch<T>(fn: () => T): T {
  batchDepth++
  try {
    return fn()
  } finally {
    batchDepth--
    if (batchDepth === 0) flush()
  }
}

function scheduleFlush() {
  if (batchDepth > 0 || flushing || flushScheduled) return
  flushScheduled = true
  Promise.resolve().then(() => {
    flushScheduled = false
    flush()
  })
}

export function flush(): void {
  if (flushing) return
  flushing = true
  try {
    // Effects may write signals; keep draining until stable, with a bound against cycles.
    let rounds = 0
    while (dirty.size > 0) {
      if (++rounds > 1000) {
        dirty.clear()
        throw new Error("reactive cycle: effects kept writing signals they read")
      }
      const pending = [...dirty]
      dirty.clear()
      for (const c of pending) run(c)
    }
  } finally {
    flushing = false
    for (const hook of afterFlushHooks) hook()
  }
}
