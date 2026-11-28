//! Tooltip and hover card rules the app's TooltipPresenter and HoverCards still decide in Swift
//! (the machines are cmux-motion's): tooltip metrics and placement, the tooltip surface's legible
//! ink and tint, the gallery's samples and columns, the hover card tokens and the coordinator's
//! pointer decisions.
//!
//! Ops: `hover.NAME` (see [`call`]). Pinned by `tests/hover.rs`.

use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

// MARK: Tooltip metrics

/// TooltipMetrics.
pub mod tooltip_metrics {
    pub const FONT_SIZE: f64 = 12.0;
    pub const LINE_HEIGHT: f64 = 16.0;
    pub const PADDING_BLOCK: f64 = 4.0;
    pub const PADDING_INLINE: f64 = 8.0;
    pub const RADIUS: f64 = 8.0;
    pub const KEYCAP_HEIGHT: f64 = 16.0;
    pub const KEYCAP_INSET: f64 = 4.0;
    pub const KEYCAP_PADDING: f64 = 4.0;
    pub const KEYCAP_GAP: f64 = 8.0;
    pub const KEYCAP_RADIUS: f64 = RADIUS - KEYCAP_INSET;
    pub const MAX_WIDTH: f64 = 320.0;
    pub const GAP: f64 = 4.0;
    pub const EDGE: f64 = 4.0;
}

pub fn tooltip_metrics() -> Value {
    use tooltip_metrics::*;
    json!({
        "fontSize": FONT_SIZE, "lineHeight": LINE_HEIGHT, "paddingBlock": PADDING_BLOCK,
        "paddingInline": PADDING_INLINE, "radius": RADIUS, "keycapHeight": KEYCAP_HEIGHT,
        "keycapInset": KEYCAP_INSET, "keycapPadding": KEYCAP_PADDING, "keycapGap": KEYCAP_GAP,
        "keycapRadius": KEYCAP_RADIUS, "maxWidth": MAX_WIDTH, "gap": GAP, "edge": EDGE,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// TooltipPresenter.origin: below the anchor (AppKit's y grows up), centered on it, kept
/// [`tooltip_metrics::EDGE`] inside the screen; above it when asked and it fits, or when below
/// does not fit. Rounded to whole points.
pub fn tooltip_origin(
    width: f64,
    height: f64,
    anchor: Rect,
    screen: Rect,
    prefer_above: bool,
) -> Point {
    use tooltip_metrics::{EDGE, GAP};
    let below = anchor.y - GAP - height;
    let above = anchor.y + anchor.height + GAP;
    let screen_max_y = screen.y + screen.height;
    let fits_below = below >= screen.y + EDGE;
    let fits_above = above + height <= screen_max_y - EDGE;
    let y = if prefer_above && fits_above {
        above
    } else if fits_below {
        below
    } else {
        above.min(screen_max_y - EDGE - height)
    };
    let centered = anchor.x + anchor.width / 2.0 - width / 2.0;
    let x = (screen.x + EDGE)
        .max(centered)
        .min((screen.x + EDGE).max(screen.x + screen.width - EDGE - width));
    Point { x: x.round(), y: y.round() }
}

/// TooltipPanel.margin: the clear room around the tooltip for its shadow.
pub const TOOLTIP_PANEL_MARGIN: f64 = 3.0;
/// TooltipPresenter: how often a shown tooltip rechecks its anchor (ms).
pub const TOOLTIP_RECHECK_MS: u64 = 500;
/// TooltipPresenter: the quiet after a scroll before a tooltip shows again (ms).
pub const TOOLTIP_SCROLL_QUIET_MS: u64 = 150;

// MARK: Colour (ThemeRGB's math)

/// ThemeRGB: sRGB channels and alpha, each clamped to 0...1.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    #[serde(default = "one")]
    pub alpha: f64,
}

fn one() -> f64 {
    1.0
}

/// ThemeTokens.minimumTextContrast (WCAG AA body text).
pub const MINIMUM_TEXT_CONTRAST: f64 = 4.5;

impl Rgb {
    pub const BLACK: Rgb = Rgb { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    pub const WHITE: Rgb = Rgb { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };

    pub fn new(red: f64, green: f64, blue: f64, alpha: f64) -> Self {
        let c = |v: f64| v.clamp(0.0, 1.0);
        Self { red: c(red), green: c(green), blue: c(blue), alpha: c(alpha) }
    }

    pub fn hex(hex: u32) -> Self {
        let ch = |shift: u32| f64::from((hex >> shift) & 0xFF) / 255.0;
        Self::new(ch(16), ch(8), ch(0), 1.0)
    }

    /// `#RRGGBB` or `RRGGBB`.
    pub fn parse_hex(text: &str) -> Option<Self> {
        let digits = text.strip_prefix('#').unwrap_or(text);
        (digits.len() == 6).then(|| u32::from_str_radix(digits, 16).ok().map(Self::hex)).flatten()
    }

    /// The colour as clamped (a request may carry any numbers).
    pub fn clamped(self) -> Self {
        Self::new(self.red, self.green, self.blue, self.alpha)
    }

    pub fn with_alpha(self, alpha: f64) -> Self {
        Self::new(self.red, self.green, self.blue, alpha)
    }

    pub fn relative_luminance(self) -> f64 {
        let linear =
            |c: f64| if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) };
        0.2126 * linear(self.red) + 0.7152 * linear(self.green) + 0.0722 * linear(self.blue)
    }

    /// WCAG contrast; alpha is ignored.
    pub fn contrast(self, other: Rgb) -> f64 {
        let (a, b) = (self.relative_luminance(), other.relative_luminance());
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    /// Each channel `t` of the way to `toward`; keeps this alpha.
    pub fn mixed(self, toward: Rgb, t: f64) -> Self {
        let t = t.clamp(0.0, 1.0);
        let lerp = |a: f64, b: f64| a + (b - a) * t;
        Self::new(
            lerp(self.red, toward.red),
            lerp(self.green, toward.green),
            lerp(self.blue, toward.blue),
            self.alpha,
        )
    }

    /// This colour at its alpha over an opaque `base`.
    pub fn composited(self, base: Rgb) -> Self {
        base.mixed(self.with_alpha(1.0), self.alpha).with_alpha(1.0)
    }

    /// WebTheme.cssRounded: what a page draws (8-bit channels, alpha to 3 places of an 8-bit value).
    pub fn css_rounded(self) -> Self {
        let byte = |v: f64| (v * 255.0).round() / 255.0;
        let alpha = ((self.alpha * 255.0).round() / 255.0 * 1000.0).round() / 1000.0;
        Self::new(byte(self.red), byte(self.green), byte(self.blue), alpha)
    }
}

// MARK: Tooltip surface

pub const TOOLTIP_BLUR_RADIUS: f64 = 24.0;
pub const TOOLTIP_MINIMUM_TINT_ALPHA: f64 = 0.6;
pub const TOOLTIP_MAXIMUM_TINT_ALPHA: f64 = 0.9;

/// TooltipSurface: the theme's opaque fill, the ink that reads on it and the tint under the blur
/// that keeps that ink legible over any backdrop.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TooltipSurface {
    pub fill: Rgb,
    pub ink: Rgb,
    pub tint: Rgb,
}

impl TooltipSurface {
    pub fn new(fill: Rgb, ink: Rgb) -> Self {
        let fill = fill.clamped().with_alpha(1.0);
        let (ink, tint) = Self::legible(fill, ink.clamped().with_alpha(1.0));
        Self { fill, ink, tint }
    }

    /// The ink nearest the theme's that reads on the fill, and the tint nearest the fill (moved
    /// away from the ink) whose least alpha keeps it reading over black and white. Else the ink
    /// moves toward its pole until a tint of the far pole holds it; else white or black ink.
    pub fn legible(fill: Rgb, ink: Rgb) -> (Rgb, Rgb) {
        let light_ink = ink.relative_luminance() >= fill.relative_luminance();
        let away = if light_ink { Rgb::BLACK } else { Rgb::WHITE };
        let ink_pole = if light_ink { Rgb::WHITE } else { Rgb::BLACK };
        let opaque = (0..=100)
            .map(|i| ink.mixed(ink_pole, f64::from(i) / 100.0))
            .find(|c| Self::reads(*c, fill));
        if let Some(ink) = opaque {
            for step in 0..=100 {
                let color = fill.mixed(away, f64::from(step) / 100.0);
                if let Some(alpha) = Self::tint_alpha(color, ink) {
                    return (ink, color.with_alpha(alpha));
                }
            }
            for step in 1..=100 {
                let moved = ink.mixed(ink_pole, f64::from(step) / 100.0);
                if let Some(alpha) = Self::tint_alpha(away, moved) {
                    return (moved, away.with_alpha(alpha));
                }
            }
        }
        let pole = if Rgb::WHITE.contrast(fill) >= Rgb::BLACK.contrast(fill) {
            Rgb::WHITE
        } else {
            Rgb::BLACK
        };
        let under = if pole == Rgb::WHITE { Rgb::BLACK } else { Rgb::WHITE };
        (
            pole,
            under.with_alpha(Self::tint_alpha(under, pole).unwrap_or(TOOLTIP_MINIMUM_TINT_ALPHA)),
        )
    }

    /// The ink reads on the fill, as drawn natively and as a page rounds both.
    pub fn reads(ink: Rgb, fill: Rgb) -> bool {
        ink.contrast(fill).min(ink.css_rounded().contrast(fill.css_rounded()))
            >= MINIMUM_TEXT_CONTRAST
    }

    /// The least alpha from 0.60 to 0.90 at which `fill` keeps `ink` reading over black and white
    /// (natively and as a page rounds it); none when no alpha does.
    pub fn tint_alpha(fill: Rgb, ink: Rgb) -> Option<f64> {
        let least = (TOOLTIP_MINIMUM_TINT_ALPHA * 100.0).round() as i32;
        let most = (TOOLTIP_MAXIMUM_TINT_ALPHA * 100.0).round() as i32;
        let page_ink = ink.css_rounded();
        (least..=most).map(|p| fill.with_alpha(f64::from(p) / 100.0)).find_map(|tint| {
            let worst = Self::worst_contrast(ink, tint)
                .min(Self::worst_contrast(page_ink, tint.css_rounded()));
            (worst >= MINIMUM_TEXT_CONTRAST).then_some(tint.alpha)
        })
    }

    /// The ink's contrast on the tint over black and over white, whichever is lower.
    pub fn worst_contrast(ink: Rgb, tint: Rgb) -> f64 {
        ink.contrast(tint.composited(Rgb::hex(0x000000)))
            .min(ink.contrast(tint.composited(Rgb::hex(0xFFFFFF))))
    }
}

// MARK: Tooltip gallery

/// TooltipGallerySample.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TooltipGallerySample {
    pub name: &'static str,
    pub text: &'static str,
    pub shortcut: Option<&'static str>,
    pub opaque: bool,
}

const fn sample(
    name: &'static str,
    text: &'static str,
    shortcut: Option<&'static str>,
) -> TooltipGallerySample {
    TooltipGallerySample { name, text, shortcut, opaque: false }
}

pub const TOOLTIP_GALLERY_SAMPLES: [TooltipGallerySample; 6] = [
    sample("Text only", "Back", None),
    sample("With a shortcut", "New Tab", Some("⌘T")),
    sample("Several keys", "Select effort", Some("⌃⇧M")),
    sample(
        "Too long for 320 pt",
        "Open in New Window Beside This One, Keeping the Scroll Position and the Selection",
        None,
    ),
    sample(
        "Too long, with a shortcut",
        "Open in New Window Beside This One, Keeping the Scroll Position",
        Some("⌥⌘N"),
    ),
    TooltipGallerySample {
        name: "Reduce Transparency",
        text: "New Tab",
        shortcut: Some("⌘T"),
        opaque: true,
    },
];

/// One gallery column: the playground's light or dark theme, or the fixed accent theme.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TooltipGalleryColumn {
    pub title: &'static str,
    pub is_dark: bool,
    /// "playground" (the app's light or dark pick) or "accent".
    pub theme: &'static str,
    /// The accent column's spec name and colours.
    pub spec: Option<&'static str>,
    pub background: Option<Rgb>,
    pub foreground: Option<Rgb>,
}

pub const ACCENT_SPEC: &str = "Stress Purple";

pub fn tooltip_gallery_columns() -> Vec<TooltipGalleryColumn> {
    let playground = |title, is_dark| TooltipGalleryColumn {
        title,
        is_dark,
        theme: "playground",
        spec: None,
        background: None,
        foreground: None,
    };
    vec![
        playground("Light", false),
        playground("Dark", true),
        TooltipGalleryColumn {
            title: "Accent",
            is_dark: true,
            theme: "accent",
            spec: Some(ACCENT_SPEC),
            background: Some(Rgb::hex(0x2B1650)),
            foreground: Some(Rgb::hex(0xF4E3FF)),
        },
    ]
}

/// TooltipGalleryWindow.makeWindow.
pub fn tooltip_gallery_window() -> Value {
    json!({
        "frame": {"x": 0.0, "y": 0.0, "width": 1180.0, "height": 760.0},
        "minSize": {"width": 700.0, "height": 400.0},
        "title": "Tooltip Gallery",
        "accessibilityIdentifier": "cmux.tooltipGallery",
        "styleMask": ["titled", "closable", "resizable", "miniaturizable"],
    })
}

// MARK: Hover cards

/// HoverCardEntrance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoverCardEntrance {
    Fade,
    Slide,
    Morph,
}

impl HoverCardEntrance {
    pub const ALL: [Self; 3] = [Self::Fade, Self::Slide, Self::Morph];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Fade => "fade",
            Self::Slide => "slide",
            Self::Morph => "morph",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Fade => "Fade",
            Self::Slide => "Fade and slide",
            Self::Morph => "Grow out of the tab",
        }
    }
}

/// HoverCardRetarget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoverCardRetarget {
    Jump,
    Crossfade,
    Glide,
}

impl HoverCardRetarget {
    pub const ALL: [Self; 3] = [Self::Jump, Self::Crossfade, Self::Glide];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Jump => "jump",
            Self::Crossfade => "crossfade",
            Self::Glide => "glide",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Jump => "Switch in place",
            Self::Crossfade => "Switch in place, crossfade content",
            Self::Glide => "Glide to the next tab",
        }
    }
}

fn choices<T: Copy>(
    all: &[T],
    raw: fn(T) -> &'static str,
    title: fn(T) -> &'static str,
) -> Vec<Value> {
    all.iter().map(|c| json!({"rawValue": raw(*c), "title": title(*c)})).collect()
}

/// HoverCardStyle's numbers and named fonts and inks (the corner radius is the panel's tunable).
pub fn hover_card_style() -> Value {
    json!({
        "padding": 16.0,
        "titleGap": 8.0,
        "rowGap": 8.0,
        "mediaGap": 16.0,
        "cornerRadius": "panelCornerRadius",
        "titleFont": "bodyEmphasized",
        "secondaryFont": "body",
        "titleInk": "primary",
        "secondaryInk": "secondary",
    })
}

/// HoverCardGroup.sidebar.
pub const SIDEBAR_GROUP: &str = "sidebar";

/// HoverCardPresentNote: what the last present decided.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HoverCardPresentNote {
    pub on_screen: bool,
    pub glides: bool,
    pub sweeping: bool,
    pub fades_bodies: bool,
    pub same_body: bool,
    pub moves: bool,
    pub live_resize: bool,
    pub in_place: bool,
    pub morphed: bool,
}

impl HoverCardPresentNote {
    /// `on_screen=true glides=false ...` (`debug.hover_cards` `last_present`).
    pub fn text(&self) -> String {
        [
            ("on_screen", self.on_screen),
            ("glides", self.glides),
            ("sweeping", self.sweeping),
            ("fades_bodies", self.fades_bodies),
            ("same_body", self.same_body),
            ("moves", self.moves),
            ("live_resize", self.live_resize),
            ("in_place", self.in_place),
            ("morphed", self.morphed),
        ]
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(" ")
    }
}

// MARK: Pointer decisions (HoverCardCoordinator+Pointer)

/// What `updateCardMouse` sets: none leaves the window as it is (an owner's card, a card that
/// takes no clicks, or no change); else whether the window ignores the mouse.
pub fn card_ignores_mouse(
    owned: bool,
    interactive: bool,
    shown: bool,
    showing_card: bool,
    pointer_on_card: bool,
    ignores_now: bool,
) -> Option<bool> {
    if owned || !interactive {
        return None;
    }
    let ignores = !(shown && showing_card && pointer_on_card);
    (ignores != ignores_now).then_some(ignores)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MonitoredEventType {
    KeyDown,
    LeftMouseDown,
    RightMouseDown,
    OtherMouseDown,
    ScrollWheel,
}

/// One event the dismissal monitor saw, with the app's answers about it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MonitoredEvent {
    #[serde(rename = "type")]
    pub kind: Option<MonitoredEventType>,
    pub interactive: bool,
    pub showing_card: bool,
    /// The machine has a shown target.
    pub shown: bool,
    /// The event's window is the card's parent or one of its children.
    pub belongs_to_parent: bool,
    /// The current pointer is on the card.
    pub pointer_on_card: bool,
    /// The event's point is on the card.
    pub point_on_card: bool,
    /// The interactive body handled the key.
    pub body_took_key: bool,
    /// The interactive body accepts a click at the point.
    pub body_accepts_mouse: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "outcome")]
pub enum MonitoredOutcome {
    /// The card's body took the key; the event goes no further.
    KeyTaken,
    /// Deliver the click to the card's row; the card stays.
    DeliverToCard,
    /// The card scrolls its own scroll view; the event goes no further.
    ScrollCard,
    /// End the card and pass the event on.
    Dismiss { reason: HoverDismissal },
}

/// HoverDismissal's monitor reasons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HoverDismissal {
    KeyDown,
    ScrollWheel,
    Click,
}

/// `handleMonitoredEvent`'s decision.
pub fn monitored_event(e: MonitoredEvent) -> MonitoredOutcome {
    let kind = e.kind;
    if e.interactive && e.showing_card {
        if kind == Some(MonitoredEventType::KeyDown)
            && e.belongs_to_parent
            && e.pointer_on_card
            && e.body_took_key
        {
            return MonitoredOutcome::KeyTaken;
        }
        if e.point_on_card
            && kind == Some(MonitoredEventType::LeftMouseDown)
            && e.body_accepts_mouse
        {
            return MonitoredOutcome::DeliverToCard;
        }
    }
    if kind == Some(MonitoredEventType::ScrollWheel) && e.shown && e.showing_card && e.point_on_card
    {
        return MonitoredOutcome::ScrollCard;
    }
    let reason = match kind {
        Some(MonitoredEventType::KeyDown) => HoverDismissal::KeyDown,
        Some(MonitoredEventType::ScrollWheel) => HoverDismissal::ScrollWheel,
        _ => HoverDismissal::Click,
    };
    MonitoredOutcome::Dismiss { reason }
}

// MARK: Ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OriginRequest {
    width: f64,
    height: f64,
    anchor: Rect,
    screen: Rect,
    #[serde(default)]
    prefer_above: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceRequest {
    fill: Rgb,
    ink: Rgb,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CardMouseRequest {
    #[serde(default)]
    owned: bool,
    interactive: bool,
    shown: bool,
    showing_card: bool,
    pointer_on_card: bool,
    ignores_now: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteRequest {
    note: HoverCardPresentNote,
}

/// Runs `hover.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "tooltipMetrics" => reply(&tooltip_metrics()),
        "tooltipTiming" => reply(&json!({
            "panelMargin": TOOLTIP_PANEL_MARGIN,
            "recheckMs": TOOLTIP_RECHECK_MS,
            "scrollQuietMs": TOOLTIP_SCROLL_QUIET_MS,
        })),
        "tooltipOrigin" => {
            let r = parse::<OriginRequest>(request)?;
            reply(&tooltip_origin(r.width, r.height, r.anchor, r.screen, r.prefer_above))
        }
        "tooltipSurface" => {
            let r = parse::<SurfaceRequest>(request)?;
            reply(&TooltipSurface::new(r.fill, r.ink))
        }
        "tooltipSurfaceConstants" => reply(&json!({
            "blurRadius": TOOLTIP_BLUR_RADIUS,
            "minimumTintAlpha": TOOLTIP_MINIMUM_TINT_ALPHA,
            "maximumTintAlpha": TOOLTIP_MAXIMUM_TINT_ALPHA,
            "minimumTextContrast": MINIMUM_TEXT_CONTRAST,
        })),
        "gallerySamples" => reply(&TOOLTIP_GALLERY_SAMPLES),
        "galleryColumns" => reply(&tooltip_gallery_columns()),
        "galleryWindow" => reply(&tooltip_gallery_window()),
        "entrances" => reply(&choices(
            &HoverCardEntrance::ALL,
            HoverCardEntrance::raw_value,
            HoverCardEntrance::title,
        )),
        "retargets" => reply(&choices(
            &HoverCardRetarget::ALL,
            HoverCardRetarget::raw_value,
            HoverCardRetarget::title,
        )),
        "cardStyle" => reply(&hover_card_style()),
        "presentNote" => reply(&parse::<NoteRequest>(request)?.note.text()),
        "cardMouse" => {
            let r = parse::<CardMouseRequest>(request)?;
            reply(&card_ignores_mouse(
                r.owned,
                r.interactive,
                r.shown,
                r.showing_card,
                r.pointer_on_card,
                r.ignores_now,
            ))
        }
        "monitoredEvent" => {
            let e = parse::<MonitoredEvent>(request)?;
            if e.kind.is_none() {
                return Err(OpError::Invalid("type".into()));
            }
            reply(&monitored_event(e))
        }
        _ => Err(OpError::Unknown),
    }
}
