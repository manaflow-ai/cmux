//! What a pack may change. A pack names its capabilities in
//! `cmux-pack.json`; each value it sets belongs to one, and a value whose
//! capability the pack did not declare is dropped with a diagnostic. A pack
//! runs no code: the capabilities are the whole of what it can do.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    /// Look settings no other capability covers: accent, surfaces, glass,
    /// density, chrome style.
    Tokens,
    /// The terminal palette (`colors`, a `ghostty` block, `appearance.themeEdits`).
    Colors,
    /// Wallpapers, pane backgrounds and their tint, opacity and rotation,
    /// including pictures and videos shipped in the pack's `assets/`.
    Backgrounds,
    /// Animation speed and switches.
    Motion,
    /// Tab shape and tab metrics.
    Tabs,
    /// Terminal and chrome type.
    Fonts,
    /// Swappable pieces of the UI: theme slot variants and the sidebar's shape.
    Components,
}

impl Capability {
    pub const ALL: [Capability; 7] = [
        Capability::Tokens,
        Capability::Colors,
        Capability::Backgrounds,
        Capability::Motion,
        Capability::Tabs,
        Capability::Fonts,
        Capability::Components,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Capability::Tokens => "tokens",
            Capability::Colors => "colors",
            Capability::Backgrounds => "backgrounds",
            Capability::Motion => "motion",
            Capability::Tabs => "tabs",
            Capability::Fonts => "fonts",
            Capability::Components => "components",
        }
    }

    pub fn parse(name: &str) -> Option<Capability> {
        Capability::ALL.into_iter().find(|capability| capability.name() == name)
    }

    /// The capability a look setting (dotted key) belongs to.
    pub fn of_key(key: &str) -> Capability {
        const BACKGROUNDS: [&str; 4] = [
            "appearance.background",
            "appearance.paneBackgrounds",
            "appearance.wallpaper",
            "ui.reducedBackgrounds",
        ];
        const MOTION: [&str; 3] = ["ui.animation", "ui.paneAnimations", "ui.calm"];
        const TABS: [&str; 2] = ["appearance.tabShape", "appearance.metrics.tab"];
        const FONTS: [&str; 4] = [
            "terminal.fontFamily",
            "terminal.fontSize",
            "appearance.font",
            "appearance.metrics.chromeFont",
        ];
        // Everything that changes the terminal palette: the theme file's own
        // `colors` and `ghostty` blocks and the per-theme color edits they
        // become. A pack sets them only with the colors capability.
        const COLORS: [&str; 3] = ["colors", "ghostty", "appearance.themeEdits"];
        let starts = |prefixes: &[&str]| prefixes.iter().any(|prefix| key.starts_with(prefix));
        let under = |roots: &[&str]| {
            roots.iter().any(|root| {
                key.strip_prefix(root).is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
            })
        };
        if under(&COLORS) {
            Capability::Colors
        } else if key == "slots" || key.starts_with("slots.") {
            Capability::Components
        } else if starts(&BACKGROUNDS) {
            Capability::Backgrounds
        } else if starts(&MOTION) {
            Capability::Motion
        } else if starts(&TABS) {
            Capability::Tabs
        } else if starts(&FONTS) {
            Capability::Fonts
        } else if key.starts_with("sidebar.") {
            Capability::Components
        } else {
            Capability::Tokens
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Capability;

    #[test]
    fn keys_map_to_their_capability() {
        assert_eq!(Capability::of_key("appearance.background"), Capability::Backgrounds);
        assert_eq!(Capability::of_key("appearance.backgroundOpacity"), Capability::Backgrounds);
        assert_eq!(Capability::of_key("ui.animationSpeed"), Capability::Motion);
        assert_eq!(Capability::of_key("appearance.tabShape"), Capability::Tabs);
        assert_eq!(Capability::of_key("appearance.metrics.tabHeight"), Capability::Tabs);
        assert_eq!(Capability::of_key("terminal.fontFamily"), Capability::Fonts);
        assert_eq!(Capability::of_key("appearance.metrics.chromeFontSize"), Capability::Fonts);
        assert_eq!(Capability::of_key("sidebar.sectionLook"), Capability::Components);
        assert_eq!(Capability::of_key("appearance.accent"), Capability::Tokens);
        // The terminal palette is colors, however it is written.
        assert_eq!(Capability::of_key("ghostty"), Capability::Colors);
        assert_eq!(Capability::of_key("colors"), Capability::Colors);
        assert_eq!(Capability::of_key("appearance.themeEdits"), Capability::Colors);
        assert_eq!(Capability::of_key("appearance.themeEdits.Nord/background"), Capability::Colors);
        assert_eq!(Capability::of_key("colorsish"), Capability::Tokens);
        assert_eq!(Capability::of_key("slots"), Capability::Components);
    }

    #[test]
    fn names_round_trip() {
        for capability in Capability::ALL {
            assert_eq!(Capability::parse(capability.name()), Some(capability));
        }
        assert_eq!(Capability::parse("shell"), None);
    }
}
