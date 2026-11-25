//! `layout.*` pane chrome keys: Swift `PaneChromeConfigParser`. Ranges from schemas/settings/source/appearance.json.

use serde_json::{Map, Value, json};

use super::{Diag, OpError, diags_json, root_of};

const SEPARATIONS: [&str; 4] = ["none", "dividers", "borders", "cards"];
const BORDERS: [&str; 2] = ["subtle", "none"];

pub(super) fn parse_op(request: &Value) -> Result<Value, OpError> {
    let (overrides, diags) = parse(root_of(request)?);
    Ok(json!({"overrides": overrides, "diagnostics": diags_json(&diags)}))
}

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA` (`#` optional, spaces around trimmed): Swift `ThemeRGB(cssHex:)`.
/// The alpha is 0...1.
pub(crate) fn css_hex(text: &str) -> Option<(u8, u8, u8, f64)> {
    let trimmed = text.trim_matches(|c: char| c == ' ' || c == '\t');
    let digits = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if ![3, 6, 8].contains(&digits.chars().count())
        || !digits.chars().all(|c| c.is_ascii_hexdigit())
    {
        return None;
    }
    let mut value = u64::from_str_radix(digits, 16).ok()?;
    if digits.len() == 3 {
        let (r, g, b) = ((value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF);
        value = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17);
    }
    let mut alpha = 1.0;
    if digits.len() == 8 {
        alpha = (value & 0xFF) as f64 / 255.0;
        value >>= 8;
    }
    Some(((value >> 16) as u8, (value >> 8) as u8, value as u8, alpha))
}

/// `#RRGGBB` or `#RRGGBBAA` (the `#` optional, no spaces): the pane border color.
fn border_color(text: &str) -> Option<Value> {
    let digits = text.strip_prefix('#').unwrap_or(text);
    if (digits.len() != 6 && digits.len() != 8) || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let (r, g, b, alpha) = css_hex(&format!("#{digits}"))?;
    Some(json!({"red": f64::from(r) / 255.0, "green": f64::from(g) / 255.0,
        "blue": f64::from(b) / 255.0, "alpha": alpha}))
}

fn points(
    value: Option<&Value>,
    path: &str,
    range: (f64, f64),
    diags: &mut Vec<Diag>,
) -> Option<f64> {
    let value = value?;
    let Some(number) = value.as_f64().filter(|n| n.is_finite()) else {
        diags.push(Diag::invalid(path, "expected a number of points"));
        return None;
    };
    if number < range.0 || number > range.1 {
        diags.push(Diag::invalid(
            path,
            format!("clamped to {}...{} points", range.0 as i64, range.1 as i64),
        ));
    }
    Some(number.max(range.0).min(range.1))
}

fn choice(
    value: Option<&Value>,
    path: &str,
    allowed: &[&str],
    joiner: &str,
    quote_all: bool,
    diags: &mut Vec<Diag>,
) -> Option<String> {
    let value = value?;
    if let Some(text) = value.as_str().filter(|text| allowed.contains(text)) {
        return Some(text.to_string());
    }
    let list = allowed.iter().map(|a| format!("\"{a}\"")).collect::<Vec<_>>().join(joiner);
    let message =
        if quote_all { format!("expected {list}") } else { format!("expected one of {list}") };
    diags.push(Diag::invalid(path, message));
    None
}

/// The pane chrome overrides the file sets, each member present only when set and valid.
pub(super) fn parse(root: &Value) -> (Value, Vec<Diag>) {
    let mut out = Map::new();
    let mut diags = Vec::new();
    let Some(layout) = root.get("layout") else { return (Value::Object(out), diags) };
    let Some(members) = layout.as_object() else {
        diags.push(Diag::invalid("layout", "expected an object"));
        return (Value::Object(out), diags);
    };
    let mut put = |name: &str, value: Option<Value>| {
        if let Some(value) = value {
            out.insert(name.into(), value);
        }
    };
    put(
        "padding",
        points(members.get("panePadding"), "layout.panePadding", (0.0, 16.0), &mut diags)
            .map(|v| json!(v)),
    );
    put(
        "cornerRadius",
        points(members.get("paneCornerRadius"), "layout.paneCornerRadius", (0.0, 20.0), &mut diags)
            .map(|v| json!(v)),
    );
    put(
        "cornerPadding",
        points(members.get("cornerPadding"), "layout.cornerPadding", (0.0, 12.0), &mut diags)
            .map(|v| json!(v)),
    );
    put(
        "border",
        choice(members.get("paneBorder"), "layout.paneBorder", &BORDERS, " or ", true, &mut diags)
            .map(|v| json!(v)),
    );
    put(
        "separation",
        choice(
            members.get("paneSeparation"),
            "layout.paneSeparation",
            &SEPARATIONS,
            ", ",
            false,
            &mut diags,
        )
        .map(|v| json!(v)),
    );
    put(
        "borderWidth",
        points(members.get("paneBorderWidth"), "layout.paneBorderWidth", (0.5, 4.0), &mut diags)
            .map(|v| json!(v)),
    );
    if let Some(value) = members.get("paneBorderColor") {
        match value.as_str().and_then(border_color) {
            Some(color) => put("borderColor", Some(color)),
            None => diags.push(Diag::invalid(
                "layout.paneBorderColor",
                "expected \"#RRGGBB\" or \"#RRGGBBAA\"",
            )),
        }
    }
    (Value::Object(out), diags)
}
