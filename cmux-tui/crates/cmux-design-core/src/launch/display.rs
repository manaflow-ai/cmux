//! `LaunchDisplay` (Windows/LaunchDisplay.swift): which screen a dev launch opens on
//! (`CMUX_NEXT_LAUNCH_DISPLAY`). Its `frame` stays with the window placement.

use serde::{Deserialize, Serialize};

/// `LaunchDisplay`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LaunchDisplay {
    BuiltIn,
    Index(i64),
}

pub const ENVIRONMENT_KEY: &str = "CMUX_NEXT_LAUNCH_DISPLAY";

/// `CharacterSet.whitespaces`: tab and the space separators (Zs), not line breaks.
fn is_swift_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

impl LaunchDisplay {
    /// `parse(_:isDevBuild:)`: unset or empty is the built-in screen on a dev build.
    pub fn parse(value: Option<&str>, is_dev_build: bool) -> Option<Self> {
        let raw = value.unwrap_or("").trim_matches(is_swift_whitespace).to_lowercase();
        match raw.as_str() {
            "" => is_dev_build.then_some(Self::BuiltIn),
            "builtin" | "built-in" | "internal" => Some(Self::BuiltIn),
            "main" => Some(Self::Index(0)),
            other => other.parse::<i64>().ok().filter(|i| *i >= 0).map(Self::Index),
        }
    }

    /// `screenIndex(builtIn:)`: the first built-in screen, or the index clamped to the screens.
    pub fn screen_index(&self, built_in: &[bool]) -> Option<usize> {
        if built_in.is_empty() {
            return None;
        }
        match *self {
            Self::BuiltIn => built_in.iter().position(|b| *b),
            Self::Index(i) => Some(i.clamp(0, built_in.len() as i64 - 1) as usize),
        }
    }
}
