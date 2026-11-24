/// Stack lines (V8 `at f (url:1:2)`, JSC `f@url:1:2`) as `f@file:1:2`, at most `limit`, on one line.
function frames(stack: string | undefined, limit: number): string[] {
  const out: string[] = [];
  for (const raw of (stack ?? "").split("\n")) {
    const line = raw.trim();
    const v8 = /^at (?:(.+?) \()?(.+?)\)?$/.exec(line);
    const jsc = v8 ? undefined : /^([^\s@]*)@(.+:\d+:\d+)$/.exec(line);
    const match = v8 ?? jsc;
    if (!match) continue;
    const where = match[2]!.replace(/^.*\//, "");
    out.push(match[1] ? `${match[1]}@${where}` : where);
    if (out.length === limit) break;
  }
  return out;
}

/// The line a caught render error is logged under: what failed, the error's own words, then where,
/// all on its first line. The app's journal keeps a console error's first line and one stack frame
/// (ConsoleErrorCapture.swift), so a component stack logged as its own multi-line argument never
/// reached it: React #185 in Leo's NIGHTLY (2026-11-24) came back with nothing that named the loop.
/// `in` is the component stack (innermost first), `stack` the error's own frames: for an update loop
/// they name the set that looped. Minified names map back through the build's pane.js at those columns.
export function paneFailureLine(error: unknown, componentStack?: string): string {
  const words = error instanceof Error ? error.message : String(error);
  const components = frames(componentStack, 16);
  const stack = error instanceof Error ? frames(error.stack, 12) : [];
  return [
    `agent pane render failed: ${words || "no message"}`,
    ...(components.length ? [`in: ${components.join(" < ")}`] : []),
    ...(stack.length ? [`stack: ${stack.join(", ")}`] : []),
  ].join(" | ");
}
