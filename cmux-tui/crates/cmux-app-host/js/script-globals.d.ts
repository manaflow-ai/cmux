// Script additions to the generated `cmux` global (generated/cmux-app.d.ts).
// `cmux script types` prints the generated file followed by this one.

interface CmuxGlobal {
  /** The script's arguments: `key=value` words and `--args JSON` of `cmux script run`. */
  args: Record<string, unknown>
  /** Resolves after `ms` milliseconds. */
  sleep(ms: number): Promise<void>
  /**
   * Resolves when `predicate` holds, checked at once and after every event on
   * `stream`. Streams: `resource.changed` (any committed resource change,
   * including terminal exit and program status), and `workspace.changed`,
   * `screen.changed`, `pane.changed`, `tab.changed`, `terminal.changed`.
   * `timeoutMs` rejects with `CmuxError` code `script.timeout`.
   */
  wait<T = unknown>(stream: string, predicate?: (event: unknown) => T | Promise<T>, options?: { timeoutMs?: number }): Promise<T>
  wait(stream: string, options?: { timeoutMs?: number }): Promise<unknown>
}

declare function setTimeout(fn: (...args: unknown[]) => void, ms?: number, ...args: unknown[]): number
declare function clearTimeout(id: number): void
