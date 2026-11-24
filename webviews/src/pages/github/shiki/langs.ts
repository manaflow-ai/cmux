// `shiki/langs` for the GitHub page: no grammars, so Pierre renders every language as plain
// text (index.ts).
export const bundledLanguages: Record<string, () => Promise<{ default: unknown }>> = {};
