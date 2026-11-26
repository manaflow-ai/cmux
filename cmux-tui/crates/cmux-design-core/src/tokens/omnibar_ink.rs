//! The omnibar's ink, fitted to every ground the bar can show: ports `OmnibarInk.swift`
//! (CmuxNextDesign): `struct OmnibarInk` (`init`, `icon(on:bare:minimum:)`, `worstContrast`,
//! `readable`), its `AddressBarSurface` extension (`Backing`, `desktops`, `toolbarGrounds`,
//! `glassFrost`, `inkGrounds`, `ink`), `Palette.omnibarInk`'s backing pick and `OmnibarInk.reads`.
//!
//! `inkGrounds` needs the bar's fills, so the pure part of `AddressBarSurface.swift`
//! (`step`, `readableStep`, `cardStep`, `rowSelectedAlpha`, `fill`, `card`, `rowSelected`,
//! `resolvedCoverage`, `layered`, `worstContrast`) is ported here too as [`AddressBarSurface`].
//!
//! Ops: `tokens.omnibar_ink_new`, `tokens.omnibar_ink_icon_on`, `tokens.omnibar_ink_worst_contrast`,
//! `tokens.omnibar_ink_reads`, `tokens.omnibar_ink_grounds`, `tokens.omnibar_ink_for_surface`,
//! `tokens.omnibar_ink_surface`, `tokens.omnibar_ink_backing`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `ThemeTokens.minimumTextContrast`.
pub const MINIMUM_TEXT_CONTRAST: f64 = 4.5;

/// The omnibar's inks (`OmnibarInk`).
#[derive(Debug, Clone, PartialEq)]
pub struct OmnibarInk {
    /// The host, typed text, plain text, "Not secure" label and caret.
    pub primary: Rgb,
    /// The path after the host and the placeholder.
    pub secondary: Rgb,
    /// The site-info glyph, the star and the badges' text and glyphs.
    pub icon: Rgb,
    /// The opaque grounds the inks were fitted to.
    pub grounds: Vec<Rgb>,
}

impl OmnibarInk {
    /// Inks for `grounds` (each made opaque; none: black), from the theme's `text` and
    /// `secondary_text`; the icon starts from the primary at 83%.
    pub fn new(text: Rgb, secondary_text: Rgb, grounds: &[Rgb], minimum: f64) -> Self {
        let grounds: Vec<Rgb> = if grounds.is_empty() {
            vec![Rgb::BLACK]
        } else {
            grounds.iter().map(|g| g.with_alpha(1.0)).collect()
        };
        let primary = readable(text, &grounds, minimum, None);
        let secondary = readable(secondary_text, &grounds, minimum, Some(primary));
        let icon = readable(text.with_alpha(text.a * 0.83), &grounds, minimum, Some(primary));
        OmnibarInk { primary, secondary, icon, grounds }
    }

    /// `icon(on:bare:minimum:)`: the icon ink for a mark on the bar bare (`bare`) and on each of
    /// `plates` laid over it; else the primary; else a step toward a pole.
    pub fn icon_on(&self, plates: &[Rgb], bare: bool, minimum: f64) -> Rgb {
        let mut under: Vec<Rgb> = if bare { self.grounds.clone() } else { Vec::new() };
        for plate in plates {
            under.extend(self.grounds.iter().map(|g| plate.composited(*g)));
        }
        if under.is_empty() {
            return self.icon;
        }
        readable(self.icon, &under, minimum, Some(self.primary))
    }

    /// `reads(_:)`: whether `color` reads on every ground at the text minimum.
    pub fn reads(&self, color: Rgb) -> bool {
        worst_contrast(color, &self.grounds) >= MINIMUM_TEXT_CONTRAST
    }
}

/// `OmnibarInk.worstContrast`: the least contrast `ink` keeps over `grounds` (21 for none).
pub fn worst_contrast(ink: Rgb, grounds: &[Rgb]) -> f64 {
    grounds
        .iter()
        .map(|g| ink.composited(*g).contrast(g.with_alpha(1.0)))
        .reduce(f64::min)
        .unwrap_or(21.0)
}

/// `OmnibarInk.readable`: `preferred` when it reads on every ground; else `fallback`; else the
/// preferred (opaque on the first ground) moved toward the better pole in 5% steps; else that pole.
pub fn readable(preferred: Rgb, grounds: &[Rgb], minimum: f64, fallback: Option<Rgb>) -> Rgb {
    if worst_contrast(preferred, grounds) >= minimum {
        return preferred;
    }
    if let Some(fallback) = fallback.filter(|f| worst_contrast(*f, grounds) >= minimum) {
        return fallback;
    }
    // Swift's `max(by:)` keeps the first of equal maxima: white unless black is strictly better.
    let pole = if worst_contrast(Rgb::WHITE, grounds) < worst_contrast(Rgb::BLACK, grounds) {
        Rgb::BLACK
    } else {
        Rgb::WHITE
    };
    let Some(first) = grounds.first() else { return preferred };
    let start = preferred.composited(*first);
    for percent in (5..=100).step_by(5) {
        let candidate = start.mixed(pole, f64::from(percent) / 100.0);
        if worst_contrast(candidate, grounds) >= minimum {
            return candidate;
        }
    }
    pole
}

/// `AddressBarSurface.State`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BarState {
    /// At rest.
    Rest,
    /// Hovered.
    Hover,
}

impl BarState {
    /// `State.allCases`.
    pub const ALL: [BarState; 2] = [BarState::Rest, BarState::Hover];
}

/// The address bar's fills from the theme (`AddressBarSurface`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AddressBarSurface {
    /// `surfaceBackground`, opaque.
    pub background: Rgb,
    /// `textPrimary`, opaque.
    pub text: Rgb,
    /// A dark theme.
    pub is_dark: bool,
    /// The window's tint opacity behind the toolbar (1: opaque), 0...1.
    pub window_opacity: f64,
}

/// What draws under the bar's ink at rest (`AddressBarSurface.Backing`).
#[derive(Debug, Clone, PartialEq)]
pub enum Backing {
    /// The flat tonal fill at the look's `coverage`.
    Flat {
        /// The requested coverage.
        coverage: f64,
    },
    /// No fill; `hover` is the see-through hover fill.
    Clear {
        /// The hover fill.
        hover: Rgb,
    },
    /// Glass under each of `tints` (None: no tint) and the bar's `hover` lift.
    Glass {
        /// The tints.
        tints: Vec<Option<Rgb>>,
        /// The hover fill.
        hover: Rgb,
    },
}

impl AddressBarSurface {
    /// `init(_:windowOpacity:)` from the tokens it reads.
    pub fn new(
        surface_background: Rgb,
        text_primary: Rgb,
        is_dark: bool,
        window_opacity: f64,
    ) -> Self {
        AddressBarSurface {
            background: surface_background.with_alpha(1.0),
            text: text_primary.with_alpha(1.0),
            is_dark,
            window_opacity: if window_opacity.is_nan() {
                0.0
            } else {
                window_opacity.clamp(0.0, 1.0)
            },
        }
    }

    /// `step(_:isDark:)`: the step toward the text color.
    pub fn step(state: BarState, is_dark: bool) -> f64 {
        match state {
            BarState::Rest => {
                if is_dark {
                    0.10
                } else {
                    0.07
                }
            }
            BarState::Hover => {
                if is_dark {
                    0.245
                } else {
                    0.12
                }
            }
        }
    }

    /// `readableStep(_:)`: the step, eased back 1% at a time until the text keeps the minimum.
    pub fn readable_step(&self, state: BarState) -> f64 {
        let mut step = Self::step(state, self.is_dark);
        while step > 0.0
            && self.text.contrast(self.background.mixed(self.text, step)) < MINIMUM_TEXT_CONTRAST
        {
            step = (step - 0.01).max(0.0);
        }
        step
    }

    /// `cardStep(isDark:)`.
    pub fn card_step(is_dark: bool) -> f64 {
        if is_dark { 0.12 } else { 0.0 }
    }

    /// `rowSelectedAlpha(isDark:)`.
    pub fn row_selected_alpha(is_dark: bool) -> f64 {
        if is_dark { 0.105 } else { 0.05 }
    }

    /// `fill(_:coverage:)`: the bar's fill in `state` at the user's coverage.
    pub fn fill(&self, state: BarState, coverage: f64) -> Rgb {
        self.layered(self.readable_step(state), self.resolved_coverage(coverage))
    }

    /// `card`: the opaque suggestion card.
    pub fn card(&self) -> Rgb {
        self.background.mixed(self.text, Self::card_step(self.is_dark))
    }

    /// `rowSelected`: a selected suggestion row over the card.
    pub fn row_selected(&self) -> Rgb {
        self.text.with_alpha(Self::row_selected_alpha(self.is_dark))
    }

    /// `resolvedCoverage(_:)`: coverage raised to the legibility floor of every state.
    pub fn resolved_coverage(&self, coverage: f64) -> f64 {
        let requested = if coverage.is_finite() { coverage.clamp(0.0, 1.0) } else { 0.0 };
        if self.window_opacity >= 1.0 {
            return requested;
        }
        let steps: Vec<f64> = BarState::ALL.iter().map(|s| self.readable_step(*s)).collect();
        let readable = |candidate: f64| {
            steps
                .iter()
                .all(|s| self.worst_contrast(self.layered(*s, candidate)) >= MINIMUM_TEXT_CONTRAST)
        };
        if readable(requested) {
            return requested;
        }
        let start = (requested * 100.0 - 1e-9).ceil() as i64;
        for percent in start..=100 {
            let candidate = percent as f64 / 100.0;
            if readable(candidate) {
                return candidate;
            }
        }
        1.0
    }

    /// `layered(step:coverage:)`: the background at `coverage`, then the text at `step`, as one colour.
    pub fn layered(&self, step: f64, coverage: f64) -> Rgb {
        let alpha = 1.0 - (1.0 - step) * (1.0 - coverage);
        if alpha <= 0.0 {
            return self.background.with_alpha(0.0);
        }
        let channel = |t: f64, b: f64| (step * t + (1.0 - step) * coverage * b) / alpha;
        Rgb::new(
            channel(self.text.r, self.background.r),
            channel(self.text.g, self.background.g),
            channel(self.text.b, self.background.b),
            alpha,
        )
    }

    /// `worstContrast(_:)`: the text over `fill` on the window tint, over black and white desktops.
    pub fn worst_contrast(&self, fill: Rgb) -> f64 {
        [Rgb::hex(0x000000), Rgb::hex(0xFFFFFF)]
            .iter()
            .map(|desktop| {
                let window = self.background.with_alpha(self.window_opacity).composited(*desktop);
                self.text.contrast(fill.composited(window))
            })
            .reduce(f64::min)
            .unwrap_or(1.0)
    }

    /// `desktops`: black and white behind a see-through window; black in an opaque one.
    pub fn desktops(&self) -> Vec<Rgb> {
        if self.window_opacity < 1.0 { vec![Rgb::BLACK, Rgb::WHITE] } else { vec![Rgb::BLACK] }
    }

    /// `toolbarGrounds`: the background at the window's opacity over each desktop.
    pub fn toolbar_grounds(&self) -> Vec<Rgb> {
        self.desktops()
            .into_iter()
            .map(|d| self.background.with_alpha(self.window_opacity).composited(d))
            .collect()
    }

    /// `glassFrost(isDark:)`: the glass's own frost (toward, step).
    pub fn glass_frost(is_dark: bool) -> (Rgb, f64) {
        if is_dark { (Rgb::BLACK, 0.30) } else { (Rgb::WHITE, 0.35) }
    }

    /// `inkGrounds(_:)`: every opaque ground the bar shows its ink on with `backing`, the card first.
    pub fn ink_grounds(&self, backing: &Backing) -> Vec<Rgb> {
        let mut grounds = vec![self.card()];
        match backing {
            Backing::Flat { coverage } => {
                let coverage = self.resolved_coverage(*coverage);
                for state in BarState::ALL {
                    let fill = self.layered(self.readable_step(state), coverage);
                    grounds.extend(self.toolbar_grounds().iter().map(|g| fill.composited(*g)));
                }
            }
            Backing::Clear { hover } => {
                let toolbar = self.toolbar_grounds();
                grounds.extend(toolbar.iter().copied());
                grounds.extend(toolbar.iter().map(|g| hover.composited(*g)));
            }
            Backing::Glass { tints, hover } => {
                let (toward, step) = Self::glass_frost(self.is_dark);
                let none = [None];
                let tints: &[Option<Rgb>] = if tints.is_empty() { &none } else { tints };
                for ground in self.toolbar_grounds() {
                    let frosted = ground.mixed(toward, step);
                    for tint in tints {
                        let glass = tint.map(|t| t.composited(frosted)).unwrap_or(frosted);
                        grounds.push(glass);
                        grounds.push(hover.composited(glass));
                    }
                }
            }
        }
        grounds
    }

    /// `ink(_:secondaryText:)`: the bar's ink with `backing`.
    pub fn ink(&self, backing: &Backing, secondary_text: Rgb) -> OmnibarInk {
        OmnibarInk::new(
            self.text,
            secondary_text,
            &self.ink_grounds(backing),
            MINIMUM_TEXT_CONTRAST,
        )
    }
}

/// `Palette.omnibarInk`'s backing: glass over the tints, else clear (transparent), else flat.
pub fn backing_for(
    glass: bool,
    transparent: bool,
    glass_tints: Vec<Option<Rgb>>,
    hover_fill: Rgb,
    coverage: f64,
) -> Backing {
    if glass {
        Backing::Glass { tints: glass_tints, hover: hover_fill }
    } else if transparent {
        Backing::Clear { hover: hover_fill }
    } else {
        Backing::Flat { coverage }
    }
}

// MARK: JSON

fn min_default() -> f64 {
    MINIMUM_TEXT_CONTRAST
}

fn yes() -> bool {
    true
}

fn colors(v: &[Color]) -> Vec<Rgb> {
    v.iter().map(|c| Rgb::from(*c)).collect()
}

/// An ink on the wire.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InkWire {
    /// [`OmnibarInk::primary`].
    pub primary: Color,
    /// [`OmnibarInk::secondary`].
    pub secondary: Color,
    /// [`OmnibarInk::icon`].
    pub icon: Color,
    /// [`OmnibarInk::grounds`].
    pub grounds: Vec<Color>,
}

impl From<&OmnibarInk> for InkWire {
    fn from(i: &OmnibarInk) -> Self {
        InkWire {
            primary: i.primary.into(),
            secondary: i.secondary.into(),
            icon: i.icon.into(),
            grounds: i.grounds.iter().map(|g| Color::from(*g)).collect(),
        }
    }
}

impl From<&InkWire> for OmnibarInk {
    fn from(w: &InkWire) -> Self {
        OmnibarInk {
            primary: w.primary.into(),
            secondary: w.secondary.into(),
            icon: w.icon.into(),
            grounds: colors(&w.grounds),
        }
    }
}

/// A surface on the wire.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SurfaceWire {
    /// `ThemeTokens.surfaceBackground`.
    pub background: Color,
    /// `ThemeTokens.textPrimary`.
    pub text: Color,
    /// `ThemeTokens.isDark`.
    pub is_dark: bool,
    /// The window's tint opacity.
    pub window_opacity: f64,
}

impl From<SurfaceWire> for AddressBarSurface {
    fn from(s: SurfaceWire) -> Self {
        AddressBarSurface::new(s.background.into(), s.text.into(), s.is_dark, s.window_opacity)
    }
}

/// A backing on the wire: `{"kind":"flat","coverage":..}`, `{"kind":"clear","hover":..}`,
/// `{"kind":"glass","tints":[..|null],"hover":..}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum BackingWire {
    /// [`Backing::Flat`].
    Flat {
        /// The coverage.
        coverage: f64,
    },
    /// [`Backing::Clear`].
    Clear {
        /// The hover fill.
        hover: Color,
    },
    /// [`Backing::Glass`].
    Glass {
        /// The tints.
        tints: Vec<Option<Color>>,
        /// The hover fill.
        hover: Color,
    },
}

impl From<&BackingWire> for Backing {
    fn from(b: &BackingWire) -> Self {
        match b {
            BackingWire::Flat { coverage } => Backing::Flat { coverage: *coverage },
            BackingWire::Clear { hover } => Backing::Clear { hover: (*hover).into() },
            BackingWire::Glass { tints, hover } => Backing::Glass {
                tints: tints.iter().map(|t| t.map(Rgb::from)).collect(),
                hover: (*hover).into(),
            },
        }
    }
}

impl From<&Backing> for BackingWire {
    fn from(b: &Backing) -> Self {
        match b {
            Backing::Flat { coverage } => BackingWire::Flat { coverage: *coverage },
            Backing::Clear { hover } => BackingWire::Clear { hover: (*hover).into() },
            Backing::Glass { tints, hover } => BackingWire::Glass {
                tints: tints.iter().map(|t| t.map(Color::from)).collect(),
                hover: (*hover).into(),
            },
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewRequest {
    text: Color,
    secondary_text: Color,
    grounds: Vec<Color>,
    #[serde(default = "min_default")]
    minimum: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IconOnRequest {
    ink: InkWire,
    plates: Vec<Color>,
    #[serde(default = "yes")]
    bare: bool,
    #[serde(default = "min_default")]
    minimum: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorstRequest {
    ink: Color,
    grounds: Vec<Color>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadsRequest {
    grounds: Vec<Color>,
    color: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroundsRequest {
    surface: SurfaceWire,
    backing: BackingWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ForSurfaceRequest {
    surface: SurfaceWire,
    backing: BackingWire,
    secondary_text: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceRequest {
    surface: SurfaceWire,
    #[serde(default)]
    coverage: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceReply {
    rest_step: f64,
    hover_step: f64,
    resolved_coverage: f64,
    rest_fill: Color,
    hover_fill: Color,
    card: Color,
    row_selected: Color,
    desktops: Vec<Color>,
    toolbar_grounds: Vec<Color>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackingRequest {
    #[serde(default)]
    glass: bool,
    #[serde(default)]
    transparent: bool,
    #[serde(default)]
    glass_tints: Vec<Option<Color>>,
    hover_fill: Color,
    #[serde(default)]
    coverage: f64,
}

/// Runs the `tokens.omnibar_ink_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        // {text, secondaryText, grounds, minimum?} -> {primary, secondary, icon, grounds}
        "omnibar_ink_new" => {
            let r: NewRequest = parse(request)?;
            let ink = OmnibarInk::new(
                r.text.into(),
                r.secondary_text.into(),
                &colors(&r.grounds),
                r.minimum,
            );
            reply(&InkWire::from(&ink))
        }
        // {ink, plates, bare?, minimum?} -> colour
        "omnibar_ink_icon_on" => {
            let r: IconOnRequest = parse(request)?;
            let ink = OmnibarInk::from(&r.ink);
            reply(&Color::from(ink.icon_on(&colors(&r.plates), r.bare, r.minimum)))
        }
        "omnibar_ink_worst_contrast" => {
            let r: WorstRequest = parse(request)?;
            reply(&worst_contrast(r.ink.into(), &colors(&r.grounds)))
        }
        "omnibar_ink_reads" => {
            let r: ReadsRequest = parse(request)?;
            reply(&(worst_contrast(r.color.into(), &colors(&r.grounds)) >= MINIMUM_TEXT_CONTRAST))
        }
        "omnibar_ink_grounds" => {
            let r: GroundsRequest = parse(request)?;
            let surface = AddressBarSurface::from(r.surface);
            let grounds = surface.ink_grounds(&Backing::from(&r.backing));
            reply(&grounds.into_iter().map(Color::from).collect::<Vec<_>>())
        }
        "omnibar_ink_for_surface" => {
            let r: ForSurfaceRequest = parse(request)?;
            let surface = AddressBarSurface::from(r.surface);
            let ink = surface.ink(&Backing::from(&r.backing), r.secondary_text.into());
            reply(&InkWire::from(&ink))
        }
        "omnibar_ink_surface" => {
            let r: SurfaceRequest = parse(request)?;
            let s = AddressBarSurface::from(r.surface);
            let col = |v: Vec<Rgb>| v.into_iter().map(Color::from).collect::<Vec<_>>();
            reply(&SurfaceReply {
                rest_step: s.readable_step(BarState::Rest),
                hover_step: s.readable_step(BarState::Hover),
                resolved_coverage: s.resolved_coverage(r.coverage),
                rest_fill: s.fill(BarState::Rest, r.coverage).into(),
                hover_fill: s.fill(BarState::Hover, r.coverage).into(),
                card: s.card().into(),
                row_selected: s.row_selected().into(),
                desktops: col(s.desktops()),
                toolbar_grounds: col(s.toolbar_grounds()),
            })
        }
        "omnibar_ink_backing" => {
            let r: BackingRequest = parse(request)?;
            let b = backing_for(
                r.glass,
                r.transparent,
                r.glass_tints.iter().map(|t| t.map(Rgb::from)).collect(),
                r.hover_fill.into(),
                r.coverage,
            );
            reply(&BackingWire::from(&b))
        }
        _ => Err(OpError::Unknown),
    }
}
