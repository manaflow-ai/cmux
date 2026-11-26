// The pairs cmux's chat draws under the WCAG minimum today, each with its cause, held by
// golden-look-contrast-N.test.ts (the golden screen under every look). A failing line no entry matches
// is a new light-on-light or dark-on-dark pair.
import type { ContrastLine } from "./contrastWalk";

/**
 * An entry matches a failing line whose element (the last step of its path) has `element`'s class,
 * of `kind`. A GOLDEN_KNOWN entry's `element` may be "*" (any element), only with `looks`.
 */
export type Known = { element: string; kind: ContrastLine["kind"]; cause: string };
export const KNOWN: Known[] = [
  {
    element: "acpmux-md-placeholder",
    kind: "text",
    cause:
      "the composer placeholder's tone, --acpmux-composer-placeholder (styles.css: 34% text over the base): 2.37:1 light, 2.71:1 dark; a deliberate placeholder tone, a design call",
  },
  {
    element: "acpmux-mode-text",
    kind: "text",
    cause:
      "the mode chip ('Manual') draws --agent-muted, the theme's textSecondary: #828282 on white 3.84:1, #838383 on #1e1e1e 4.4:1 and on Codex's #292929 box 3.84:1; the theme token, not the chat's CSS",
  },
  {
    element: "cv-worked__lead",
    kind: "text",
    cause: "the live run's 'Running' line draws --agent-muted (the theme's textSecondary), as the mode chip",
  },
  {
    element: "cv-shimmer__base",
    kind: "text",
    cause: "the live run's tool line draws --agent-muted (the theme's textSecondary), as the mode chip",
  },
  {
    element: "acpmux-permission-command-preview",
    kind: "text",
    cause:
      "the permission card's command preview draws --agent-soft (the theme's soft text, #828282 / #838383): 3.43:1 light, 3.82:1 dark on its 5% tint",
  },
  {
    element: "acpmux-permission-keys-or",
    kind: "text",
    cause:
      "the '/' between a permission button's two key letters (aria-hidden) at 45% of the button's ink (styles.css): 2.8 to 4.4:1",
  },
];

/** The classes a failing line is matched by: its own element's, or its parent's for a bare tag (code). */
function classesOf(line: ContrastLine): string[] {
  const steps = line.selector.split(" > ");
  const own = steps.at(-1)!.split(".").slice(1);
  return own.length ? own : (steps.at(-2)?.split(".").slice(1) ?? []);
}

/** The KNOWN entry for a failing line. */
export function knownFor(line: ContrastLine): Known | undefined {
  const classes = classesOf(line);
  return KNOWN.find((known) => known.kind === line.kind && classes.includes(known.element));
}

/**
 * Pairs only the golden screen draws under the minimum today (the chat's own parts are in KNOWN).
 * An entry without `looks` fails under the stock cmux look too: the chat's own colors, not a look's.
 * An entry with `looks` fails only under those looks: that look's own ink, held to those looks so the
 * same element under any other look still fails. Found by the first golden run on 2026-11-19 (worst
 * ratio given); each is a fix to make, tracked in the PR's follow-up, and the list only shrinks.
 */
export type GoldenKnown = Known & { looks?: string[] };
const CLAUDE_LIGHT_INK = ["claude", "studio", "theme-claude-desktop", "theme-customize-leo-daylight-leo-daylight"];
/** Theme files with no chat stylesheet: tool rows and "Worked for" draw the stock 58% of their text. */
const STOCK_ACTIVITY_INK = ["theme-moss", "appearance"];
/**
 * Looks whose whole palette reads under the minimum (found 2026-11-23, after they landed): held look-wide
 * (element "*"), so every other look still fails on the same element. Each is the look's own fix to make.
 */
const WHOLE_PALETTE = ["plush", "plush-addon", "plush-dusk-addon", "plush-clay-addon", "whole", "theme-meadow"];
export const GOLDEN_KNOWN: GoldenKnown[] = [
  {
    element: "acpmux-model-detail",
    kind: "text",
    cause:
      "the model chip's effort ('High') draws the theme's dim ink: 2.9:1 at worst (Claude light #949491 on #faf9f5), under every look",
  },
  {
    element: "cv-edit-diff__hunks",
    kind: "text",
    cause:
      "syntax colors inside the permission card's diff sit on the added and removed line tints (e.g. #377b97 on #e7d3d1 3.28:1; classic-desktop #007f7f on #e5cbcb 3.16:1): the highlighter's palette is not fitted to the tints",
  },
  {
    element: "cv-tool-error",
    kind: "text",
    cause: "a failed tool's message draws --agent-muted (the theme's textSecondary): 3.74:1 at worst on white",
  },
  {
    element: "cv-edit-diff__add",
    kind: "text",
    cause: "the diff header's '+N' green on its header fill: 4.02:1 at worst (#1f852f on #ededed)",
  },
  {
    element: "cv-edit-diff__del",
    kind: "text",
    cause: "the diff header's '-N' red on its header fill: 4.08:1 at worst (#d13930 on #ebecec)",
  },
  ...["cv-tool__text", "cv-tool__file", "cv-tool__summary", "cv-worked__label", "cv-worked__label-time"].map(
    (element): GoldenKnown => ({
      element,
      kind: "text",
      looks: CLAUDE_LIGHT_INK,
      cause:
        "the Claude-style light looks' muted ink for tool rows and 'Worked for' (#827c90 on #fbf8ff, 3.8:1): the look's own tone",
    }),
  ),
  ...["cv-tool__text", "cv-tool__file", "cv-tool__summary", "cv-worked__label", "cv-worked__label-time"].map(
    (element): GoldenKnown => ({
      element,
      kind: "text",
      looks: STOCK_ACTIVITY_INK,
      cause:
        "a theme file with no chat stylesheet: tool rows and 'Worked for' at the stock 58% of its text (Moss dark #878273 on #1e2326, 4.11:1; rex appearance light 4.0:1); the theme's text and paper",
    }),
  ),
  ...(["text", "icon"] as const).map((kind): GoldenKnown => ({
    element: "*",
    kind,
    looks: WHOLE_PALETTE,
    cause:
      "the look's palette, not one element: Plush's muted ink on its mid-grey paper (#8c95a3 on #e2e7ee, 2.43:1), whole's dark-only literal colors drawn on a light theme (1.15:1), Meadow light's muted and menu ink (2.8:1)",
  })),
  {
    element: "agent-mark",
    kind: "icon",
    cause:
      "the Claude mark's clay #d97757 (the brand color) on an off-white page: 2.94:1 against 3:1 on #f8f8f9 or #faf8f3 (Kerf, Paper light), 2.96:1 on Claude's cream #faf9f5; it passes on white",
  },
  {
    element: "acpmux-diff-add",
    kind: "text",
    looks: ["theme-classic-desktop"],
    cause: "Classic Desktop's '+N' green #008700 on #f7f7f7, 4.4:1: the theme's green",
  },
];

/** The entry that holds a failing golden-screen line under `look`: KNOWN, else GOLDEN_KNOWN. */
export function goldenKnownFor(line: ContrastLine, look: string): Known | undefined {
  const known = knownFor(line);
  if (known) return known;
  const classes = classesOf(line);
  return GOLDEN_KNOWN.find(
    (entry) =>
      entry.kind === line.kind &&
      (entry.element === "*" || classes.includes(entry.element)) &&
      (!entry.looks || entry.looks.includes(look)),
  );
}
