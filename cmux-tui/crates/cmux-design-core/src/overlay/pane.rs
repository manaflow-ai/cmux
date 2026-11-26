//! The floating pane's look: `FloatingPaneMaterial`, `FloatingPaneCornerMode`,
//! `FloatingPaneTunables` and `FloatingPaneLook` (CmuxNextDesign/FloatingPane).

use serde::{Deserialize, Serialize};

/// `FloatingPaneMaterial`: none, or one of the system's materials.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FloatingPaneMaterial {
    None,
    HudWindow,
    Popover,
    Menu,
    Sidebar,
    HeaderView,
    Sheet,
    Titlebar,
    Selection,
    WindowBackground,
    ContentBackground,
    UnderWindowBackground,
    UnderPageBackground,
    #[serde(rename = "fullScreenUI")]
    FullScreenUi,
}

impl FloatingPaneMaterial {
    /// Every material, in Swift's `allCases` order.
    pub const ALL: [FloatingPaneMaterial; 14] = [
        Self::None,
        Self::HudWindow,
        Self::Popover,
        Self::Menu,
        Self::Sidebar,
        Self::HeaderView,
        Self::Sheet,
        Self::Titlebar,
        Self::Selection,
        Self::WindowBackground,
        Self::ContentBackground,
        Self::UnderWindowBackground,
        Self::UnderPageBackground,
        Self::FullScreenUi,
    ];

    /// `tunableTitle`.
    pub fn title(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::HudWindow => "HUD window",
            Self::Popover => "Popover",
            Self::Menu => "Menu",
            Self::Sidebar => "Sidebar",
            Self::HeaderView => "Header",
            Self::Sheet => "Sheet",
            Self::Titlebar => "Titlebar",
            Self::Selection => "Selection",
            Self::WindowBackground => "Window background",
            Self::ContentBackground => "Content background",
            Self::UnderWindowBackground => "Under window background",
            Self::UnderPageBackground => "Under page background",
            Self::FullScreenUi => "Full screen UI",
        }
    }

    /// `system`: the `NSVisualEffectView.Material` case name, nil for none.
    pub fn system(self) -> Option<&'static str> {
        Some(match self {
            Self::None => return None,
            Self::HudWindow => "hudWindow",
            Self::Popover => "popover",
            Self::Menu => "menu",
            Self::Sidebar => "sidebar",
            Self::HeaderView => "headerView",
            Self::Sheet => "sheet",
            Self::Titlebar => "titlebar",
            Self::Selection => "selection",
            Self::WindowBackground => "windowBackground",
            Self::ContentBackground => "contentBackground",
            Self::UnderWindowBackground => "underWindowBackground",
            Self::UnderPageBackground => "underPageBackground",
            Self::FullScreenUi => "fullScreenUI",
        })
    }
}

/// `FloatingPaneCornerMode`: what a floating pane's corners follow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FloatingPaneCornerMode {
    Concentric,
    Window,
    MainPane,
}

impl FloatingPaneCornerMode {
    /// Every mode, in Swift's `allCases` order.
    pub const ALL: [FloatingPaneCornerMode; 3] = [Self::Concentric, Self::Window, Self::MainPane];

    /// `tunableTitle`.
    pub fn title(self) -> &'static str {
        match self {
            Self::Concentric => "Concentric with the window",
            Self::Window => "The window's radius",
            Self::MainPane => "Main pane's radius",
        }
    }
}

/// One numeric knob of `FloatingPaneTunables`: its key, default, range and step.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NumberKnob {
    pub key: &'static str,
    pub default: f64,
    pub min: f64,
    pub max: f64,
    pub step: f64,
}

const fn knob(key: &'static str, default: f64, min: f64, max: f64, step: f64) -> NumberKnob {
    NumberKnob { key, default, min, max, step }
}

/// `FloatingPaneTunables.defaultCornerFloor`.
pub const DEFAULT_CORNER_FLOOR: f64 = 6.0;
/// `FloatingPaneTunables.defaultResizeBand`.
pub const DEFAULT_RESIZE_BAND: f64 = 12.0;
/// `FloatingPaneTunables.defaultCornerZone`.
pub const DEFAULT_CORNER_ZONE: f64 = 20.0;

/// `FloatingPaneTunables`' numeric knobs, in the section's order.
pub const NUMBER_KNOBS: [NumberKnob; 10] = [
    knob("floatingPane.backgroundOpacity", 1.0, 0.0, 1.0, 0.05),
    knob("floatingPane.tintStrength", 0.0, 0.0, 1.0, 0.05),
    knob("floatingPane.borderWidth", 1.0, 0.0, 6.0, 0.5),
    knob("floatingPane.borderOpacity", 1.0, 0.0, 1.0, 0.05),
    knob("floatingPane.shadowOpacity", 0.35, 0.0, 1.0, 0.05),
    knob("floatingPane.shadowBlur", 14.0, 0.0, 60.0, 1.0),
    knob("floatingPane.shadowOffset", 4.0, -30.0, 30.0, 1.0),
    knob("floatingPane.cornerFloor", DEFAULT_CORNER_FLOOR, 0.0, 40.0, 0.5),
    knob("floatingPane.resizeBand", DEFAULT_RESIZE_BAND, 4.0, 24.0, 1.0),
    knob("floatingPane.cornerZone", DEFAULT_CORNER_ZONE, 10.0, 40.0, 1.0),
];

/// Every knob key of the section, in `FloatingPaneTunables.all`'s order.
pub const ALL_KEYS: [&str; 13] = [
    "floatingPane.backgroundOpacity",
    "floatingPane.material",
    "floatingPane.tint",
    "floatingPane.tintStrength",
    "floatingPane.borderWidth",
    "floatingPane.borderOpacity",
    "floatingPane.shadowOpacity",
    "floatingPane.shadowBlur",
    "floatingPane.shadowOffset",
    "floatingPane.cornerMode",
    "floatingPane.cornerFloor",
    "floatingPane.resizeBand",
    "floatingPane.cornerZone",
];

/// `FloatingPaneLook`: a floating pane's look as its card draws it. The tint is the
/// `TunableColor` raw value (`"glassTint"` by default).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FloatingPaneLook {
    pub background_opacity: f64,
    pub material: FloatingPaneMaterial,
    pub tint: String,
    pub tint_strength: f64,
    pub border_width: f64,
    pub border_opacity: f64,
    pub shadow_opacity: f64,
    pub shadow_blur: f64,
    pub shadow_offset: f64,
    pub corner_mode: FloatingPaneCornerMode,
    pub corner_floor: f64,
    pub resize_band: f64,
    pub corner_zone: f64,
}

impl Default for FloatingPaneLook {
    fn default() -> Self {
        FloatingPaneLook {
            background_opacity: 1.0,
            material: FloatingPaneMaterial::None,
            tint: "glassTint".into(),
            tint_strength: 0.0,
            border_width: 1.0,
            border_opacity: 1.0,
            shadow_opacity: 0.35,
            shadow_blur: 14.0,
            shadow_offset: 4.0,
            corner_mode: FloatingPaneCornerMode::Concentric,
            corner_floor: DEFAULT_CORNER_FLOOR,
            resize_band: DEFAULT_RESIZE_BAND,
            corner_zone: DEFAULT_CORNER_ZONE,
        }
    }
}

fn unit(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

impl FloatingPaneLook {
    /// `FloatingPaneLook.current` given the knobs' raw values: the fractions clamped to 0...1, the
    /// widths and blur at least 0, the resize band to 4...24 and the corner zone to 10...40.
    pub fn from_knobs(raw: &FloatingPaneLook) -> FloatingPaneLook {
        FloatingPaneLook {
            background_opacity: unit(raw.background_opacity),
            material: raw.material,
            tint: raw.tint.clone(),
            tint_strength: unit(raw.tint_strength),
            border_width: raw.border_width.max(0.0),
            border_opacity: unit(raw.border_opacity),
            shadow_opacity: unit(raw.shadow_opacity),
            shadow_blur: raw.shadow_blur.max(0.0),
            shadow_offset: raw.shadow_offset,
            corner_mode: raw.corner_mode,
            corner_floor: raw.corner_floor.max(0.0),
            resize_band: raw.resize_band.clamp(4.0, 24.0),
            corner_zone: raw.corner_zone.clamp(10.0, 40.0),
        }
    }

    /// `isSeeThrough`: the panes under it show through its background.
    pub fn is_see_through(&self) -> bool {
        self.background_opacity < 1.0
    }
}
