# Instrument: changelog

The versions of Instrument, cmux's web component kit (`kit/index.ts`, `INSTRUMENT_VERSION` in `version.ts`).
A patch adds or re-exports pieces and moves no pixel; a minor moves a drawn default; a major removes or
renames a piece. The token file (`schemas/instrument/instrument.json`) keeps its own changelog.

## Unreleased (the next patch)

Variants a host with its own sheet (the customize scene renderer) needs to draw with the kit,
each off unless asked for and each reproducing a value the app already draws. No pixel moves.

- `Button` `bare`: only the caller's class, no button look of its own.
- `Row`: a `ref` and every other attribute or handler on the row element; `subtitleSize="detail"`;
  `--kit-row-selected-fill` for a host's selection fill.
- `Pill` `size="xs"`: the scene badge (16 tall, the detail step, a 14% fill of its own color);
  `--kit-pill-radius` for a host's corner.
- `grid(name)`, `GRID`: the layout grid's `--grid-*` lengths, which follow the interface scale.
- `--ds-radius-full` (999px), `radius("full")`.

## 0.1.0 (2026-11-25)

The look the app draws today, named. No product surface changes; only the kit gallery gains entries.

Components:

- `Row`, `List`, `Pill`, `Avatar`, `Field`, `Glass`, `GlassMenu`, `PopoverButton` (kit's own).
- `Button`, `Popover`, `Input`, `StatusGlyph` (`ui/`), `Icon`, `Spinner` (the agent pane's).
- `Tooltip`, `TooltipProvider` (`ui/Tooltip`).
- `Card` and `AnchoredCard`, the same component (`ui/Tooltip`'s hover card).
- `Menu`, `MenuButton`, `MenuPopup`, `MenuItem`, `MenuCheckboxItem`, `MenuRadioGroup`, `MenuRadioItem`,
  `MenuGroup`, `MenuSeparator`, `Submenu` (`ui/Menu`).
- `Panel` and `Surface`, the same component (`ui/surface/Surface`), with its slots.
- `SessionList`, `MinimalSessions`, `sessionLook`, `DEFAULT_SESSION_LOOK`, `MINIMAL_SESSIONS_LOOK`.

Tokens and motion:

- `color`, `space`, `control`, `icon`, `radius`, `text`, `textLineHeight`, `motion`; the lists `COLORS`,
  `CONTROLS`, `ICONS`, `MOTION`, `RADII`, `SPACING`, `TEXT`, `ELEVATION`; `EASE_STANDARD`.
- `motionToken`, `warmMotionTokens` (`ui/motion/motionTokens`), `motionMode`, `springEasing`
  (`ui/motion/motionMode`).

Types: every component's props, `GlassLevel`, `PillSize`, `PillTone`, `RowDensity`, `AvatarSize`,
`ButtonSize`, `ButtonVariant`, `UiAnchor`, `StatusGlyphName`, `PanelRole`, `SurfaceRole`, `SurfaceTone`,
`MotionMode`, the token name types, `Session`, `SessionState`, `SessionLook`.

- `INSTRUMENT_VERSION`: `"0.1.0"`.
