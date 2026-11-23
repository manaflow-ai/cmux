//! The design check `ext dev` runs on a view's first scene: the foot-guns that make an
//! extension look wrong next to cmux's own surfaces, each with the fix a person or a small
//! model can apply as written (RFD: cmuxterm-hq docs/rfd, "bad-design-proof UI primitives").
//!
//! The checks read the scene, not the source, so they hold for any way the view was built:
//! - `type-size`: a point size that is not one of the system's type roles.
//! - `type-style`: a `font` name that is no type role: an Apple text style name off the roles
//!   (`largeTitle`), named as the role at its size, or a name no renderer knows (it draws as body).
//!   Both renderers draw a name from one table (`scene_type.rs`), so this is a rename hint.
//! - `type-roles`: (widgets) more text styles in one tile than the system allows (4 in cmux's).
//!   A pane or a specimen page may show more; a glanceable tile reads with few.
//! - `spacing`: a gap or padding that is not on the system's spacing scale.
//! - `color`: a raw hex color, or a color name no renderer knows (it draws nothing).
//! - `accents`: more accent colors in one view than the system allows (2 in cmux's).
//! - `contrast`: a hex text color below the WCAG minimum on its background, or on cmux's
//!   light or dark surface when it sits on the theme's.
//! - `line-limit`: (widgets) a Text with no line limit, which overflows a small tile.
//! - `component`: a finished component's `variant` or `state` it does not draw, or a `Chart`
//!   with no values or more than it draws (`design_components.rs`).
//!
//! The system is cmux's, or the folder's own `cmux-design.json` over it (`design_system.rs`).
//! Findings warn; they never fail the load. `ext dev --once --json` lists them as `design`.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::design_components;
use super::design_system::System;
use super::scene::{self, Node};
use super::scene_type;

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

/// The design findings for the scene `batches` build against cmux's system.
#[cfg(test)]
pub(super) fn check(batches: &[&Value], surface: Surface) -> Vec<Finding> {
    check_in(batches, surface, &System::cmux())
}

/// The design findings for the scene `batches` build against `system`: node findings in
/// outline order, then the per-view counts (`type-roles`, `accents`).
pub(super) fn check_in(batches: &[&Value], surface: Surface, system: &System) -> Vec<Finding> {
    let (root, nodes) = scene::apply(batches);
    let Some(root) = root else { return Vec::new() };
    let mut findings = Findings::default();
    let mut styles: BTreeSet<String> = BTreeSet::new();
    let mut accents: BTreeSet<String> = BTreeSet::new();
    let mut seen = BTreeSet::new();
    // Depth first with what each node sits on, as the outline walks it: cmux's two surfaces
    // until a hex background covers them (a translucent one is blended over what is behind).
    let surfaces: Behind =
        SURFACES.iter().map(|(name, rgb)| (format!("cmux's {name} background"), *rgb)).collect();
    let mut stack: Vec<(String, Behind)> = vec![(root, surfaces)];
    while let Some((id, behind)) = stack.pop() {
        let Some(node) = nodes.get(&id) else { continue };
        if !seen.insert(id) {
            continue;
        }
        let background = node.props.get("background").and_then(Value::as_str);
        let behind = match background.and_then(hex) {
            Some((rgb, alpha)) if alpha >= 1.0 => vec![("its background".to_string(), rgb)],
            // A theme color behind the text (an accent pill, a badge): its value is the theme's,
            // so a hex text color on it cannot be measured here; the `color` check still names it.
            None if background.is_some_and(|b| b != "clear") => Vec::new(),
            Some((rgb, alpha)) => behind
                .iter()
                .map(|(name, under)| {
                    let mixed = over(rgb, alpha, *under);
                    let under = name.strip_prefix("its tinted background over ").unwrap_or(name);
                    (
                        format!("its tinted background over {}", under.trim_start_matches("its ")),
                        mixed,
                    )
                })
                .collect(),
            None => behind,
        };
        if node.kind == "Text" {
            text(node, &behind, surface, system, &mut findings, &mut styles);
        }
        if node.kind == "Stat" {
            // A Stat draws its value in the numeral role and its label as a caption.
            styles.extend(["numeral".to_string(), "caption".to_string()]);
        }
        spacing(node, system, &mut findings);
        colors(node, &mut findings, &mut accents);
        for (message, fix) in design_components::problems(node) {
            findings.add("component", Some(node), message, fix);
        }
        stack.extend(node.children.iter().rev().map(|child| (child.clone(), behind.clone())));
    }
    let max_roles = system.max_roles;
    if surface == Surface::Widget && styles.len() > max_roles {
        findings.add(
            "type-roles",
            None,
            format!(
                "{} text styles in one view ({}); a glanceable view reads with {max_roles} at most",
                styles.len(),
                styles.iter().cloned().collect::<Vec<_>>().join(", ")
            ),
            "keep one value (BigNumber), one heading (WidgetTitle or Headline), Body and Caption; drop the rest".into(),
        );
    }
    let max_accents = system.max_accents;
    if accents.len() > max_accents {
        findings.add(
            "accents",
            None,
            format!(
                "{} accent colors in one view ({}); more than {max_accents} reads as noise",
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
pub(super) fn run(
    files: &[std::path::PathBuf],
    surface: Surface,
    system: &System,
    json_out: bool,
) -> i32 {
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
            if scene::apply(&[&ops]).0.is_none() {
                eprintln!("cmux: {scene}: the ops name no root, so there is no scene to check");
                return super::exit::MANIFEST_INVALID;
            }
            reports.push((scene, check_in(&[&ops], surface, system)));
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

/// Registry review's design check of one extension folder (RFD 0009 slice 6): its recorded
/// scenes, against its own system. Any warning refuses the listing; `ext dev` never fails a
/// load on one (an author mid-edit is never blocked).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Listing {
    /// Each recorded scene's name and its findings, in the file's order.
    pub scenes: Vec<(String, Vec<Finding>)>,
    /// Why the folder cannot be checked (no recorded scenes, a file that does not ship), or
    /// `None` when its scenes were.
    pub missing: Option<String>,
    /// What the check used that the author may not expect: a `cmux-design.json` the package
    /// does not ship, so the scenes were checked against cmux's system, as review will.
    pub note: Option<String>,
}

impl Listing {
    /// Clean: every recorded scene was checked and none warns.
    pub(super) fn ok(&self) -> bool {
        self.missing.is_none() && self.scenes.iter().all(|(_, findings)| findings.is_empty())
    }

    /// The warnings, as one count.
    pub(super) fn warnings(&self) -> usize {
        self.scenes.iter().map(|(_, findings)| findings.len()).sum()
    }

    /// One line for `ext publish`'s check list: what was checked, or the refusal and its fix.
    pub(super) fn summary(&self) -> String {
        if let Some(missing) = &self.missing {
            return missing.clone();
        }
        let count = self.scenes.len();
        let scenes = format!("{count} recorded scene{}", if count == 1 { "" } else { "s" });
        let note = self.note.as_ref().map(|note| format!(" ({note})")).unwrap_or_default();
        if self.ok() {
            return format!("{scenes} ({RECORDED}), no design warning{note}");
        }
        let warned = self.scenes.iter().filter(|(_, f)| !f.is_empty()).count();
        let total = self.warnings();
        format!(
            "{total} design warning{} in {warned} of {scenes}; registry review refuses a listing with any. Fix each, then cmux ext shot --record again{note}",
            if total == 1 { "" } else { "s" }
        )
    }

    /// The refusal in full: each warned scene and its findings with their fixes.
    pub(super) fn details(&self) -> Vec<String> {
        let mut out = Vec::new();
        for (scene, findings) in &self.scenes {
            if findings.is_empty() {
                continue;
            }
            out.push(format!("{scene}:"));
            out.extend(
                lines(findings).into_iter().map(|text| format!("  {}", text.replace('\n', "\n  "))),
            );
        }
        out
    }

    pub(super) fn to_json(&self) -> Value {
        json!({
            "ok": self.ok(),
            "missing": self.missing,
            "note": self.note,
            "warnings": self.warnings(),
            "scenes": self.scenes.iter().map(|(scene, findings)| json!({
                "scene": scene,
                "design": findings.iter().map(Finding::to_json).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        })
    }
}

/// The recorded scenes' file, in an extension folder (`ext shot --record` writes it).
pub(super) const RECORDED: &str = super::shot::RECORDED;

/// Whether the manifest's `files` ship `rel` in the package (no `files`: every non-source file
/// does, as `dev::package_files` reads it).
fn shipped(manifest: &Value, rel: &str) -> bool {
    let Some(files) = manifest.get("files").and_then(Value::as_array) else { return true };
    files.iter().filter_map(Value::as_str).any(|entry| {
        let entry = entry.trim_start_matches("./").trim_end_matches('/');
        entry == rel || rel.starts_with(&format!("{entry}/"))
    })
}

/// The surface a recorded scene draws on: its name's interface (`cmux.widget/1 small`), else
/// the manifest's drawn one.
fn surface_of(name: &str, drawn: Option<&str>) -> Surface {
    match name.split_whitespace().next() {
        Some(interface) if interface.starts_with("cmux.") && interface.contains('/') => {
            Surface::of(interface)
        }
        _ => drawn.map_or(Surface::Other, Surface::of),
    }
}

/// Registry review's design check of the folder `dir` with `manifest`: every scene in
/// `preview/scenes.json`, against the folder's `cmux-design.json` over cmux's system (a file
/// that does not read is a `system` warning on each scene). Only what the package ships is
/// used, so the check here and on the unpacked release agree: an unshipped `cmux-design.json`
/// is left out (and the listing says so). An extension that draws no view (a command, an
/// opener) has nothing to check and passes.
pub(super) fn listing(dir: &std::path::Path, manifest: &Value) -> Listing {
    let drawn = super::dev::view_interface(manifest);
    let missing = |why: String| Listing { scenes: Vec::new(), missing: Some(why), note: None };
    let path = dir.join(RECORDED);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(_) if drawn.is_none() => {
            return Listing { scenes: Vec::new(), missing: None, note: None };
        }
        Err(_) => {
            return missing(format!(
                "no recorded scenes: run cmux ext shot --record (it writes {RECORDED}) for each size and state worth checking, so review can check its design"
            ));
        }
    };
    let value = match serde_json::from_str::<Value>(&text) {
        Ok(value) => value,
        Err(error) => {
            return missing(format!(
                "{RECORDED} does not read: {error}; record it again with cmux ext shot --record"
            ));
        }
    };
    let scenes = scenes_in(RECORDED, &value);
    if scenes.is_empty() {
        return missing(format!(
            "{RECORDED} has no scene ops; record it again with cmux ext shot --record"
        ));
    }
    if !shipped(manifest, RECORDED) {
        return missing(format!(
            "{RECORDED} is not in the package, so review cannot read it: add \"preview/\" to the manifest's files"
        ));
    }
    let design_file = super::design_system::FILE;
    let (system, problem, note) = if shipped(manifest, design_file) {
        let (system, problem) = System::load(dir);
        (system, problem, None)
    } else {
        let note = dir.join(design_file).is_file().then(|| {
            format!(
                "{design_file} is not in the package, so these scenes were checked against cmux's system, as review checks the release; add \"{design_file}\" to the manifest's files to check against yours"
            )
        });
        (System::cmux(), None, note)
    };
    let scenes = scenes
        .into_iter()
        .map(|(name, ops)| {
            let surface =
                surface_of(name.trim_start_matches(&format!("{RECORDED}:")), drawn.as_deref());
            let findings = if scene::apply(&[&ops]).0.is_none() {
                vec![Finding {
                    check: "scene",
                    node: None,
                    message: "the ops name no root, so there is no scene to check".into(),
                    fix: "record it again with cmux ext shot --record".into(),
                    count: 1,
                }]
            } else {
                problem.clone().into_iter().chain(check_in(&[&ops], surface, &system)).collect()
            };
            (name, findings)
        })
        .collect();
    Listing { scenes, missing: None, note }
}

/// `ext design --listing DIR [--json]`: [`listing`] for a folder; exit 0 clean, 1 refused,
/// 4 when the folder has no manifest.
pub(super) fn run_listing(dir: &std::path::Path, json_out: bool) -> i32 {
    let manifest = ["cmux-app.json", "cmux-app.v2.json"]
        .iter()
        .find_map(|file| std::fs::read_to_string(dir.join(file)).ok())
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let Some(manifest) = manifest else {
        eprintln!("cmux: {}: no cmux-app.json that reads", dir.display());
        return super::exit::MANIFEST_INVALID;
    };
    let review = listing(dir, &manifest);
    if json_out {
        println!("{}", review.to_json());
    } else {
        println!("{}", review.summary());
        for line in review.details() {
            println!("  {line}");
        }
    }
    if review.ok() { super::exit::OK } else { super::exit::LOAD_FAILED }
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

/// What a node's text sits on: each candidate's name and color.
type Behind = Vec<(String, [f64; 3])>;

fn text(
    node: &Node,
    behind: &Behind,
    surface: Surface,
    system: &System,
    findings: &mut Findings,
    styles: &mut BTreeSet<String>,
) {
    let mut weight = node.props.get("weight").and_then(Value::as_str).unwrap_or("");
    let font = node.props.get("font");
    let mut size = 13.0;
    match font {
        Some(Value::Number(_)) => {
            let points = number(font).unwrap_or(13.0);
            size = points;
            if !system.has_size(points) {
                findings.add(
                    "type-size",
                    Some(node),
                    format!("font size {points} is not on the type scale"),
                    format!("use {}", system.nearest_roles(points)),
                );
            }
            styles.insert(match system.role_of(points, weight) {
                Some(role) => role.name.clone(),
                None => format!("{points} {}", if weight.is_empty() { "regular" } else { weight }),
            });
        }
        Some(Value::String(name)) => match scene_type::named(name) {
            Some(style) => {
                size = style.size;
                if style.role.is_some() && scene_type::exact_role(style).is_none() {
                    let role = style.role.as_deref().and_then(scene_type::named);
                    let (fix_role, call) = match role {
                        Some(role) => (
                            role.name.as_str(),
                            role.helper
                                .as_deref()
                                .map(|h| format!(" or {h}(...)"))
                                .unwrap_or_default(),
                        ),
                        None => ("body", String::new()),
                    };
                    findings.add(
                        "type-style",
                        Some(node),
                        format!(
                            "font \"{name}\" is no type role: it draws {} pt {} (the role at that size is \"{fix_role}\")",
                            style.size, style.weight
                        ),
                        format!("rename it: font \"{fix_role}\"{call}"),
                    );
                }
                let drawn = if weight.is_empty() { style.weight.as_str() } else { weight };
                styles.insert(match system.role_of(style.size, drawn) {
                    Some(role) => role.name.clone(),
                    None => format!("{name} {drawn}"),
                });
                weight = drawn;
            }
            None => {
                let roles: Vec<&str> =
                    scene_type::roles().iter().map(|r| r.name.as_str()).collect();
                findings.add(
                    "type-style",
                    Some(node),
                    format!("font \"{name}\" is no type role or text style, so it draws as body"),
                    format!("use a type role: {}", roles.join(", ")),
                );
                styles.insert(format!(
                    "body{}",
                    if weight.is_empty() { String::new() } else { format!(" {weight}") }
                ));
            }
        },
        _ => {
            styles.insert(format!(
                "body{}",
                if weight.is_empty() { String::new() } else { format!(" {weight}") }
            ));
        }
    }
    if let Some((color, alpha)) = node.props.get("color").and_then(Value::as_str).and_then(hex) {
        let bold = matches!(weight, "semibold" | "bold" | "heavy" | "black");
        let large = size >= 18.0 || (bold && size >= 14.0);
        let floor = if large { 3.0 } else { 4.5 };
        for (what, bg) in behind {
            // A translucent text color shows its background through: measure what is drawn.
            let drawn = over(color, alpha, *bg);
            let ratio = contrast(drawn, *bg);
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

fn spacing(node: &Node, system: &System, findings: &mut Findings) {
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
        if system.space.contains(&value) {
            continue;
        }
        let near = system.nearest_step(value);
        findings.add(
            "spacing",
            Some(node),
            format!("{key} {value} is not on the spacing scale"),
            format!("use {near} ({})", system.scale_text()),
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
    let channel = |i: usize| {
        let pair = digits.get(i..)?.get(..2)?;
        u8::from_str_radix(pair, 16).ok().map(|v| f64::from(v) / 255.0)
    };
    let alpha = if digits.len() == 8 { channel(6)? } else { 1.0 };
    Some(([channel(0)?, channel(2)?, channel(4)?], alpha))
}

/// WCAG 2 contrast ratio of two sRGB colors.
/// `fg` at `alpha` drawn over `bg`: what the eye sees, channel by channel.
fn over(fg: [f64; 3], alpha: f64, bg: [f64; 3]) -> [f64; 3] {
    let mut drawn = bg;
    for (out, top) in drawn.iter_mut().zip(fg) {
        *out = top * alpha + *out * (1.0 - alpha);
    }
    drawn
}

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
