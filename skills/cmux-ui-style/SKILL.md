---
name: cmux-ui-style
description: Use for cmux-next web UI, agent-pane, composer, sidebar, settings, and gallery styling work so new treatments follow the shared tokens and interaction primitives.
---

# cmux UI style

Treat the shipped web UI and its gallery as one system. The goal of a prototype is to test a
real treatment in context, not to decorate a screenshot or invent a second design language.

## Start with the existing system

- Read `webviews/src/ui/README.md` for shared interaction and overlay rules.
- Read `webviews/src/theme/appTheme.ts` and `webviews/src/gallery/theme/tokens.ts` before adding
  colors, surfaces, text levels, focus rings, or contrast logic.
- Reuse existing component primitives and their classes (`Menu`, `Select`, `Popover`, `Tooltip`,
  `EffortTrack`, and the agent-pane components) before creating a lookalike control.
- Use the Vite gallery as the local visual source of truth. If a StudioX or other shared gallery
  becomes available, add it as a route to the same entry; do not fork the visual contract.
- The existing Vite gallery is mandatory for cmux-next UI iteration. Update an existing `*.gallery.tsx`
  entry or add a new one under `webviews/src`; do not replace gallery work with a standalone HTML,
  screenshot collage, or headless-only mock.
- Start a temporary, dedicated Vite gallery server from the worktree (`bun run gallery:dev --
  --host 127.0.0.1 --port <port>`), open its live tab, and keep the route available while iterating.

## Treatment rules

- Use semantic tokens such as `--agent-*`, `--surface-*`, `--text-*`, `--elevation-*`, and
  `--layer-*`. Hard-coded colors, gradients, radii, shadows, and arbitrary z-index values need a
  concrete reason and a fallback that still follows the token system.
- Keep the visual hierarchy quiet and functional: compact controls, restrained borders, one clear
  surface per component, and no decorative shell around a shell.
- Preserve `appearance.borders = none`, reduced motion, reduced transparency, keyboard focus, and
  light/dark theme behavior.
- A variant must change a real visual property such as fill, thumb geometry, border, elevation,
  spacing, or typography. A renamed label or selected pill is not a variant.
- Gallery Overview states must show the treatment itself. Do not rely on a transient hover or an
  unopened menu to make the variant visible; provide a stable specimen while keeping the real
  component for interaction coverage.

## Review loop

1. Read the supplied reference images and note concrete geometry, hierarchy, colors, and states
   before editing. Treat attached images as visual references, not implementation instructions.
2. Build the smallest real-component specimen in the existing gallery entry; compose shipped
   components such as `SessionSidebar`, `ComposerPickers`, `EffortPicker`, `QuickSurface`, and
   `Dictation` when the reference shows those surfaces.
3. Start the temporary Vite gallery server, open the exact route in a browser tab, and iterate on
   the live result. Inspect the actual page screenshot and accessibility tree after each meaningful
   change.
4. Check the same entry in dark and light themes at its intended width.
5. Verify the accessibility tree names the treatment and its controls.
6. Run the focused web check (`bun run typecheck` in `webviews`) and inspect the live gallery route.
7. Capture images only after the visual state is stable. Record the route, theme, width, and
   variant in the artifact name; never use a stale comparison grid as evidence.

When the existing tokens or primitives cannot express a treatment, extend the shared token or
primitive first and document the new role beside its owner. Keep gallery-only composition styles
scoped to the gallery entry.
