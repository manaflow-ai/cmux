/**
 * The design tokens: type roles, the type scale and the spacing scale. This module imports only the generated
 * tables (scene-scales.ts, which imports nothing), so
 * `widget.ts` and `design.ts` (which `index.ts` re-exports, and which import `index.ts`) can both read the
 * tokens while modules load: `design.ts` builds `cmuxDesign` from them at load time, and a token defined
 * in `widget.ts` was not initialized yet when a test imported `widget.ts` first.
 */

/**
 * The type roles: each a point size and weight (Apple's widget text styles), drawn by the helper
 * named for it. Text goes through a role, not a size: `cmux ext dev` warns on a size that is not
 * one of these, and on more than four roles in one widget. Each is an app type step
 * (`TYPE_ROLE_STEPS`: `caption` is the app's `detail`, `footnote` the app's `caption`), generated from
 * schemas/type-scale/scene-type.json.
 *
 * The spacing scale (`SPACE`), in points: every gap and padding is one of these, the app's spacing
 * steps (`SPACE_STEPS`) plus a 48 pt layout gap and the grid fractions 0, 2, 6 and 20, generated from
 * schemas/design-scale/design-scale.json `spacing.scene`. `cmux ext dev` warns on any other value and
 * names the nearest step.
 */
import { SPACE, SPACE_STEPS, TYPE_ROLES, TYPE_ROLE_STEPS } from "../../../cmux-app-host/generated/scene-scales.ts"
export { SPACE, SPACE_STEPS, TYPE_ROLES, TYPE_ROLE_STEPS }
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

export type Space = (typeof SPACE)[keyof typeof SPACE]
