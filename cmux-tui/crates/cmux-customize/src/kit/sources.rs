//! The kit's TypeScript and the token schemas, compiled in. Paths are
//! relative to `webviews/src` (sources, galleries) and the repository root
//! (schemas). Each `include_str!` is a literal so CI's crate graph
//! (scripts/ci/affected_jobs.py) sees the file as this crate's input.
//! `kit_tests.rs` fails when kit/index.ts re-exports from a file
//! that is not listed here, so a new kit piece cannot go missing.

/// The kit barrel and every file a kit component or a type it names lives in.
pub static SOURCES: &[(&str, &str)] = &[
    ("kit/index.ts", include_str!("../../../../../webviews/src/kit/index.ts")),
    ("kit/Row.tsx", include_str!("../../../../../webviews/src/kit/Row.tsx")),
    ("kit/List.tsx", include_str!("../../../../../webviews/src/kit/List.tsx")),
    ("kit/Pill.tsx", include_str!("../../../../../webviews/src/kit/Pill.tsx")),
    ("kit/Avatar.tsx", include_str!("../../../../../webviews/src/kit/Avatar.tsx")),
    ("kit/Field.tsx", include_str!("../../../../../webviews/src/kit/Field.tsx")),
    ("kit/Glass.tsx", include_str!("../../../../../webviews/src/kit/Glass.tsx")),
    ("kit/GlassMenu.tsx", include_str!("../../../../../webviews/src/kit/GlassMenu.tsx")),
    ("kit/PopoverButton.tsx", include_str!("../../../../../webviews/src/kit/PopoverButton.tsx")),
    ("kit/tokens.ts", include_str!("../../../../../webviews/src/kit/tokens.ts")),
    (
        "kit/presets/SessionList.tsx",
        include_str!("../../../../../webviews/src/kit/presets/SessionList.tsx"),
    ),
    (
        "kit/presets/sessionLook.ts",
        include_str!("../../../../../webviews/src/kit/presets/sessionLook.ts"),
    ),
    ("ui/Button.tsx", include_str!("../../../../../webviews/src/ui/Button.tsx")),
    ("ui/Popover.tsx", include_str!("../../../../../webviews/src/ui/Popover.tsx")),
    ("ui/Input.tsx", include_str!("../../../../../webviews/src/ui/Input.tsx")),
    ("kit/version.ts", include_str!("../../../../../webviews/src/kit/version.ts")),
    ("ui/Tooltip.tsx", include_str!("../../../../../webviews/src/ui/Tooltip.tsx")),
    ("ui/Menu.tsx", include_str!("../../../../../webviews/src/ui/Menu.tsx")),
    ("ui/surface/Surface.tsx", include_str!("../../../../../webviews/src/ui/surface/Surface.tsx")),
    (
        "ui/motion/motionTokens.ts",
        include_str!("../../../../../webviews/src/ui/motion/motionTokens.ts"),
    ),
    (
        "ui/motion/motionMode.ts",
        include_str!("../../../../../webviews/src/ui/motion/motionMode.ts"),
    ),
    ("ui/StatusGlyph.tsx", include_str!("../../../../../webviews/src/ui/StatusGlyph.tsx")),
    (
        "ui/statusGlyphs.generated.ts",
        include_str!("../../../../../webviews/src/ui/statusGlyphs.generated.ts"),
    ),
    (
        "agent-session/acpmux/icons/Icon.tsx",
        include_str!("../../../../../webviews/src/agent-session/acpmux/icons/Icon.tsx"),
    ),
    (
        "agent-session/acpmux/conversation/icons.tsx",
        include_str!("../../../../../webviews/src/agent-session/acpmux/conversation/icons.tsx"),
    ),
    (
        "agent-session/acpmux/conversation/Spinner.tsx",
        include_str!("../../../../../webviews/src/agent-session/acpmux/conversation/Spinner.tsx"),
    ),
];

/// The gallery files whose `componentEntry({covers})` name a kit component.
pub static GALLERIES: &[(&str, &str)] = &[
    ("kit/kit.gallery.tsx", include_str!("../../../../../webviews/src/kit/kit.gallery.tsx")),
    ("ui/Button.gallery.tsx", include_str!("../../../../../webviews/src/ui/Button.gallery.tsx")),
    (
        "ui/FocusRing.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/FocusRing.gallery.tsx"),
    ),
    ("ui/Input.gallery.tsx", include_str!("../../../../../webviews/src/ui/Input.gallery.tsx")),
    ("ui/Popover.gallery.tsx", include_str!("../../../../../webviews/src/ui/Popover.gallery.tsx")),
    (
        "ui/StatusGlyph.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/StatusGlyph.gallery.tsx"),
    ),
    (
        "agent-session/acpmux/icons/NekoIconGallery.gallery.tsx",
        include_str!(
            "../../../../../webviews/src/agent-session/acpmux/icons/NekoIconGallery.gallery.tsx"
        ),
    ),
    (
        "agent-session/acpmux/conversation/BackgroundSpinner.gallery.tsx",
        include_str!(
            "../../../../../webviews/src/agent-session/acpmux/conversation/BackgroundSpinner.gallery.tsx"
        ),
    ),
    (
        "agent-session/acpmux/conversation/HighlightContrast.gallery.tsx",
        include_str!(
            "../../../../../webviews/src/agent-session/acpmux/conversation/HighlightContrast.gallery.tsx"
        ),
    ),
    (
        "agent-session/acpmux/offer/SuggestedTasks.gallery.tsx",
        include_str!(
            "../../../../../webviews/src/agent-session/acpmux/offer/SuggestedTasks.gallery.tsx"
        ),
    ),
    (
        "ui/HoverSurface.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/HoverSurface.gallery.tsx"),
    ),
    ("ui/Menu.gallery.tsx", include_str!("../../../../../webviews/src/ui/Menu.gallery.tsx")),
    (
        "ui/MenuLookKeys.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/MenuLookKeys.gallery.tsx"),
    ),
    (
        "ui/MenuLooks.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/MenuLooks.gallery.tsx"),
    ),
    (
        "ui/MenuRowStates.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/MenuRowStates.gallery.tsx"),
    ),
    (
        "ui/MenuStyleV2.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/MenuStyleV2.gallery.tsx"),
    ),
    ("ui/Tooltip.gallery.tsx", include_str!("../../../../../webviews/src/ui/Tooltip.gallery.tsx")),
    (
        "ui/glass/MenuMaterial.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/glass/MenuMaterial.gallery.tsx"),
    ),
    (
        "ui/surface/Surface.gallery.tsx",
        include_str!("../../../../../webviews/src/ui/surface/Surface.gallery.tsx"),
    ),
];

static SCHEMAS: &[(&str, &str)] = &[
    (
        "schemas/design-scale/design-scale.json",
        include_str!("../../../../../schemas/design-scale/design-scale.json"),
    ),
    (
        "schemas/design-roles/design-roles.json",
        include_str!("../../../../../schemas/design-roles/design-roles.json"),
    ),
    (
        "schemas/type-scale/type-scale.json",
        include_str!("../../../../../schemas/type-scale/type-scale.json"),
    ),
    (
        "schemas/motion-scale/motion-scale.json",
        include_str!("../../../../../schemas/motion-scale/motion-scale.json"),
    ),
    (
        "schemas/instrument/instrument.json",
        include_str!("../../../../../schemas/instrument/instrument.json"),
    ),
    (
        "schemas/agent-pane/style-tokens.json",
        include_str!("../../../../../schemas/agent-pane/style-tokens.json"),
    ),
];

pub(super) fn schema(path: &str) -> Option<&'static str> {
    SCHEMAS.iter().find(|(p, _)| *p == path).map(|(_, text)| *text)
}

pub(super) fn source(path: &str) -> Option<&'static str> {
    SOURCES.iter().find(|(p, _)| *p == path).map(|(_, text)| *text)
}
