//! cmux-next `ThemeTokens` for cmux2: every chrome color derived from the
//! user's Ghostty theme, so the sidebar, titlebar and tab strips are the
//! terminal background with no seam, and selection, hover and focus are the
//! foreground at low alpha (no accent hue).
//!
//! Port of `Packages/Shared/CmuxTheme` (`ThemeTokens.swift`, `ThemeRGB.swift`,
//! `ThemeInput.swift`) on cmux `feat-cmux-next`. The Ghostty config is read
//! here (no libghostty): default files per platform, `config-file`
//! includes, `theme = ` with `light:`/`dark:` pairs and Ghostty's theme
//! directories, explicit colors over the theme, and an optional theme
//! override after the files (`Env::theme_override`: a space, workspace or
//! terminal theme, resolved as cmux-next's `ThemeResolver`). Synchronous, no
//! UI toolkit, no features or dependencies, plain `Copy` `#[repr(C)]`
//! results.
//!
//! Source of the values: the token values come from the spec's
//! `design-tokens.json` (pixel parity rule), proposed at
//! `plans/cmux-next/spec-proposals/visuals/design-tokens.json` on
//! `feat-cmux-next`, compiled in (`include_str!`) and read once: every plain
//! color formula (`alpha(..)`, `mix(..)`, `= token`) and the contrast
//! minimums come from it (`spec.rs`). The json follows the Swift source, and
//! `themes.*` there is the oracle (`spec/tests.rs`). `appearance.accent`
//! (`ThemeInput::accent`, set by the app from cmux.json) gives selection, the
//! focus ring, `highlight`, `accent` and `onAccent` the hue of Swift
//! `AppTheme` (`app_theme.rs`); `cursor-color` gives `caret`. A theme's own
//! accent (`ThemeInput::accent_color`: the theme file's `# cmux-accent`,
//! read by `load`, or the app's `appearance.themeEdits` `<theme>/accent`)
//! wins over `appearance.accent`. Do not invent other values.
//!
//! ```no_run
//! use cmux_theme_tokens::{Appearance, Env, ThemeTokens, load};
//! let loaded = load(&Env::current(), Appearance::Dark);
//! let tokens = ThemeTokens::derive(&loaded.input);
//! // Watch loaded.watch_paths() (event-driven) and call `load` again on a change.
//!
//! // A space, workspace or terminal theme: the user's config with
//! // `theme = Nord` after it (explicit colors in the files still win).
//! if let Some(env) = Env::current().with_theme_override("Nord") {
//!     let _nord = ThemeTokens::derive(&load(&env, Appearance::Dark).input);
//! }
//! ```

#![forbid(unsafe_code)]

mod app_theme;
mod colors;
mod config;
mod rgb;
mod spec;
mod tokens;

pub use app_theme::{AppTheme, AppToken, ThemeAccent};
pub use colors::parse_color;
pub use config::{
    Appearance, DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME, Env, Loaded, THEME_ACCENT_KEY,
    THEME_OVERRIDE_MAX_CHARS, load, theme_file_accent, theme_for, theme_override_value,
};
pub use rgb::Rgb;
pub use tokens::*;

/// Loads the process's Ghostty config for `appearance` and derives the
/// tokens under `borders`.
pub fn current_tokens(appearance: Appearance, borders: BorderMode) -> (ThemeTokens, Loaded) {
    let loaded = load(&Env::current(), appearance);
    (ThemeTokens::derive(&loaded.input).with_borders(borders), loaded)
}
