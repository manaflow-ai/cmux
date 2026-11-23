// The composer hat's `kinds` header pinned on every variant of an entry about it (trayFoldHead.experiment.ts):
// these galleries read the header's words ("2 subagents running · 1 server"), which the `tally` default
// (Leo, 2026-11-23) draws as marks and numbers only. ComposerHatTally.gallery.ts shows `tally`.
// A variant's own pin of the experiment wins.
type Pinnable = { experiments?: Record<string, string> };

export function pinKindsHead<E extends { variants: Record<string, Pinnable> }>(entry: E): E {
  const variants = Object.fromEntries(
    Object.entries(entry.variants).map(([name, variant]) => [
      name,
      { ...variant, experiments: { "subagent-tray-fold-head": "kinds", ...variant.experiments } },
    ]),
  );
  return { ...entry, variants };
}
