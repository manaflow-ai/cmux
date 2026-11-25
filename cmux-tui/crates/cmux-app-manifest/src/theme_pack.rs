//! `cmux.theme/1` rules a schema cannot express (plans/cmux-next/extensions/DESIGN.md
//! section 6, items 4 and 5): the contrast floor of `APP_THEME_CONTRACT`, the slots and
//! variants this cmux ships, and the motion scale's order.
//!
//! The contrast floor: every contract pair whose two tokens the pack sets holds its WCAG 2
//! minimum. A pair under it is adjusted: the foreground token moves in OKLCH lightness only as
//! far as all of its minimums need (`cmux_theme_tokens::fit_contrast`, the app theme's own
//! fit), and the validator warns with the color cmux draws. When no lightness reaches every
//! minimum, the pack is refused with the pair and the ratio. A pair with a token the pack
//! leaves out is not checked here: that token comes from the person's theme, whose derivation
//! already holds the contract.

use std::collections::BTreeMap;

use cmux_theme_tokens::{AppTheme, AppToken, Rgb, fit_contrast};
use serde_json::Value;

use crate::issue::{Issue, escape};

pub(crate) const INTERFACE: &str = "cmux.theme/1";

/// The pack's token key of an app token: `--cmux-app-text-secondary` -> `textSecondary`.
pub fn token_key(token: AppToken) -> String {
    let name = token.variable().trim_start_matches("--cmux-app-");
    let mut out = String::with_capacity(name.len());
    let mut upper = false;
    for c in name.chars() {
        if c == '-' {
            upper = true;
        } else if upper {
            out.push(c.to_ascii_uppercase());
            upper = false;
        } else {
            out.push(c);
        }
    }
    out
}

fn parse_hex(text: &str) -> Option<Rgb> {
    let digits = text.strip_prefix('#').filter(|d| d.len() == 6)?;
    u32::from_str_radix(digits, 16).ok().map(Rgb::hex)
}

/// One contract pair under its minimum in a pack's tokens.
#[derive(Debug, Clone, PartialEq)]
pub struct ContrastFinding {
    /// The foreground token key (`text`).
    pub token: String,
    /// The background token key (`sidebar`).
    pub on: String,
    /// The ratio as the pack wrote the two colors.
    pub ratio: f64,
    pub minimum: f64,
    /// The color cmux draws the token in instead (`#rrggbb`), or `None` when no lightness of
    /// the token meets all of its minimums: the pack is refused.
    pub adjusted: Option<String>,
}

/// A pack's tokens held to the contrast floor.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ThemeContrast {
    /// The tokens as cmux draws them: the pack's, with each adjusted one replaced.
    pub tokens: BTreeMap<String, String>,
    /// Every pair under its minimum, in contract order.
    pub findings: Vec<ContrastFinding>,
}

impl ThemeContrast {
    /// True when some pair could not be adjusted.
    pub fn refused(&self) -> bool {
        self.findings.iter().any(|f| f.adjusted.is_none())
    }
}

/// Holds `tokens` (the `options.tokens` object of a `cmux.theme/1` implementation) to the
/// contract. Tokens that are not opaque `#rrggbb` are left to the schema and skipped here.
pub fn theme_contrast(tokens: &Value) -> ThemeContrast {
    let mut colors: BTreeMap<String, Rgb> = BTreeMap::new();
    for token in AppToken::ALL {
        let key = token_key(token);
        if let Some(rgb) = tokens.get(&key).and_then(Value::as_str).and_then(parse_hex) {
            colors.insert(key, rgb);
        }
    }
    let contract = AppTheme::contract();
    let mut findings = Vec::new();
    // Each foreground once, in contract order, so a token adjusted earlier (the accent) is the
    // surface a later one (onAccent) is fitted against.
    let mut done: Vec<AppToken> = Vec::new();
    for (token, _, _) in &contract {
        if done.contains(token) {
            continue;
        }
        done.push(*token);
        let key = token_key(*token);
        let Some(color) = colors.get(&key).copied() else { continue };
        let pairs: Vec<(String, Rgb, f64)> = contract
            .iter()
            .filter(|(t, _, _)| t == token)
            .filter_map(|(_, on, minimum)| {
                let on = token_key(*on);
                colors.get(&on).map(|rgb| (on, *rgb, *minimum))
            })
            .collect();
        let failing: Vec<&(String, Rgb, f64)> =
            pairs.iter().filter(|(_, on, minimum)| color.contrast(*on) < *minimum).collect();
        if failing.is_empty() {
            continue;
        }
        let constraints: Vec<(Rgb, f64)> = pairs.iter().map(|(_, on, m)| (*on, *m)).collect();
        let fitted = fit_contrast(color, &constraints, None);
        let fits = constraints.iter().all(|(on, minimum)| fitted.contrast(*on) >= *minimum);
        let adjusted = fits.then(|| format!("#{:06x}", fitted.to_hex()));
        for (on, rgb, minimum) in failing {
            findings.push(ContrastFinding {
                token: key.clone(),
                on: on.clone(),
                ratio: color.contrast(*rgb),
                minimum: *minimum,
                adjusted: adjusted.clone(),
            });
        }
        if fits {
            colors.insert(key, fitted);
        }
    }
    let tokens = colors.into_iter().map(|(k, rgb)| (k, format!("#{:06x}", rgb.to_hex()))).collect();
    ThemeContrast { tokens, findings }
}

/// The slots this cmux ships and each one's variants, from the interface file.
fn known_slots() -> Vec<(String, Vec<String>)> {
    let Some((_, raw)) = crate::interfaces::interface_files().iter().find(|(n, _)| *n == INTERFACE)
    else {
        return Vec::new();
    };
    let file: Value = serde_json::from_str(raw).unwrap_or(Value::Null);
    file.get("slots")
        .and_then(Value::as_object)
        .map(|slots| {
            slots
                .iter()
                .map(|(id, variants)| {
                    let variants = variants.as_array().into_iter().flatten();
                    (id.clone(), variants.filter_map(Value::as_str).map(str::to_owned).collect())
                })
                .collect()
        })
        .unwrap_or_default()
}

const MOTION_ORDER: [&str; 4] = ["quick", "micro", "standard", "large"];

/// The `cmux.theme/1` rules on the implementation at `at` (a JSON pointer).
pub(crate) fn check(at: &str, imp: &Value, out: &mut Vec<Issue>) {
    if let Some(tokens) = imp.pointer("/options/tokens") {
        for f in theme_contrast(tokens).findings {
            let path = format!("{at}/options/tokens/{}", escape(&f.token));
            let pair = format!(
                "{} on {} is {:.2}:1, under the {}:1 minimum",
                f.token, f.on, f.ratio, f.minimum
            );
            match f.adjusted {
                Some(color) => out.push(Issue::warning(
                    path,
                    "theme.contrast.adjusted",
                    format!("{pair}; cmux draws {} as {color}", f.token),
                )),
                None => out.push(Issue::error(
                    path,
                    "theme.contrast",
                    format!("{pair}, and no lightness of {} meets all of its minimums", f.token),
                )),
            }
        }
    }
    if let Some(slots) = imp.pointer("/options/slots").and_then(Value::as_object) {
        let known = known_slots();
        for (slot, variant) in slots {
            let path = format!("{at}/options/slots/{}", escape(slot));
            let Some((_, variants)) = known.iter().find(|(id, _)| id == slot) else {
                out.push(Issue::warning(
                    path,
                    "theme.slot.unknown",
                    format!("{slot} is not a slot of this cmux version; it is ignored"),
                ));
                continue;
            };
            let variant = variant.as_str().unwrap_or_default();
            if !variants.iter().any(|v| v == variant) {
                out.push(Issue::warning(
                    path,
                    "theme.slot.variant",
                    format!(
                        "{slot} has no variant {variant} ({}); it draws its default",
                        variants.join(", ")
                    ),
                ));
            }
        }
    }
    if let Some(motion) = imp.pointer("/options/motion") {
        let steps: Vec<(&str, u64)> = MOTION_ORDER
            .iter()
            .filter_map(|step| motion.get(*step).and_then(Value::as_u64).map(|ms| (*step, ms)))
            .collect();
        for pair in steps.windows(2) {
            let ((shorter, a), (longer, b)) = (pair[0], pair[1]);
            if a > b {
                out.push(Issue::error(
                    format!("{at}/options/motion/{longer}"),
                    "theme.motion.order",
                    format!("{longer} ({b} ms) is shorter than {shorter} ({a} ms); the scale runs quick <= micro <= standard <= large"),
                ));
            }
        }
    }
}

#[cfg(test)]
#[path = "theme_pack_tests.rs"]
mod tests;
