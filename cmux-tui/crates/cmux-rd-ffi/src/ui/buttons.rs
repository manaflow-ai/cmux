//! The viewer's buttons' rules (`MacScreenButtons.swift`): a button's padding and size, its ink and
//! fill for each state, its focus rule, a menu button's retitle, and the switch's knob. Swift keeps
//! the colours (it resolves `Palette` names) and draws. See `ui/mod.rs`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, raw: &Value) -> Answer {
    Some(match name {
        "metrics" => args::<MetricsArgs>(raw).and_then(|a| answer(&metrics(&a))),
        "style" => args::<StyleArgs>(raw).and_then(|a| answer(&style(&a))),
        "hintKern" => args::<KernArgs>(raw).and_then(|a| answer(&hint_kern(&a))),
        "takesFocus" => args::<FocusArgs>(raw).and_then(|a| answer(&takes_focus(&a))),
        "menuTitle" => args::<MenuTitleArgs>(raw).and_then(|a| answer(&menu_title(&a))),
        "switchKnob" => args::<SwitchArgs>(raw).and_then(|a| answer(&switch_knob(&a))),
        _ => return None,
    })
}

/// `MacScreenButton.Kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Kind {
    Primary,
    Plain,
    Destructive,
    Icon,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetricsArgs {
    kind: Kind,
    #[serde(default)]
    compact: bool,
    /// `Metrics.space1/3/4/6` at the density now.
    space1: f64,
    space3: f64,
    space4: f64,
    space6: f64,
    /// The label's (or glyph's) measured size.
    content_width: f64,
    content_height: f64,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ButtonMetrics {
    horizontal_padding: f64,
    min_height: f64,
    width: f64,
    height: f64,
    /// The label's font is the emphasized body (a primary button's).
    emphasized: bool,
}

/// An icon pads `space1` and is at least `space6` wide; a compact button pads `space3`, others `space4`.
fn metrics(a: &MetricsArgs) -> ButtonMetrics {
    let icon = a.kind == Kind::Icon;
    let horizontal_padding = if icon {
        a.space1
    } else if a.compact {
        a.space3
    } else {
        a.space4
    };
    let min_height = if a.compact || icon { 22.0 } else { 26.0 };
    let mut width = a.content_width.ceil() + horizontal_padding * 2.0;
    if icon {
        width = width.max(a.space6);
    }
    ButtonMetrics {
        horizontal_padding,
        min_height,
        width,
        height: min_height.max(a.content_height.ceil()),
        emphasized: a.kind == Kind::Primary,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StyleArgs {
    kind: Kind,
    enabled: bool,
    #[serde(default)]
    hovering: bool,
    #[serde(default)]
    pressed: bool,
}

/// A fill: a `MacScreenColors` colour by name, its own alpha times `alpha` (`clear` draws none).
#[derive(Serialize, Debug, PartialEq)]
struct Fill {
    color: &'static str,
    alpha: f64,
}

#[derive(Serialize, Debug, PartialEq)]
struct Style {
    /// The `Palette` ink of the label and glyph.
    foreground: &'static str,
    fill: Fill,
    /// The whole button's alpha (a disabled button dims).
    alpha: f64,
}

fn style(a: &StyleArgs) -> Style {
    let foreground = match a.kind {
        Kind::Primary => "onAccent",
        Kind::Destructive => "danger",
        Kind::Plain => "primary",
        Kind::Icon if a.hovering => "primary",
        Kind::Icon => "secondary",
    };
    let fill = match a.kind {
        Kind::Primary => {
            let alpha = if a.pressed {
                0.75
            } else if a.hovering {
                0.9
            } else {
                1.0
            };
            Fill { color: "accent", alpha }
        }
        Kind::Icon if a.pressed => Fill { color: "pressed", alpha: 1.0 },
        Kind::Icon if a.hovering && a.enabled => Fill { color: "hover", alpha: 1.0 },
        Kind::Icon => Fill { color: "clear", alpha: 1.0 },
        _ if a.pressed => Fill { color: "pressed", alpha: 1.0 },
        _ if a.hovering => Fill { color: "selection", alpha: 1.0 },
        _ => Fill { color: "hover", alpha: 1.0 },
    };
    Style { foreground, fill, alpha: if a.enabled { 1.0 } else { 0.45 } }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KernArgs {
    space2: f64,
    /// The measured width of a space in the hint's font.
    space_width: f64,
}

/// The kern after the label that sets the shortcut hint `space2` off it.
fn hint_kern(a: &KernArgs) -> f64 {
    (a.space2 - a.space_width).max(0.0)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FocusArgs {
    enabled: bool,
    takes_key_focus: bool,
    full_keyboard_access: bool,
}

fn takes_focus(a: &FocusArgs) -> bool {
    a.enabled && (a.takes_key_focus || a.full_keyboard_access)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MenuTitleArgs {
    /// The button's label now (nil: a glyph-only button, which never takes a title).
    label: Option<String>,
    /// The title asked for.
    title: String,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct MenuTitle {
    /// Set the label (and re-measure) only on a titled button whose title changes.
    retitle: bool,
    /// The button shows a word beside its glyph afterwards.
    has_title: bool,
}

/// `MacScreenMenuButton.retitle(_:)` and `hasTitle`.
fn menu_title(a: &MenuTitleArgs) -> MenuTitle {
    let retitle = a.label.as_deref().is_some_and(|l| l != a.title);
    let label = if retitle { Some(a.title.as_str()) } else { a.label.as_deref() };
    MenuTitle { retitle, has_title: !label.unwrap_or("").is_empty() }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwitchArgs {
    width: f64,
    height: f64,
    on: bool,
    dark: bool,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Knob {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    /// The track's fill: `focus` on; off, `primary` at `trackAlpha` (bordered in `separator`).
    track: &'static str,
    track_alpha: f64,
    track_border_width: f64,
    /// The knob's white, or `nil`: pure white.
    #[serde(skip_serializing_if = "Option::is_none")]
    knob_white: Option<f64>,
}

/// The knob insets 2, is 1.6 times as wide as tall (at most the track), and sits right when on.
fn switch_knob(a: &SwitchArgs) -> Knob {
    let inset = 2.0;
    let height = a.height - inset * 2.0;
    let width = (a.width - inset * 2.0).min((height * 1.6).round());
    Knob {
        x: if a.on { a.width - inset - width } else { inset },
        y: inset,
        width,
        height,
        track: if a.on { "focus" } else { "primary" },
        track_alpha: if a.on { 1.0 } else { 0.1 },
        track_border_width: if a.on { 0.0 } else { 0.5 },
        knob_white: (a.dark && !a.on).then_some(0.886),
    }
}

#[cfg(test)]
#[path = "buttons_tests.rs"]
mod tests;
