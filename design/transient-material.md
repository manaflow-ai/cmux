# One transient material

Leo, 2026-11-11: translucency is intended; use one coherent material style, never
an opaque replacement. The scoped implementation adopts this across non-chat Mac
and iOS surfaces. Chat-side adoption remains held; no shared default may change a
chat consumer indirectly in that baseline. The separate
[chat-adoption draft](transient-material-chat.md) prepares those shared/default
changes; its hold is on landing, not source preparation or draft publication.

## References and choice

Start with the private `cmux-design-references/README.md` and `index.json`, then
`apps/claude/live/NOTES.md`, `apps/codex/live/NOTES.md`, macOS and mobile captures.
The comparison set includes the toast stack, account menus, desktop hover cards
and system sheets indexed there. Source reference images and side-by-sides stay in
private `cmuxterm-hq/design/transient-surfaces.md`; public descriptions use sizes
and behavior. This extends `surface-materials.md`, not its renderer ownership.

The standard candidate uses regular native glass and a neutral/theme veil, with
quieter and denser comparisons. Pick the standard because it reuses the existing
toast veil and web menu frost, retaining readable text while showing the backdrop.
The gallery must still be captured and inspected before that choice is called
visually verified. No screenshot receipt exists at this source-edit stage.

## Token and platform adapters

`schemas/design-scale/design-scale.json:transientMaterial` is the common numeric
contract. `CmuxTheme.TransientMaterial.standard` is ordinary checked source, not a
new committed generated artifact. `gen-design-scale.mjs` checks it and emits the
existing web scale. `check-surface-roles.py` binds the unchanged toast role to it.

| Property | Value / owner |
| --- | --- |
| Dark/light native veil | 0.42 / 0.55 |
| Native regular-glass tint multiplier | 1.25 |
| Dark rim top/bottom | 0.30 / 0.06 |
| Light rim top/bottom | 0.85 / 0.10 |
| Web simulated menu tint / frost | 78%; 32 px blur, saturation 1.6 |
| Native-host web veil | 40%; no second backdrop blur |
| Native neutral seed | 0.11 dark / 0.99 light |
| Mac theme | Current scoped theme tint, never accent-as-material |
| iOS theme | Phone neutral material; never paired Mac wallpaper/theme |
| Accessibility | System Reduce Transparency remains opaque; tooltip ink remains contrast-fitted |

These are one material's renderer parameters, not independent surface-specific
choices. Native glass, native sheet material, web simulation and host glass have
different compositing paths. App-owned native surfaces call
`Glass.makeOverlayPanel(tone: .neutralGlass(.transient))`; the newly merged `Glass.makeMenuPanel` component
keeps its row/veil behavior and reads the common host-veil token; web standalone pages explicitly import
`pages/shared/transientMaterial`; iOS uses `CmuxMobileTransientMaterial.standard`.
System `NSMenu`, `UIMenu`, SwiftUI Menu, alerts and share controllers remain
system-owned. Replacing them with custom glass would violate native ownership.

## Geometry and behavior

Material changes do not alter content layout. Radius comes from the existing
role: `PopupStyle` for popovers/menus, `Metrics.corners` for native panels,
`SurfaceRole` for toast/sheet/tooltip and the existing iOS capsule or continuous
rectangle. Selected rows keep the content-surface fill. Type, icon size and row
spacing remain the existing design-scale/type tokens and platform text styles.

No motion is added. Existing popup entrance/close, tooltip delay, toast expiry,
sheet detents, keyboard handling, dismissal and stacking stay with their owners.
Toasts keep their placement/queue rules; tooltips retain 4.5:1 contrast fitting;
menus stay anchored to their control; sheets stay attached to their presenting
window or native iOS presentation. The token never changes z-order or timing.

## Non-chat Mac inventory

| Surface | Owner / adoption |
| --- | --- |
| Palette and actions/shortcut popovers | `CmuxNextPalette`, shared native factory |
| Browser info, extensions, downloads, bookmark editing, link bubble, prompt bars, unresponsive card | Existing native owners, shared factory |
| Browser dialogs / HTTP auth / extension prompt | `CmuxDialogSpec(usesTransientMaterial: true)` |
| Sidebar/group editors, tab-group editor, zoom HUD, notifications, icon picker, host pressure | Shared factory; persistent sidebar/chrome remains window material |
| Hover cards in sidebar/tabs | `HoverCardPanel`, shared factory |
| Find pill and which-key HUD | Shared factory; browser/terminal/find only |
| Remote state, latency, toolbar, upstream indicator and VNC dialogs | Shared factory / explicit dialog opt-in |
| Import, onboarding, password, quit, pairing, terminal, updater and screen-share dialogs | Explicit non-chat dialog opt-in; no shared dialog default change |
| Native toasts | Existing toast role now aliases the equal-valued common token |
| Native tooltips | Existing contrast-fitted `TooltipSurface`; underlying native popover tint reads the common token with equal values |
| Standalone non-chat page popups | Newly merged `Glass.makeMenuPanel` host, whose equal-valued veil reads the common token |
| Standalone non-chat web menus/cards/dialogs/tooltips/toasts | Scoped CSS adapter; imported by Settings, browser-management, cloud/device, onboarding and utility pages |
| Native menus and platform share UI | Preserve merged account `GlassMenu`; right-click and platform share UI remain system-owned |

The complete native renderer inventory remains
`schemas/surface-materials/surface-materials.json`; the existing detector recognizes the same factory throughout adoption.
The per-call-site iOS inventory and capture matrix are in
`cmux-next-ios/design/transient-material.md`, including removed opaque sheet
backdrops and explicitly scoped toast adapters.

## Held chat adoption, ready follow-up

The separate draft prepares this adoption now; landing waits for the chat visual
hold to lift. Use the same token, without inventing another material. Move the
standalone CSS rules into the shared `ui/glass/glass.css` and
`popupSurface.css` ownership, then remove the explicit standalone imports. Adopt
ContextUsageRing and its iOS `SessionMeterViews` popover. Keep the newly merged native-menu host intact; propagate explicit dialog material to chat-owned
asks, and opt chat toast/banner callers into the iOS adapter. Keep contrast and
Reduce Transparency behavior unchanged.

Also held: Home messaging/Conversations sheets, recipient suggestions and native
transcript agent cards; agent permissions and agent-share invite cards; Chief
Pet/Quick Composer; mixed diff/editor/markdown/files/task/feed/message pages;
unknown pushed iOS routes. These can display or cover chat. Conservative ownership
is intentional, not an undocumented alternate material. Root-level factories and
shared component defaults therefore remain legacy unless explicitly opted in.

## Gallery and verification

- Web `ui.transient-material`: before, standard, quieter and denser in both
  appearances; six material samples. The CSS is inert outside explicitly scoped
  pages and gallery stages. Web palette/menu samples are not native-menu proof.
- Mac `debug.hover_cards` galleries `transient-popover`, `transient-menu`,
  `transient-tooltip`, `transient-palette`, `transient-toast`, `transient-sheet`:
  native factory material comparisons, with actual production captures for layout.
- iOS `TransientMaterialCaptureUITests`: production sheet, palette, toast,
  banner and system menu, four variants in light/dark. System menus intentionally
  do not change between candidates.

Run source guards, fleet web checks, native material/overlay tests and iOS
behavior/capture suites. Inspect captured standard against before in each
appearance, with Reduce Transparency and accessibility text checks. Record exact
head, runner and artifact receipt in the PR before claiming visual completion.
