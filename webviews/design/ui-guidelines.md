# UI guidelines

These rules keep compact controls legible and predictable across density modes.

## Spacing

- Keep at least `var(--ds-space-2)` (8px at the default density) between a disclosure chevron and a status mark or label that appears beside it.
- Use design tokens for spacing so the relationship scales with the active density.

## Hit targets

- Interactive controls expose at least `var(--ds-control-icon)` (24px at the default density) in both axes. A visual glyph may be smaller inside that box.
- Keep the hit box stable while labels or status marks appear so the pointer does not chase a moving target.

## Animation duration

- Use the shared motion tokens for transitions. Micro feedback uses the short action token, and structural movement uses the move token.
- A compact control does not introduce a raw duration longer than 200ms. Reduced-motion and motion-off modes remove structural movement.

`scripts/check-ui-guidelines.ts` checks the tray controls and fails when these rules regress. Its test fixtures include the pre-fix chevron spacing so a too-close mark cannot return silently.
