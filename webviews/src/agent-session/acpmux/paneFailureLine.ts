/// The line a caught render error is logged under: what failed, then the error's own words.
export function paneFailureLine(error: unknown): string {
  const words = error instanceof Error ? error.message : String(error);
  return `agent pane render failed: ${words || "no message"}`;
}
