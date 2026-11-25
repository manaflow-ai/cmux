# Instrument: changelog

The versions of Instrument, cmux's web component kit (`kit/index.ts`, `INSTRUMENT_VERSION` in `version.ts`).
A patch adds or re-exports pieces and moves no pixel; a minor moves a drawn default; a major removes or
renames a piece. The token file (`schemas/instrument/instrument.json`) keeps its own changelog.

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
