// l10n-allow-file: proposal fixtures (sample customizations and setups), drawn only in the gallery
// until Leo picks a layout; the shipped list comes from `cmux customize library` (Rust).
// The customization paradigm (cmuxterm-hq docs/design/customization-paradigm.md): a customization is
// a thing with a name, a one-line description, an author and a before/after, not a settings row. A
// setup is a named set of them (Leo's, a teammate's, cmux's default), which anyone can try in one
// click, keep or revert. Leo, 2026-11-24 07:17Z: "having people be able to easily toggle my
// customieer or whatever would be god"; 07:32Z: "getting a proper customization paradigm would be
// better. the settings page customize is... not good."

/** What a customization changes in the live preview; each one is one class on the mini window. */
export type Effect = "glass" | "motion" | "compact" | "ember" | "round" | "standup" | "yours" | "blocks";

/** Where a customization comes from: a saved preference, or a pending UI pull request (unmerged). */
export type Source = { kind: "preference" } | { kind: "pr"; number: number; merged: boolean };

export type Customization = {
  id: Effect;
  name: string;
  line: string;
  author: string;
  source: Source;
  /** Another customization that sets the same thing; the later one in the list wins. */
  conflictsWith?: Effect;
};

export type Setup = {
  id: string;
  name: string;
  line: string;
  /** The customizations this setup turns on; every other one is off. */
  on: readonly Effect[];
};

export const CUSTOMIZATIONS: readonly Customization[] = [
  {
    id: "glass",
    name: "Glass chrome",
    line: "Sidebar and title bar let the background through.",
    author: "Leo",
    source: { kind: "pr", number: 48996, merged: true },
  },
  {
    id: "motion",
    name: "Motion background",
    line: "A slow generated gradient moves behind the window.",
    author: "Leo",
    source: { kind: "pr", number: 45930, merged: false },
  },
  {
    id: "ember",
    name: "Ember accent",
    line: "Warm accent on selection, buttons and the caret.",
    author: "Leo",
    source: { kind: "preference" },
  },
  {
    id: "compact",
    name: "Compact sidebar",
    line: "Narrower sidebar and tighter rows fit more sessions.",
    author: "Leo",
    source: { kind: "preference" },
  },
  {
    id: "round",
    name: "Round composer",
    line: "The message box is a capsule, like the send pop.",
    author: "Leo",
    source: { kind: "preference" },
  },
  {
    id: "blocks",
    name: "Block animation",
    line: "New messages slide in instead of appearing.",
    author: "Leo",
    source: { kind: "pr", number: 50462, merged: true },
  },
  {
    id: "yours",
    name: "Make cmux yours",
    line: "A welcome card that walks you through a setup.",
    author: "Leo",
    source: { kind: "pr", number: 50394, merged: false },
  },
  {
    id: "standup",
    name: "PRs in My Build",
    line: "A sidebar chip listing the unmerged code in this build.",
    author: "Leo",
    source: { kind: "pr", number: 52934, merged: false },
    conflictsWith: "compact",
  },
];

export const SETUPS: readonly Setup[] = [
  { id: "default", name: "cmux default", line: "What ships. Nothing extra.", on: [] },
  {
    id: "leo",
    name: "Leo's setup",
    line: "Every preference Leo keeps on, plus the UI he is trying.",
    on: ["glass", "motion", "ember", "compact", "round", "blocks", "yours", "standup"],
  },
  {
    id: "calm",
    name: "Calm",
    line: "Glass and ember, no motion.",
    on: ["glass", "ember", "round"],
  },
];

export const byId = (id: Effect): Customization => CUSTOMIZATIONS.find((item) => item.id === id)!;

/** The pill under a name: where it comes from and whether it has merged. */
export function sourceLabel(source: Source): string {
  if (source.kind === "preference") return "Preference";
  return source.merged ? `PR #${source.number}` : `PR #${source.number} · unmerged`;
}

/** What trying a setup changes from what is on now: the customizations it adds and the ones it removes. */
export function diff(current: ReadonlySet<Effect>, setup: Setup): { adds: Effect[]; removes: Effect[] } {
  const next = new Set(setup.on);
  return {
    adds: CUSTOMIZATIONS.map((item) => item.id).filter((id) => next.has(id) && !current.has(id)),
    removes: CUSTOMIZATIONS.map((item) => item.id).filter((id) => !next.has(id) && current.has(id)),
  };
}

/** A conflict that is live: both customizations on, and which one wins (the later in the list). */
export function liveConflicts(on: ReadonlySet<Effect>): { loser: Effect; winner: Effect }[] {
  return CUSTOMIZATIONS.flatMap((item) =>
    item.conflictsWith && on.has(item.id) && on.has(item.conflictsWith)
      ? [{ loser: item.conflictsWith, winner: item.id }]
      : [],
  );
}
