/** Source shape kept structural so this helper can run in Bun tests without Vite's import.meta.glob. */
export type PrioritizedSource = { path: string };

/** Put the route's likely source first so a copied deep link gets a foreground frame immediately. */
export function prioritizeEntrySources<T extends PrioritizedSource>(sources: readonly T[], entryId: string): T[] {
  const terms = entryId
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((term) => term.length >= 4);
  if (terms.length === 0) return [...sources];
  return [...sources].sort((a, b) => {
    const score = (source: PrioritizedSource) =>
      terms.reduce((total, term) => total + (source.path.toLowerCase().includes(term) ? 1 : 0), 0);
    return score(b) - score(a);
  });
}
