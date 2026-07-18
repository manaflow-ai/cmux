# 03 Meridian — liquid-glass native

The most iOS-native candidate: content runs edge-to-edge and all chrome floats above it as Liquid Glass, per the iOS 26 HIG. Chrome is monochrome (ChatGPT-style) so the only saturated pixels on screen are status signals and the single accent. Where Phosphor builds its own world, Meridian disappears into the platform — lowest long-term maintenance, automatic fit with every OS release.

## Color

- Backgrounds: `systemBackground` / `secondarySystemBackground` / `tertiarySystemFill` — no custom surface colors at all.
- Text: `label` / `secondaryLabel` / `tertiaryLabel`.
- Accent: indigo #5B5BD6 (dark: #7A7AE8) — placeholder brand accent, used only for the primary action and selection.
- Status: needsYou `systemOrange`, running accent-indigo, done `systemGreen`, failed `systemRed`, idle `tertiaryLabel`. Rendered as SF Symbols with tint, not custom dots: `person.crop.circle.badge.exclamationmark`, `arrow.triangle.2.circlepath`, `checkmark.circle.fill`, `xmark.circle.fill`, `moon.zzz`.
- Chrome (toolbar icons, tab labels): monochrome `label`/`secondaryLabel` only.

## Type

SF Pro, standard Dynamic Type styles only: `.largeTitle` nav, `.headline` row titles, `.body`, `.subheadline`, `.caption`. Mono via `.monospaced()` design for terminal and branch names. No custom sizes.

## Shape

Concentric radii: full-bleed content, cards 26 (hugging device corners), controls capsule. Standard `insetGrouped` metrics for lists.

## Glass

Everywhere chrome exists, nowhere content does:
- Floating capsule tab bar bottom-center: Home / Activity / Settings, glass, selected item tinted.
- Session/Chat action cluster: `GlassEffectContainer` holding circular glass buttons (approve, keyboard, more) that would morph between states on iOS 26.
- Composer: glass capsule field.
- Nav large-title with scroll-edge effect; sheets with glass grabber region.
All through the gated `mobileGlass*` helpers with iOS 18 material fallbacks.

## Motion

System defaults only: standard springs, `symbolEffect(.pulse)` on the running symbol, matched-geometry morph between tab bar and expanded controls where iOS 26 allows. Nothing custom-timed.

## Ergonomics

Floating tab bar keeps global nav permanently in thumb reach. Primary per-item actions via standard swipe actions and context menus (platform muscle memory). Approve appears both as a swipe action and as the prominent glass button in Session — one shared action, two entrypoints.

## Screens

- **Hub**: large-title "cmux". Needs-you items in a promoted "For you" `insetGrouped` section with tinted symbol + orange badge count on the tab bar; the rest in a plain section. Rows: headline name, subheadline branch (monospaced), trailing relative time; running rows show the pulsing symbol.
- **Session**: edge-to-edge terminal mock behind everything; top status bar is a glass capsule (symbol + workspace + elapsed); bottom-right `GlassEffectContainer` cluster: keyboard, approve (accent-filled when pending), overflow.
- **Chat**: standard chat metrics; agent messages plain `body` on background, user messages in `secondarySystemBackground` bubbles; tool call = `insetGrouped`-style card with monospaced command and DisclosureGroup output; approval = card with `.borderedProminent` (accent) Approve + `.bordered` Deny; composer is the glass capsule.
- **Activity**: sectioned by day, standard list, tinted symbols per event type, unread dot in accent; mirrors notification center conventions.
- **Settings**: pure `insetGrouped` system form — deliberately indistinguishable from a first-party app.
- **Specimen**: accent + status tints over system backgrounds in both schemes, Dynamic Type ramp, glass elements row, symbol vocabulary with meanings.
