/**
 * The design tokens: type roles, the type scale and the spacing scale. This module imports nothing, so
 * `widget.ts` and `design.ts` (which `index.ts` re-exports, and which import `index.ts`) can both read the
 * tokens while modules load: `design.ts` builds `cmuxDesign` from them at load time, and a token defined
 * in `widget.ts` was not initialized yet when a test imported `widget.ts` first.
 */

/**
 * The type roles: each a point size and weight (Apple's widget text styles), drawn by the helper
 * named for it. Text goes through a role, not a size: `cmux ext dev` warns on a size that is not
 * one of these, and on more than four roles in one widget.
 */
export const TYPE_ROLES = {
  numeral: { size: 34, weight: "semibold" },
  heading: { size: 20, weight: "semibold" },
  title: { size: 15, weight: "semibold" },
  label: { size: 13, weight: "semibold" },
  body: { size: 13, weight: "regular" },
  caption: { size: 12, weight: "regular" },
  footnote: { size: 11, weight: "regular" },
} as const
export type TypeRole = keyof typeof TYPE_ROLES
/** The type scale, in points (Apple's widget text styles): `TYPE_ROLES`' sizes. */
export const WIDGET_TYPE = {
  bigNumber: TYPE_ROLES.numeral.size,
  title: TYPE_ROLES.title.size,
  label: TYPE_ROLES.label.size,
  body: TYPE_ROLES.body.size,
  caption: TYPE_ROLES.caption.size,
  footnote: TYPE_ROLES.footnote.size,
} as const

/**
 * The spacing scale, in points: every gap and padding is one of these (a 4 pt grid, with 2 and
 * 6 for tight rows). `cmux ext dev` warns on any other value and names the nearest step.
 */
export const SPACE = { none: 0, hairline: 2, xxs: 4, xs: 6, s: 8, m: 12, l: 16, xl: 20, xxl: 24, xxxl: 32, huge: 48 } as const
export type Space = (typeof SPACE)[keyof typeof SPACE]
