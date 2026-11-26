//! Swift `ThemeSpec(_:)` (CmuxNextDesignTokens): `Name`, or a `light:A,dark:B`
//! pair in either order, a missing side using the other.

use crate::trim_spaces;

/// A parsed theme spec: the theme for each system appearance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThemeSpec {
    pub light: String,
    pub dark: String,
}

impl ThemeSpec {
    /// Parses `raw`. None for empty text, text over 200 characters, a part
    /// with an unknown prefix, or characters that could start another config
    /// line (control characters, `#`, `=`, `"`).
    pub fn parse(raw: &str) -> Option<ThemeSpec> {
        let trimmed = cmux_theme_tokens::theme_override_value(raw)?;
        let (mut light, mut dark, mut plain) = (None, None, None);
        for part in trimmed.split(',') {
            let text = trim_spaces(part);
            if text.is_empty() {
                return None;
            }
            if let Some(name) = prefixed(text, "light:") {
                light = Some(name);
            } else if let Some(name) = prefixed(text, "dark:") {
                dark = Some(name);
            } else if plain.is_none() && !text.contains(':') {
                plain = Some(text.to_owned());
            } else {
                return None;
            }
        }
        let resolved_light = light.clone().or_else(|| dark.clone()).or_else(|| plain.clone())?;
        let resolved_dark = dark.or(light).or(plain)?;
        Some(ThemeSpec { light: resolved_light, dark: resolved_dark })
    }
}

fn prefixed(text: &str, prefix: &str) -> Option<String> {
    let head = text.get(..prefix.len())?;
    if !head.eq_ignore_ascii_case(prefix) {
        return None;
    }
    let name = trim_spaces(&text[prefix.len()..]);
    (!name.is_empty()).then(|| name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(light: &str, dark: &str) -> Option<ThemeSpec> {
        Some(ThemeSpec { light: light.into(), dark: dark.into() })
    }

    #[test]
    fn a_plain_name_is_both_sides() {
        assert_eq!(ThemeSpec::parse("  Nord "), spec("Nord", "Nord"));
    }

    #[test]
    fn a_pair_in_either_order_and_one_side_alone() {
        assert_eq!(ThemeSpec::parse("light:A, dark:B"), spec("A", "B"));
        assert_eq!(ThemeSpec::parse("Dark: B ,LIGHT:A"), spec("A", "B"));
        assert_eq!(ThemeSpec::parse("dark:B"), spec("B", "B"));
        assert_eq!(ThemeSpec::parse("light:A"), spec("A", "A"));
        // A pair side wins over a plain part.
        assert_eq!(ThemeSpec::parse("Plain,dark:B"), spec("B", "B"));
    }

    #[test]
    fn refusals() {
        for raw in [
            "",
            "   ",
            "a,,b",
            "a,b",
            "x:y",
            "light:",
            "a#b",
            "a=b",
            "a\"b",
            "a\u{7}b",
            "a\u{200B}b",
        ] {
            assert_eq!(ThemeSpec::parse(raw), None, "{raw:?}");
        }
        assert_eq!(ThemeSpec::parse(&"x".repeat(201)), None);
        assert!(ThemeSpec::parse(&"x".repeat(200)).is_some());
    }
}
