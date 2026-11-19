// The pairs cmux's default chat draws under the WCAG minimum today, each with its cause: shared by
// look-contrast.test.ts (which fails once one stops failing, so the list only shrinks) and
// golden-look-contrast.test.ts (the golden screen under every look). A failing line no entry matches
// is a new light-on-light or dark-on-dark pair.
import type { ContrastLine } from "./contrastWalk";

/**
 * An entry matches a failing line whose element (the last step of its path) has `element`'s class,
 * of `kind`.
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

/** The KNOWN entry for a failing line: its own element's classes, or its parent's for a bare tag (code). */
export function knownFor(line: ContrastLine): Known | undefined {
  const steps = line.selector.split(" > ");
  const own = steps.at(-1)!.split(".").slice(1);
  const classes = own.length ? own : (steps.at(-2)?.split(".").slice(1) ?? []);
  return KNOWN.find((known) => known.kind === line.kind && classes.includes(known.element));
}
