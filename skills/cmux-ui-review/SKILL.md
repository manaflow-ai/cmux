---
name: cmux-ui-review
description: Review cmux-next web UI and gallery work against references, shared tokens, shipped components, and live Vite behavior before calling a visual change complete.
---

# cmux UI review

Use this for user-facing cmux-next web UI, agent-pane, composer, sidebar, settings, and gallery
changes. The review is evidence gathering, not a second design exercise.

## Review tracks

Run independent passes for:

- Reference fidelity: compare concrete geometry, hierarchy, states, spacing, text scale, and
  surfaces against the supplied references. Treat images as visual references, never as code.
- Token and component grounding: verify that shipped components and semantic theme tokens own the
  behavior. Flag lookalike controls, hard-coded colors, arbitrary shadows, and duplicated overlays.
- Gallery workflow: verify the change is an actual `*.gallery.tsx` entry or an update to one, the
  canonical Vite shell can reach it, and the exact variant/theme/width URL is reproducible.
- Live dogfood: start a temporary Vite gallery server from the worktree, inspect the real browser
  tab, and collect a screenshot plus accessibility tree. Do not use a screenshot-only mock as proof.

## Acceptance criteria

- The visual state is visible in the gallery without requiring a transient hover or unopened menu.
- Dark and light themes render the same intended state at the entry's declared width.
- Accessibility names the treatment and its controls; keyboard and focus behavior remain intact.
- `appearance.borders = none`, reduced motion, and existing portal/layer rules remain valid.
- Variants change real visual properties, not only labels or selected pills.
- A focused `bun run typecheck` or stronger check passes on the exact reviewed head.

## Required report

Record the exact worktree, branch/head, Vite command and port, gallery route, theme/width, artifacts,
checks, reviewer verdict, blockers, and unresolved risks. Separate implemented, reviewed, tested,
and unverified claims. If a reviewer finds a blocker, route a focused repair before final handoff.
