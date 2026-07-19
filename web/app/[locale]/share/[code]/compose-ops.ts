// Pure text-op helpers for the multiplayer composer, kept framework-free so
// tests and the connection layer can import them without pulling React or
// next-intl into the module graph.

/** Single-splice diff between two strings (common prefix/suffix trim). */
export function spliceDiff(
  prev: string,
  next: string,
): { p: number; d: number; i: string } | null {
  if (prev === next) return null;
  const prevCP = [...prev];
  const nextCP = [...next];
  let start = 0;
  while (start < prevCP.length && start < nextCP.length && prevCP[start] === nextCP[start]) {
    start += 1;
  }
  let endPrev = prevCP.length;
  let endNext = nextCP.length;
  while (endPrev > start && endNext > start && prevCP[endPrev - 1] === nextCP[endNext - 1]) {
    endPrev -= 1;
    endNext -= 1;
  }
  return { p: start, d: endPrev - start, i: nextCP.slice(start, endNext).join("") };
}
