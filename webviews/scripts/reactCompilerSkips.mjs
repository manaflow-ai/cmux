// Which functions the React Compiler (babel-plugin-react-compiler) left as written, read off its logger's
// events. Shared by check-compiler-bails.mjs (the ratchet) and react-compiler-bailouts.mjs (the reporter), so
// both count the same skips.
//
// The compiler reports a skipped function three ways:
// - `CompileError`: one event per diagnostic, at the function (`fnLoc`). A file-level error has no `fnLoc`,
//   only the diagnostic's own `loc`.
// - `PipelineError`: the compiler threw. The cause is in `data`.
// - `CompileSkip`: a `"use no memo"` directive opted the function out. `fnLoc` is its body, and `reason`
//   says why.
// A diagnostic logged inside a function that still compiled (a lint-only validation such as
// setState-in-effect, with no `fnLoc`) is not a skip. Several events for one function count once.

const SKIP_KINDS = new Set(["CompileError", "CompileSkip", "PipelineError"]);

/**
 * @typedef {{ start?: { line?: number } | null; end?: { line?: number } | null } | null | undefined} Loc
 * @typedef {{ kind: string; fnLoc?: Loc; fnName?: string | null; reason?: string; loc?: Loc; data?: unknown; detail?: any }} CompilerEvent
 * @typedef {{ line: number; fnName: string | null; kind: string; reason: string; at: number | null }} CompilerSkip
 */

/**
 * @param {Loc} loc
 * @param {number} line
 */
const holds = (loc, line) => (loc?.start?.line ?? Infinity) <= line && line <= (loc?.end?.line ?? -Infinity);

/**
 * One entry per function the compiler skipped, in event order.
 * @param {CompilerEvent[]} events
 * @returns {CompilerSkip[]}
 */
export function compilerSkips(events) {
  const compiled = events.filter((event) => event.kind === "CompileSuccess" && event.fnLoc).map((event) => event.fnLoc);
  /** @type {(CompilerSkip & { fnLoc: Loc })[]} */
  const skipped = [];
  for (const event of events) {
    if (!SKIP_KINDS.has(event.kind)) continue;
    const detail = event.detail?.options ?? event.detail ?? {};
    /** @type {Loc} */
    const where = detail.loc ?? detail.details?.[0]?.loc ?? event.detail?.loc ?? event.loc ?? null;
    const line = event.fnLoc?.start?.line ?? where?.start?.line ?? 0;
    if (!event.fnLoc && compiled.some((loc) => holds(loc, line))) continue;
    if (skipped.some((skip) => (skip.fnLoc ? holds(skip.fnLoc, line) : skip.line === line && line !== 0))) continue;
    const reason = String(detail.reason ?? event.detail?.reason ?? event.reason ?? event.data ?? event.kind);
    skipped.push({
      line,
      fnLoc: event.fnLoc ?? null,
      fnName: event.fnName ?? null,
      kind: event.kind,
      reason: reason.split("\n")[0],
      at: where?.start?.line ?? null,
    });
  }
  return skipped.map(({ fnLoc: _, ...skip }) => skip);
}
