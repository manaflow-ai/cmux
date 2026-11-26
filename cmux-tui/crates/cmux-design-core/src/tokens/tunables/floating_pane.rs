//! A floating pane's look knobs: ports `FloatingPaneTunables` and `FloatingPaneLook`
//! (CmuxNextDesign/FloatingPane/FloatingPaneTunables.swift), with the choice options of
//! `FloatingPaneMaterial` and `FloatingPaneCornerMode` they offer. The store's overrides come in
//! as a key-to-value map; `FloatingPaneLook.current` reads them as `Tunable.value` does.

use super::descriptor::{
    DefaultSource, TunableChoiceOption, TunableDescriptor, TunableKind, TunableSection,
    TunableUnit, TunableValue, clamp_to, smax,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// `FloatingPaneTunables.section`.
pub fn section() -> TunableSection {
    TunableSection::new("floatingPane", "Floating Pane", "macwindow.on.rectangle", 15)
}

/// `FloatingPaneTunables.defaultCornerFloor`.
pub const DEFAULT_CORNER_FLOOR: f64 = 6.0;
/// `FloatingPaneTunables.defaultResizeBand`.
pub const DEFAULT_RESIZE_BAND: f64 = 12.0;
/// `FloatingPaneTunables.defaultCornerZone`.
pub const DEFAULT_CORNER_ZONE: f64 = 20.0;

/// `FloatingPaneMaterial`'s cases: raw value and Debug Settings title, in order.
pub const MATERIALS: [(&str, &str); 14] = [
    ("none", "None"),
    ("hudWindow", "HUD window"),
    ("popover", "Popover"),
    ("menu", "Menu"),
    ("sidebar", "Sidebar"),
    ("headerView", "Header"),
    ("sheet", "Sheet"),
    ("titlebar", "Titlebar"),
    ("selection", "Selection"),
    ("windowBackground", "Window background"),
    ("contentBackground", "Content background"),
    ("underWindowBackground", "Under window background"),
    ("underPageBackground", "Under page background"),
    ("fullScreenUI", "Full screen UI"),
];

/// `FloatingPaneCornerMode`'s cases: raw value and Debug Settings title, in order.
pub const CORNER_MODES: [(&str, &str); 3] = [
    ("concentric", "Concentric with the window"),
    ("window", "The window's radius"),
    ("mainPane", "Main pane's radius"),
];

fn options(cases: &[(&str, &str)]) -> Vec<TunableChoiceOption> {
    cases.iter().map(|(v, t)| TunableChoiceOption::new(*v, *t)).collect()
}

fn number(
    name: &str,
    label: &str,
    help: &str,
    default: f64,
    range: (f64, f64),
    step: f64,
    unit: TunableUnit,
) -> TunableDescriptor {
    TunableDescriptor {
        key: format!("floatingPane.{name}"),
        section: section(),
        label: label.into(),
        help: help.into(),
        kind: TunableKind::number(range, step, unit),
        default_source: DefaultSource::Fixed(TunableValue::Number(default)),
        code_name: Some(format!("FloatingPaneTunables.{name}")),
        read_cadence: Default::default(),
    }
}

fn other(
    name: &str,
    label: &str,
    help: &str,
    kind: TunableKind,
    default: TunableValue,
) -> TunableDescriptor {
    TunableDescriptor {
        key: format!("floatingPane.{name}"),
        section: section(),
        label: label.into(),
        help: help.into(),
        kind,
        default_source: DefaultSource::Fixed(default),
        code_name: Some(format!("FloatingPaneTunables.{name}")),
        read_cadence: Default::default(),
    }
}

/// `FloatingPaneTunables.all`: the 13 knobs' descriptors, in order.
pub fn descriptors() -> Vec<TunableDescriptor> {
    use TunableUnit::{Fraction, Points};
    vec![
        number(
            "backgroundOpacity",
            "Background opacity",
            "The opacity of the pane's background. Below 1 the panes under it show through; a terminal's text stays solid. A browser page stays opaque.",
            1.0,
            (0.0, 1.0),
            0.05,
            Fraction,
        ),
        other(
            "material",
            "Material",
            "A system material behind the background: it blurs what is under the pane. It shows when the background opacity is below 1.",
            TunableKind::Choice(options(&MATERIALS)),
            TunableValue::Choice("none".into()),
        ),
        other(
            "tint",
            "Tint",
            "A theme colour over the background, at the tint strength.",
            TunableKind::Color,
            TunableValue::Color("glassTint".into()),
        ),
        number(
            "tintStrength",
            "Tint strength",
            "The opacity of the tint. 0: no tint.",
            0.0,
            (0.0, 1.0),
            0.05,
            Fraction,
        ),
        number(
            "borderWidth",
            "Border width",
            "The width of the line around the pane. 0: no line.",
            1.0,
            (0.0, 6.0),
            0.5,
            Points,
        ),
        number(
            "borderOpacity",
            "Border opacity",
            "The opacity of the line around the pane.",
            1.0,
            (0.0, 1.0),
            0.05,
            Fraction,
        ),
        number(
            "shadowOpacity",
            "Shadow opacity",
            "The opacity of the shadow under the pane. 0: no shadow.",
            0.35,
            (0.0, 1.0),
            0.05,
            Fraction,
        ),
        number(
            "shadowBlur",
            "Shadow blur",
            "The blur radius of the shadow.",
            14.0,
            (0.0, 60.0),
            1.0,
            Points,
        ),
        number(
            "shadowOffset",
            "Shadow offset",
            "How far below the pane the shadow lies. A negative value puts it above.",
            4.0,
            (-30.0, 30.0),
            1.0,
            Points,
        ),
        other(
            "cornerMode",
            "Corner mode",
            "Concentric with the window: a corner is the window's radius less its distance from the window's edges, and never below the corner floor. The window's radius: each corner has the window's radius at each place. Main pane's radius: each corner has the main pane's radius.",
            TunableKind::Choice(options(&CORNER_MODES)),
            TunableValue::Choice("concentric".into()),
        ),
        number(
            "cornerFloor",
            "Corner floor",
            "The smallest corner radius when the corner mode is concentric with the window. A corner is the window's radius less its distance from the window's edges, and never below this.",
            DEFAULT_CORNER_FLOOR,
            (0.0, 40.0),
            0.5,
            Points,
        ),
        number(
            "resizeBand",
            "Resize band",
            "The width of the band on each edge that resizes the pane. This value less 4 pt is outside the card's edge, over the panes below. Inside the edge the band is the top 4 pt of the bar, and the rim on the 3 other sides. At an edge of the pane area the band outside is only the room that is there.",
            DEFAULT_RESIZE_BAND,
            (4.0, 24.0),
            1.0,
            Points,
        ),
        number(
            "cornerZone",
            "Corner zone",
            "The side of the square at each corner that resizes 2 edges. The square starts at the outer corner of the resize band.",
            DEFAULT_CORNER_ZONE,
            (10.0, 40.0),
            1.0,
            Points,
        ),
    ]
}

/// `FloatingPaneLook`: a floating pane's look as its card draws it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingPaneLook {
    /// Background opacity, 0...1.
    pub background_opacity: f64,
    /// The material's raw value.
    pub material: String,
    /// The tint's `TunableColor` raw value.
    pub tint: String,
    /// Tint strength, 0...1.
    pub tint_strength: f64,
    /// Border width, not under 0.
    pub border_width: f64,
    /// Border opacity, 0...1.
    pub border_opacity: f64,
    /// Shadow opacity, 0...1.
    pub shadow_opacity: f64,
    /// Shadow blur, not under 0.
    pub shadow_blur: f64,
    /// Shadow offset.
    pub shadow_offset: f64,
    /// The corner mode's raw value.
    pub corner_mode: String,
    /// The concentric corner floor, not under 0.
    pub corner_floor: f64,
    /// The resize band, 4...24.
    pub resize_band: f64,
    /// The corner zone, 10...40.
    pub corner_zone: f64,
}

impl Default for FloatingPaneLook {
    fn default() -> Self {
        FloatingPaneLook {
            background_opacity: 1.0,
            material: "none".into(),
            tint: "glassTint".into(),
            tint_strength: 0.0,
            border_width: 1.0,
            border_opacity: 1.0,
            shadow_opacity: 0.35,
            shadow_blur: 14.0,
            shadow_offset: 4.0,
            corner_mode: "concentric".into(),
            corner_floor: DEFAULT_CORNER_FLOOR,
            resize_band: DEFAULT_RESIZE_BAND,
            corner_zone: DEFAULT_CORNER_ZONE,
        }
    }
}

impl FloatingPaneLook {
    /// `isSeeThrough`: the background opacity is under 1.
    pub fn is_see_through(&self) -> bool {
        self.background_opacity < 1.0
    }
}

fn unit(value: f64) -> f64 {
    clamp_to(value, 0.0, 1.0)
}

/// `FloatingPaneLook.current` over `overrides` (key to stored value): each knob's override when it
/// has the knob's type (a choice must name a case), else its default; then the look's clamps.
pub fn look(overrides: &BTreeMap<String, TunableValue>) -> FloatingPaneLook {
    let get = |name: &str| overrides.get(&format!("floatingPane.{name}"));
    let num =
        |name: &str, default: f64| get(name).and_then(TunableValue::number).unwrap_or(default);
    let choice = |name: &str, cases: &[(&str, &str)], default: &str| {
        get(name)
            .and_then(TunableValue::choice)
            .filter(|raw| cases.iter().any(|(v, _)| v == raw))
            .unwrap_or(default)
            .to_string()
    };
    FloatingPaneLook {
        background_opacity: unit(num("backgroundOpacity", 1.0)),
        material: choice("material", &MATERIALS, "none"),
        tint: get("tint").and_then(TunableValue::color).unwrap_or("glassTint").to_string(),
        tint_strength: unit(num("tintStrength", 0.0)),
        border_width: smax(0.0, num("borderWidth", 1.0)),
        border_opacity: unit(num("borderOpacity", 1.0)),
        shadow_opacity: unit(num("shadowOpacity", 0.35)),
        shadow_blur: smax(0.0, num("shadowBlur", 14.0)),
        shadow_offset: num("shadowOffset", 4.0),
        corner_mode: choice("cornerMode", &CORNER_MODES, "concentric"),
        corner_floor: smax(0.0, num("cornerFloor", DEFAULT_CORNER_FLOOR)),
        resize_band: clamp_to(num("resizeBand", DEFAULT_RESIZE_BAND), 4.0, 24.0),
        corner_zone: clamp_to(num("cornerZone", DEFAULT_CORNER_ZONE), 10.0, 40.0),
    }
}
