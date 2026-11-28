//! `FontSmoothing.swift` and `ProcessFontSmoothing.swift`: the `appearance.fontSmoothing`
//! modes, their CSS values, and what the `AppleFontSmoothing` default gives and gets written.
//!
//! The defaults reads become inputs: `saved` is what `defaults.object(forKey:)` gives now (the
//! app's own domain over the global one), `global` what is left once the app's value goes.

use serde::{Deserialize, Serialize};

/// The default AppKit and Core Graphics read (`ProcessFontSmoothing.defaultsKey`).
pub const DEFAULTS_KEY: &str = "AppleFontSmoothing";

/// What `antialiased` writes (`ProcessFontSmoothing.apply`).
pub const ANTIALIASED_VALUE: i64 = 0;

/// What `subpixel` writes over a missing value or a 0.
pub const SUBPIXEL_VALUE: i64 = 2;

/// `appearance.fontSmoothing` (`FontSmoothing`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FontSmoothing {
    /// The Mac's own smoothing; pages draw as native text does. The default.
    #[default]
    Auto,
    /// Thin grayscale strokes, no stem darkening.
    Antialiased,
    /// macOS font smoothing on, even where the Mac turned it off.
    Subpixel,
}

impl FontSmoothing {
    /// Every mode, in Swift's `CaseIterable` order.
    pub const ALL: [FontSmoothing; 3] =
        [FontSmoothing::Auto, FontSmoothing::Antialiased, FontSmoothing::Subpixel];

    /// The Swift raw value (`auto`, `antialiased`, `subpixel`).
    pub fn raw_value(self) -> &'static str {
        match self {
            FontSmoothing::Auto => "auto",
            FontSmoothing::Antialiased => "antialiased",
            FontSmoothing::Subpixel => "subpixel",
        }
    }

    /// `FontSmoothing(rawValue:)`: nil for any other string.
    pub fn from_raw(raw: &str) -> Option<FontSmoothing> {
        FontSmoothing::ALL.into_iter().find(|mode| mode.raw_value() == raw)
    }

    /// `cssValue`: the `-webkit-font-smoothing` value pages draw with; None for `auto`.
    pub fn css_value(self) -> Option<&'static str> {
        match self {
            FontSmoothing::Auto => None,
            FontSmoothing::Antialiased => Some("antialiased"),
            FontSmoothing::Subpixel => Some("subpixel-antialiased"),
        }
    }
}

/// `ProcessFontSmoothing(defaults:)`: off only when the default holds 0; a missing key (or a
/// value that is no number, given here as None) smooths.
pub fn smooths_stems(value: Option<i64>) -> bool {
    value.map(|v| v != 0).unwrap_or(true)
}

/// What `apply(_:to:)` does to the app's defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "value")]
pub enum DefaultsWrite {
    /// `removeObject(forKey:)` (auto: always, even when nothing is there).
    Remove,
    /// `set(_:forKey:)` with this number.
    Set(i64),
    /// The value in place already gives the mode: nothing is written.
    Keep,
}

/// The outcome of `ProcessFontSmoothing.apply(_:to:)` (and `applyLive`'s refresh choice).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyOutcome {
    /// The write to the app's domain.
    pub write: DefaultsWrite,
    /// The value `defaults.object(forKey:)` gives afterwards.
    pub value: Option<i64>,
    /// `smoothsStems` of the smoothing the defaults now give (`apply`'s return).
    pub smooths_stems: bool,
    /// The smoothing changed from what `saved` gave: `applyLive` redraws the chrome text
    /// (`ChromeTextRefresh.all()`).
    pub refreshes_chrome: bool,
}

/// `ProcessFontSmoothing.apply(mode, to:)` with `saved` the value the defaults give now and
/// `global` the value they give once the app's own value is removed.
pub fn apply(mode: FontSmoothing, saved: Option<i64>, global: Option<i64>) -> ApplyOutcome {
    let write = match mode {
        FontSmoothing::Auto => DefaultsWrite::Remove,
        FontSmoothing::Antialiased => {
            if saved != Some(ANTIALIASED_VALUE) {
                DefaultsWrite::Set(ANTIALIASED_VALUE)
            } else {
                DefaultsWrite::Keep
            }
        }
        FontSmoothing::Subpixel => {
            if saved.is_none() || saved == Some(0) {
                DefaultsWrite::Set(SUBPIXEL_VALUE)
            } else {
                DefaultsWrite::Keep
            }
        }
    };
    let value = match write {
        DefaultsWrite::Remove => global,
        DefaultsWrite::Set(v) => Some(v),
        DefaultsWrite::Keep => saved,
    };
    let after = smooths_stems(value);
    ApplyOutcome {
        write,
        value,
        smooths_stems: after,
        refreshes_chrome: after != smooths_stems(saved),
    }
}
