// Script additions to the generated `cmux` global (generated/cmux-app.d.ts).
// `cmux script types` prints the generated file followed by this one.

/** The fields every terminal event has: the terminal's and its tab's public ids. */
interface CmuxTerminalEventFields {
  stream: string
  terminal: string | null
  tab: string
}

/**
 * Script event streams and their fields. Resource streams fire on every
 * committed resource change and carry only `stream`.
 */
interface CmuxScriptEvents {
  "resource.changed": { stream: "resource.changed" }
  "workspace.changed": { stream: "workspace.changed" }
  "screen.changed": { stream: "screen.changed" }
  "pane.changed": { stream: "pane.changed" }
  "tab.changed": { stream: "tab.changed" }
  "terminal.changed": { stream: "terminal.changed" }
  /** New output on the terminal (coalesced; read the screen for the text). */
  "terminal.output": CmuxTerminalEventFields
  "terminal.bell": CmuxTerminalEventFields
  "terminal.title_changed": CmuxTerminalEventFields & { title: string }
  /** OSC 7501 program status; `null` when the status was removed. */
  "terminal.program_status_changed": CmuxTerminalEventFields & {
    program_status: { state: "working" | "blocked" | "error" | "done"; progress: number | null } | null
  }
  /** The terminal's program exited; `exit_code` when it exited with a code. */
  "terminal.exited": CmuxTerminalEventFields & { outcome?: { kind: string; code?: number; signal?: number }; exit_code?: number }
}

type CmuxEventOf<S extends string> = S extends keyof CmuxScriptEvents ? CmuxScriptEvents[S] : { stream: string; [field: string]: unknown }

interface CmuxEventStream<E> extends AsyncIterable<E> {
  next(): Promise<IteratorResult<E>>
  return(): Promise<IteratorResult<E>>
}

interface CmuxGlobal {
  /** The script's arguments: `key=value` words and `--args JSON` of `cmux script run`. */
  args: Record<string, unknown>
  /** Resolves after `ms` milliseconds. */
  sleep(ms: number): Promise<void>
  /**
   * Resolves when `predicate` holds, checked at once and after every event on
   * `stream`. The predicate is a function, or a filter object whose fields
   * must equal the event's (`{ terminal: "term_..." }`); with a filter the
   * result is the matching event. `timeoutMs` rejects with `CmuxError` code
   * `script.timeout`. Streams: see `CmuxScriptEvents`.
   */
  wait<S extends string, T = unknown>(stream: S, predicate?: (event: CmuxEventOf<S> | undefined) => T | Promise<T>, options?: { timeoutMs?: number }): Promise<T>
  wait<S extends string>(stream: S, filter: Partial<CmuxEventOf<S>>, options?: { timeoutMs?: number }): Promise<CmuxEventOf<S>>
  wait<S extends string>(stream: S, options?: { timeoutMs?: number }): Promise<CmuxEventOf<S>>
  /**
   * Calls `fn` for each event on `stream` whose fields match `filter`.
   * Returns a function that removes the handler. A handler's error is
   * logged and the handler stays. A `cmux script run` lasts while the script
   * has handlers, until `cmux.stop()` or its timeout; REPL cells never wait.
   */
  on<S extends string>(stream: S, fn: (event: CmuxEventOf<S>) => unknown): () => void
  on<S extends string>(stream: S, filter: Partial<CmuxEventOf<S>>, fn: (event: CmuxEventOf<S>) => unknown): () => void
  /** Removes every handler and ends a waiting `cmux script run`; `value` becomes its result. */
  stop(value?: unknown): void
  /** The events on `stream` that match `filter`, buffered from now: `for await (const ev of cmux.stream(...))`; `break` ends it. */
  stream<S extends string>(stream: S, filter?: Partial<CmuxEventOf<S>>): CmuxEventStream<CmuxEventOf<S>>
}

declare function setTimeout(fn: (...args: unknown[]) => void, ms?: number, ...args: unknown[]): number
declare function clearTimeout(id: number): void
