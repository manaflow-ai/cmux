//! The design check `ext dev` runs on a view's first scene: the foot-guns that make an
//! extension look wrong next to cmux's own surfaces, each with the fix a person or a small
//! model can apply as written (RFD: cmuxterm-hq docs/rfd, "bad-design-proof UI primitives").
//!
//! The checks read the scene, not the source, so they hold for any way the view was built:
//! - `type-size`: a point size that is not on the type scale (`TYPE_ROLES`).
//! - `type-style`: an Apple text style name the web and macOS renderers draw at different sizes.
//! - `type-roles`: more than `MAX_TYPE_ROLES` text styles in one view.
//! - `spacing`: a gap or padding that is not on the spacing scale (`SPACING`).
//! - `color`: a raw hex color, or a color name no renderer knows (it draws nothing).
//! - `accents`: more than `MAX_ACCENTS` accent colors in one view.
//! - `contrast`: a hex text color below the WCAG minimum on its background, or on cmux's
//!   light or dark surface when it sits on the theme's.
//! - `line-limit`: a widget's Text with no line limit, which overflows a small tile.
//!
//! Findings warn; they never fail the load. `ext dev --once --json` lists them as `design`.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::scene::{self, Node};

/// The type scale's roles: name, the SDK helper that draws it (`widget.ts`, `TYPE_ROLES`),
/// point size, weight. Apple's widget text styles, and the sizes the web scene renders.
pub(super) const TYPE_ROLES: [(&str, &str, f64, &str); 7] = [
    ("numeral", "BigNumber", 34.0, "semibold"),
    ("heading", "Heading", 20.0, "semibold"),
    ("title", "Headline", 15.0, "semibold"),
    ("label", "Label", 13.0, "semibold"),
    ("body", "Body", 13.0, "regular"),
    ("caption", "Caption", 12.0, "regular"),
    ("footnote", "Footnote", 11.0, "regular"),
];

/// The spacing scale, in points (the SDK's `SPACE`): a 4 pt grid with 2 and 6 for tight rows.
pub(super) const SPACING: [f64; 11] = [0.0, 2.0, 4.0, 6.0, 8.0, 12.0, 16.0, 20.0, 24.0, 32.0, 48.0];

/// Text styles one view may use: a value, a heading, body and a caption.
pub(super) const MAX_TYPE_ROLES: usize = 4;

/// Accent colors one view may use (the theme accent counts as one).
pub(super) const MAX_ACCENTS: usize = 2;

/// Findings printed at most; past it one line says how many more.
const MAX_FINDINGS: usize = 20;

/// The scene's semantic colors (`webviews/src/apps/scene/sceneStyle.ts`, `AppJSON+SceneColor.swift`).
const COLOR_TOKENS: [&str; 12] = [
    "primary",
    "accent",
    "secondary",
    "tertiary",
    "separator",
    "success",
    "warning",
    "danger",
    "hover",
    "selected",
    "badge",
    "clear",
];

/// Tokens that are accents: the rest are the text's own shades and the surface's.
const ACCENT_TOKENS: [&str; 4] = ["accent", "success", "warning", "danger"];

/// Apple text style names the two renderers draw at different sizes (web px, macOS pt).
const DRIFTING_STYLES: [(&str, &str, &str); 4] = [
    ("largeTitle", "15 px", "26 pt"),
    ("title", "15 px", "22 pt"),
    ("title2", "20 px", "17 pt"),
    ("title3", "20 px", "15 pt"),
];

/// Props that hold a color.
const COLOR_PROPS: [&str; 7] =
    ["color", "background", "fill", "stroke", "borderColor", "hoverBackground", "tint"];

/// cmux's light and dark surfaces: a hex text color on the theme's background is read on both.
const SURFACES: [(&str, [f64; 3]); 2] = [("light", [1.0, 1.0, 1.0]), ("dark", [0.11, 0.11, 0.118])];

/// One design finding: which check, the node it is about, and what to do.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Finding {
    pub check: &'static str,
    /// The node's outline line (`scene.rs`), so it can be found in `ext shot`'s outline.
    pub node: Option<String>,
    pub message: String,
    pub fix: String,
    /// How many nodes had this same finding.
    pub count: usize,
}

impl Finding {
    pub(super) fn to_json(&self) -> Value {
        json!({ "check": self.check, "node": self.node, "message": self.message,
                "fix": self.fix, "count": self.count })
    }

    /// `check: message (N nodes): fix`, then the node.
    pub(super) fn text(&self) -> String {
        let count = if self.count > 1 { format!(" ({} nodes)", self.count) } else { String::new() };
        let node = self.node.as_deref().map(|n| format!("\n    at {n}")).unwrap_or_default();
        format!("{}: {}{count}\n    fix: {}{node}", self.check, self.message, self.fix)
    }
}

/// What the scene is drawn as: a widget tile checks line limits too.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Surface {
    Widget,
    Other,
}

impl Surface {
    /// The surface the interface `ext dev` probed draws on.
    pub(super) fn of(interface: &str) -> Self {
        if interface == "cmux.widget/1" { Self::Widget } else { Self::Other }
    }
}

/// The design findings for the scene `batches` build, most important first.
pub(super) fn check(batches: &[&Value], surface: Surface) -> Vec<Finding> {
    let (root, nodes) = scene::apply(batches);
    let Some(root) = root else { return Vec::new() };
    let mut findings = Findings::default();
    let mut styles: BTreeSet<String> = BTreeSet::new();
    let mut accents: BTreeSet<String> = BTreeSet::new();
    let mut seen = BTreeSet::new();
    // Depth first with what each node sits on, as the outline walks it: cmux's two surfaces
    // until a hex background covers them (a translucent one is blended over what is behind).
    let surfaces: Behind =
        SURFACES.iter().map(|(name, rgb)| (format!("cmux's {name} surface"), *rgb)).collect();
    let mut stack: Vec<(String, Behind)> = vec![(root, surfaces)];
    while let Some((id, behind)) = stack.pop() {
        let Some(node) = nodes.get(&id) else { continue };
        if !seen.insert(id) {
            continue;
        }
        let behind = match node.props.get("background").and_then(Value::as_str).and_then(hex) {
            Some((rgb, alpha)) if alpha >= 1.0 => vec![("its background".to_string(), rgb)],
            Some((rgb, alpha)) => behind
                .iter()
                .map(|(name, under)| {
                    let mixed = std::array::from_fn(|i| rgb[i] * alpha + under[i] * (1.0 - alpha));
                    (
                        format!("its tinted background over {}", name.trim_start_matches("its ")),
                        mixed,
                    )
                })
                .collect(),
            None => behind,
        };
        if node.kind == "Text" {
            text(node, &behind, surface, &mut findings, &mut styles);
        }
        spacing(node, &mut findings);
        colors(node, &mut findings, &mut accents);
        stack.extend(node.children.iter().rev().map(|child| (child.clone(), behind.clone())));
    }
    if styles.len() > MAX_TYPE_ROLES {
        findings.add(
            "type-roles",
            None,
            format!(
                "{} text styles in one view ({}); a glanceable view reads with {MAX_TYPE_ROLES} at most",
                styles.len(),
                styles.iter().cloned().collect::<Vec<_>>().join(", ")
            ),
            "keep one value (BigNumber), one heading (Headline), Body and Caption; drop the rest".into(),
        );
    }
    if accents.len() > MAX_ACCENTS {
        findings.add(
            "accents",
            None,
            format!(
                "{} accent colors in one view ({}); more than {MAX_ACCENTS} reads as noise",
                accents.len(),
                accents.iter().cloned().collect::<Vec<_>>().join(", ")
            ),
            "use \"accent\" for the one thing to look at and \"secondary\" for the rest; keep success/warning/danger for state".into(),
        );
    }
    findings.done()
}

/// The text lines `ext dev` prints for `findings`, capped.
pub(super) fn lines(findings: &[Finding]) -> Vec<String> {
    let mut lines: Vec<String> = findings.iter().take(MAX_FINDINGS).map(Finding::text).collect();
    if findings.len() > MAX_FINDINGS {
        lines.push(format!("… {} more (--json lists them all)", findings.len() - MAX_FINDINGS));
    }
    lines
}

/// The scenes a recorded file holds, by name: one JSON array of ops (named for the file), or
/// an object of them (a gallery fixture), or of `{ops}` (a store preview's states).
pub(super) fn scenes_in(file: &str, value: &Value) -> Vec<(String, Value)> {
    match value {
        Value::Array(_) => vec![(file.to_string(), value.clone())],
        Value::Object(map) => map
            .iter()
            .filter_map(|(name, scene)| {
                let ops = if scene.is_array() { scene } else { scene.get("ops")? };
                ops.is_array().then(|| (format!("{file}:{name}"), ops.clone()))
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// `ext design FILE... [--widget] [--json]`: each recorded scene's findings. Exit 0 when none
/// warns, 1 when one does, 4 when a file does not read as scenes.
pub(super) fn run(files: &[std::path::PathBuf], surface: Surface, json_out: bool) -> i32 {
    let mut reports = Vec::new();
    for path in files {
        let name = path.display().to_string();
        let value = std::fs::read_to_string(path)
            .map_err(|e| e.to_string())
            .and_then(|text| serde_json::from_str::<Value>(&text).map_err(|e| e.to_string()));
        let scenes = match value {
            Ok(value) => scenes_in(&name, &value),
            Err(error) => {
                eprintln!("cmux: {name}: {error}");
                return super::exit::MANIFEST_INVALID;
            }
        };
        if scenes.is_empty() {
            eprintln!("cmux: {name}: no scene ops (a JSON array of ops, or an object of them)");
            return super::exit::MANIFEST_INVALID;
        }
        for (scene, ops) in scenes {
            reports.push((scene, check(&[&ops], surface)));
        }
    }
    let warned = reports.iter().filter(|(_, findings)| !findings.is_empty()).count();
    if json_out {
        let scenes: Vec<Value> = reports
            .iter()
            .map(|(scene, findings)| {
                json!({ "scene": scene, "design": findings.iter().map(Finding::to_json).collect::<Vec<_>>() })
            })
            .collect();
        println!("{}", json!({ "ok": warned == 0, "scenes": scenes }));
    } else {
        for (scene, findings) in &reports {
            if findings.is_empty() {
                println!("{scene}: no design warnings");
                continue;
            }
            println!(
                "{scene}: {} design warning{}",
                findings.len(),
                if findings.len() == 1 { "" } else { "s" }
            );
            for text in lines(findings) {
                println!("  {}", text.replace('\n', "\n  "));
            }
        }
    }
    if warned == 0 { super::exit::OK } else { super::exit::LOAD_FAILED }
}

/// Findings, merged by check and message so one repeated mistake is one line.
#[derive(Default)]
struct Findings {
    order: Vec<(&'static str, String)>,
    by_key: BTreeMap<(&'static str, String), Finding>,
}

impl Findings {
    fn add(&mut self, check: &'static str, node: Option<&Node>, message: String, fix: String) {
        let key = (check, message.clone());
        if let Some(finding) = self.by_key.get_mut(&key) {
            finding.count += 1;
            return;
        }
        self.order.push(key.clone());
        let node = node.map(scene::line);
        self.by_key.insert(key, Finding { check, node, message, fix, count: 1 });
    }

    fn done(mut self) -> Vec<Finding> {
        self.order.iter().filter_map(|key| self.by_key.remove(key)).collect()
    }
}

fn number(value: Option<&Value>) -> Option<f64> {
    value.and_then(Value::as_f64).filter(|n| n.is_finite())
}

/// The type role a point size and weight are, if any.
fn role_of(size: f64, weight: &str) -> Option<&'static str> {
    let weight = if weight.is_empty() { "regular" } else { weight };
    TYPE_ROLES.iter().find(|(_, _, s, w)| *s == size && *w == weight).map(|(name, _, _, _)| *name)
}

/// The nearest roles to an off-scale size, as the fix names them.
fn nearest_roles(size: f64) -> String {
    let mut roles: Vec<_> = TYPE_ROLES.iter().collect();
    roles.sort_by(|a, b| (a.2 - size).abs().total_cmp(&(b.2 - size).abs()));
    roles
        .iter()
        .take(2)
        .map(|(_, helper, s, _)| format!("{helper}(...) ({s} pt)"))
        .collect::<Vec<_>>()
        .join(" or ")
}

/// What a node's text sits on: each candidate's name and color.
type Behind = Vec<(String, [f64; 3])>;

fn text(
    node: &Node,
    behind: &Behind,
    surface: Surface,
    findings: &mut Findings,
    styles: &mut BTreeSet<String>,
) {
    let weight = node.props.get("weight").and_then(Value::as_str).unwrap_or("");
    let font = node.props.get("font");
    let mut size = 13.0;
    match font {
        Some(Value::Number(_)) => {
            let points = number(font).unwrap_or(13.0);
            size = points;
            if !TYPE_ROLES.iter().any(|(_, _, s, _)| *s == points) {
                findings.add(
                    "type-size",
                    Some(node),
                    format!("font size {points} is not on the type scale"),
                    format!("use {}", nearest_roles(points)),
                );
            }
            styles.insert(match role_of(points, weight) {
                Some(role) => role.to_string(),
                None => format!("{points} {}", if weight.is_empty() { "regular" } else { weight }),
            });
        }
        Some(Value::String(name)) => {
            if let Some((_, web, mac)) = DRIFTING_STYLES.iter().find(|(n, _, _)| n == name) {
                findings.add(
                    "type-style",
                    Some(node),
                    format!("font \"{name}\" draws {web} on the web and {mac} on macOS"),
                    "use a type role: BigNumber(...) (34 pt), Heading(...) (20 pt) or Headline(...) (15 pt)".into(),
                );
            }
            styles.insert(format!(
                "{name}{}",
                if weight.is_empty() { String::new() } else { format!(" {weight}") }
            ));
        }
        _ => {
            styles.insert(format!(
                "body{}",
                if weight.is_empty() { String::new() } else { format!(" {weight}") }
            ));
        }
    }
    if let Some((color, _)) = node.props.get("color").and_then(Value::as_str).and_then(hex) {
        let bold = matches!(weight, "semibold" | "bold" | "heavy" | "black");
        let large = size >= 18.0 || (bold && size >= 14.0);
        let floor = if large { 3.0 } else { 4.5 };
        for (what, bg) in behind {
            let ratio = contrast(color, *bg);
            if ratio < floor {
                findings.add(
                    "contrast",
                    Some(node),
                    format!("text contrast {ratio:.1}:1 on {what} (needs {floor}:1)"),
                    "use \"primary\" or \"secondary\": they keep contrast in light and dark".into(),
                );
            }
        }
    }
    if surface == Surface::Widget && number(node.props.get("lineLimit")).is_none() {
        findings.add(
            "line-limit",
            Some(node),
            "text with no line limit overflows a small tile when it is long".into(),
            "add .lineLimit(1) (or 2 for a title), or use the type helpers (Headline, Body, Caption, ...), which set it".into(),
        );
    }
}

fn spacing(node: &Node, findings: &mut Findings) {
    let mut values: Vec<(&str, f64)> = Vec::new();
    for key in ["spacing", "padding", "paddingHorizontal", "paddingVertical"] {
        match node.props.get(key) {
            Some(Value::Number(_)) => values.extend(number(node.props.get(key)).map(|n| (key, n))),
            Some(Value::Object(edges)) => {
                values.extend(edges.values().filter_map(|v| number(Some(v))).map(|n| (key, n)));
            }
            _ => {}
        }
    }
    for (key, value) in values {
        if SPACING.contains(&value) {
            continue;
        }
        let near = SPACING
            .iter()
            .min_by(|a, b| (*a - value).abs().total_cmp(&(*b - value).abs()))
            .copied()
            .unwrap_or(0.0);
        findings.add(
            "spacing",
            Some(node),
            format!("{key} {value} is not on the spacing scale"),
            format!("use {near} (SPACE: 0 2 4 6 8 12 16 20 24 32 48)"),
        );
    }
}

fn colors(node: &Node, findings: &mut Findings, accents: &mut BTreeSet<String>) {
    for key in COLOR_PROPS {
        let Some(value) = node.props.get(key).and_then(Value::as_str) else { continue };
        if COLOR_TOKENS.contains(&value) {
            if ACCENT_TOKENS.contains(&value) && key != "background" {
                accents.insert(value.to_string());
            }
            continue;
        }
        if hex(value).is_some() {
            if key != "background" {
                accents.insert(value.to_ascii_lowercase());
            }
            findings.add(
                "color",
                Some(node),
                format!("{key} {value} is a raw color: it does not follow the theme or dark mode"),
                "use a role: primary, secondary, tertiary, accent, success, warning, danger".into(),
            );
        } else {
            findings.add(
                "color",
                Some(node),
                format!("{key} \"{value}\" is not a color cmux knows, so it draws nothing"),
                "use a role: primary, secondary, tertiary, accent, success, warning, danger".into(),
            );
        }
    }
}

/// `#rrggbb` or `#rrggbbaa` as sRGB in 0..1, and its alpha.
fn hex(text: &str) -> Option<([f64; 3], f64)> {
    let digits = text.strip_prefix('#')?;
    if !(digits.len() == 6 || digits.len() == 8) || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let channel =
        |i: usize| u8::from_str_radix(&digits[i..i + 2], 16).ok().map(|v| f64::from(v) / 255.0);
    let alpha = if digits.len() == 8 { channel(6)? } else { 1.0 };
    Some(([channel(0)?, channel(2)?, channel(4)?], alpha))
}

/// WCAG 2 contrast ratio of two sRGB colors.
fn contrast(a: [f64; 3], b: [f64; 3]) -> f64 {
    let luminance = |c: [f64; 3]| {
        let lin = |v: f64| if v <= 0.040_45 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) };
        0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])
    };
    let (la, lb) = (luminance(a), luminance(b));
    let (hi, lo) = if la > lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

#[cfg(test)]
#[path = "design_tests.rs"]
mod tests;
