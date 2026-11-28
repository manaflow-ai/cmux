//! Theme rules of CmuxNextDesign (`Packages/macOS/CmuxNext/Sources/CmuxNextDesign/`):
//! `Themes/StatusDotHue.swift`, `Themes/ThemeTokens+StatusDotHue.swift` ([`status_dot`]),
//! `Themes/ThemeTokens+MenuHighlight.swift`, `Themes/ThemeTokens+SpinnerInk.swift`,
//! `ThemeTokens+GroupFill.swift` ([`fills`]), `FloatingGlass/Palette+GlassText.swift`
//! ([`glass_text`]), `Themes/ThemeSwatch.swift` ([`swatch`]), `Themes/ThemeElement.swift`,
//! `ThemeElementGround.swift`, `ThemeElementSample.swift`, `ThemeElementAudit.swift` and the pure
//! parts of `Themes/Playground/AllThemesPlayground{Entry,Model,Strings}.swift` ([`audit`]).
//!
//! Ops (`tokens.themes_*`) take the theme as [`WireTokens`]: the terminal colours it derives
//! from (Ghostty's defaults for what is left out), then any token set outright.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use cmux_theme_tokens::{GHOSTTY_DEFAULT_PALETTE, ThemeInput, ThemeTokens};
use serde::Deserialize;
use serde_json::{Value, json};

pub mod audit;
pub mod fills;
pub mod glass_text;
pub mod status_dot;
pub mod swatch;

use audit::{AuditColors, PlaygroundEntry, ThemeElement, ThemeElementGround, ThemeElementSample};
use glass_text::{ThemeInk, Veil};
use status_dot::StatusDotHue;

/// A theme on the wire: what `ThemeTokens::derive` reads (each optional, Ghostty's default
/// otherwise; `palette` is padded with the default entries), then tokens set outright.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
#[allow(missing_docs)]
pub struct WireTokens {
    pub background: Option<Color>,
    pub foreground: Option<Color>,
    pub palette: Option<Vec<Color>>,
    pub selection_background: Option<Color>,
    pub selection_foreground: Option<Color>,
    pub is_dark: Option<bool>,
    pub window_background: Option<Color>,
    pub text_primary: Option<Color>,
    pub text_secondary: Option<Color>,
    pub text_tertiary: Option<Color>,
    pub hover_fill: Option<Color>,
    pub selection_fill: Option<Color>,
    pub pressed_fill: Option<Color>,
    pub separator: Option<Color>,
    pub glass_tint: Option<Color>,
    pub attention: Option<Color>,
    pub danger: Option<Color>,
    pub accent: Option<Color>,
}

impl WireTokens {
    /// The derived tokens with the overrides applied.
    pub fn tokens(&self) -> ThemeTokens {
        let mut input = ThemeInput::GHOSTTY_DEFAULT;
        if let Some(c) = self.background {
            input.background = c.into();
        }
        if let Some(c) = self.foreground {
            input.foreground = c.into();
        }
        if let Some(p) = &self.palette {
            let mut palette = GHOSTTY_DEFAULT_PALETTE;
            for (slot, c) in palette.iter_mut().zip(p) {
                *slot = (*c).into();
            }
            input.palette = palette;
        }
        input.selection_background = self.selection_background.map(Rgb::from);
        input.selection_foreground = self.selection_foreground.map(Rgb::from);
        let mut t = ThemeTokens::derive(&input);
        if let Some(d) = self.is_dark {
            t.is_dark = d;
        }
        let set = |slot: &mut Rgb, c: Option<Color>| {
            if let Some(c) = c {
                *slot = c.into();
            }
        };
        set(&mut t.window_background, self.window_background);
        set(&mut t.text_primary, self.text_primary);
        set(&mut t.text_secondary, self.text_secondary);
        set(&mut t.text_tertiary, self.text_tertiary);
        set(&mut t.hover_fill, self.hover_fill);
        set(&mut t.selection_fill, self.selection_fill);
        set(&mut t.pressed_fill, self.pressed_fill);
        set(&mut t.separator, self.separator);
        set(&mut t.glass_tint, self.glass_tint);
        set(&mut t.attention, self.attention);
        set(&mut t.danger, self.danger);
        set(&mut t.accent, self.accent);
        t
    }
}

fn lift_default() -> f64 {
    fills::DEFAULT_OPAQUE_OVERLAY_LIFT
}

fn dialog_minimum() -> f64 {
    glass_text::DIALOG_MINIMUM_CONTRAST
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThemeRequest {
    #[serde(default)]
    tokens: WireTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HueRequest {
    mark: StatusDotHue,
    is_dark: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DotRequest {
    #[serde(default)]
    tokens: WireTokens,
    mark: StatusDotHue,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadableDotRequest {
    color: Color,
    surfaces: Vec<Color>,
    pole: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroundRequest {
    #[serde(default)]
    tokens: WireTokens,
    ground: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LiftRequest {
    #[serde(default)]
    tokens: WireTokens,
    #[serde(default = "lift_default")]
    lift: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StrokeForRequest {
    #[serde(default)]
    tokens: WireTokens,
    fill: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VeilRequest {
    veil: Veil,
    #[serde(default)]
    takes_theme_tint: bool,
    glass_tint: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FitRequest {
    ink: Color,
    surfaces: Vec<Color>,
    #[serde(default = "dialog_minimum")]
    minimum: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToastRequest {
    #[serde(default)]
    tokens: WireTokens,
    #[serde(default = "primary")]
    ink: ThemeInk,
    #[serde(default)]
    reduce_transparency: bool,
    #[serde(default = "lift_default")]
    lift: f64,
    veil: Veil,
    #[serde(default)]
    veil_takes_theme_tint: bool,
}

fn primary() -> ThemeInk {
    ThemeInk::Primary
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CardTextRequest {
    #[serde(default)]
    tokens: WireTokens,
    ink: ThemeInk,
    surfaces: Vec<Color>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntriesRequest {
    entries: Vec<PlaygroundEntry>,
    #[serde(default)]
    query: String,
    #[serde(default)]
    failures_only: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FoldersRequest {
    folders: Vec<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SummaryRequest {
    failing: i64,
    total: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SampleRequest {
    sample: ThemeElementSample,
}

fn colors(cs: &[Color]) -> Vec<Rgb> {
    cs.iter().copied().map(Rgb::from).collect()
}

fn color(c: Rgb) -> Color {
    c.into()
}

fn sample_json(s: &ThemeElementSample) -> Value {
    json!({
        "element": s.element,
        "ground": s.ground,
        "ink": s.ink,
        "surface": s.surface,
        "minimum": s.minimum,
        "followsSystemAppearance": s.follows_system_appearance,
        "contrast": s.contrast(),
        "passes": s.passes(),
    })
}

/// Runs `tokens.themes_*`; any other name is [`OpError::Unknown`].
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "themes_status_dot_hue" => {
            let r: HueRequest = parse(request)?;
            reply(&color(r.mark.hue(r.is_dark)))
        }
        "themes_status_dot" => {
            let r: DotRequest = parse(request)?;
            reply(&color(status_dot::status_dot(&r.tokens.tokens(), r.mark)))
        }
        "themes_status_dot_rows" => {
            let r: ThemeRequest = parse(request)?;
            let rows = status_dot::status_dot_rows(&r.tokens.tokens());
            reply(&rows.map(color))
        }
        "themes_readable_dot" => {
            let r: ReadableDotRequest = parse(request)?;
            reply(&color(status_dot::readable_dot(
                r.color.into(),
                &colors(&r.surfaces),
                r.pole.into(),
            )))
        }
        "themes_menu_highlight_share" => {
            let r: GroundRequest = parse(request)?;
            reply(&fills::menu_highlight_share(&r.tokens.tokens(), r.ground.into()))
        }
        "themes_spinner_ink" => {
            let r: ThemeRequest = parse(request)?;
            reply(&color(fills::spinner_ink(&r.tokens.tokens())))
        }
        "themes_group_fill_target" => {
            let r: ThemeRequest = parse(request)?;
            reply(&fills::group_fill_target(r.tokens.tokens().is_dark))
        }
        "themes_group_fill_on" => {
            let r: GroundRequest = parse(request)?;
            reply(&color(fills::group_fill_on(&r.tokens.tokens(), r.ground.into())))
        }
        "themes_group_fill" => {
            let r: LiftRequest = parse(request)?;
            let t = r.tokens.tokens();
            let fill = fills::group_fill(&t, r.lift);
            Ok(json!({ "fill": color(fill), "stroke": color(fills::group_stroke_for(&t, fill)) }))
        }
        "themes_group_stroke_for" => {
            let r: StrokeForRequest = parse(request)?;
            reply(&color(fills::group_stroke_for(&r.tokens.tokens(), r.fill.into())))
        }
        "themes_veil_rgb" => {
            let r: VeilRequest = parse(request)?;
            reply(&color(glass_text::veil_rgb(r.veil, r.takes_theme_tint, r.glass_tint.into())))
        }
        "themes_fit_readable" => {
            let r: FitRequest = parse(request)?;
            reply(&color(glass_text::fit_readable(r.ink.into(), &colors(&r.surfaces), r.minimum)))
        }
        "themes_toast_text" => {
            let r: ToastRequest = parse(request)?;
            let t = r.tokens.tokens();
            let args = (r.reduce_transparency, r.lift, r.veil, r.veil_takes_theme_tint);
            Ok(json!({
                "ground": color(glass_text::toast_ground(&t, args.0, args.1, args.2, args.3)),
                "text": color(glass_text::toast_text(&t, r.ink, args.0, args.1, args.2, args.3)),
                "inkTitle": color(glass_text::toast_ink_title(&t, args.0, args.1, args.2, args.3)),
            }))
        }
        "themes_card_text" => {
            let r: CardTextRequest = parse(request)?;
            reply(&color(glass_text::card_text(&r.tokens.tokens(), r.ink, &colors(&r.surfaces))))
        }
        "themes_css_hex" => {
            let r: TextRequest = parse(request)?;
            reply(&swatch::css_hex(&r.text).map(color))
        }
        "themes_swatch_strip" => {
            let r: TextRequest = parse(request)?;
            reply(&swatch::strip(&r.text).into_iter().map(color).collect::<Vec<_>>())
        }
        "themes_element_table" => Ok(json!({
            "elements": ThemeElement::ALL.iter().map(|e| json!({
                "element": e, "titleKey": e.title_key(), "title": e.title(),
            })).collect::<Vec<_>>(),
            "grounds": ThemeElementGround::ALL.iter().map(|g| json!({
                "ground": g, "titleKey": g.title_key(), "title": g.title(),
            })).collect::<Vec<_>>(),
        })),
        "themes_audit" => {
            let r: AuditColors = parse(request)?;
            let samples = audit::audit_samples(&r);
            Ok(json!({
                "samples": samples.iter().map(sample_json).collect::<Vec<_>>(),
                "failing": samples.iter().filter(|s| !s.passes()).count(),
            }))
        }
        "themes_sample" => {
            let r: SampleRequest = parse(request)?;
            let s = r.sample;
            Ok(json!({
                "contrast": s.contrast(),
                "passes": s.passes(),
                "help": audit::playground_sample_help(&s),
            }))
        }
        "themes_playground_shown" => {
            let r: EntriesRequest = parse(request)?;
            Ok(json!({
                "shown": audit::playground_shown(&r.entries, &r.query, r.failures_only),
                "failingCount": audit::playground_failing_count(&r.entries),
            }))
        }
        "themes_playground_sorted" => {
            let r: EntriesRequest = parse(request)?;
            let names: Vec<String> =
                audit::playground_sorted(r.entries).into_iter().map(|e| e.name).collect();
            reply(&names)
        }
        "themes_playground_files" => {
            let r: FoldersRequest = parse(request)?;
            let files = audit::playground_files(&r.folders);
            reply(&files.iter().map(|(n, i)| json!({ "name": n, "folder": i })).collect::<Vec<_>>())
        }
        "themes_playground_strings" => {
            let r: SummaryRequest = parse(request)?;
            let mut fixed = serde_json::Map::new();
            for (key, value) in audit::PLAYGROUND_STRINGS {
                fixed.insert(key.to_string(), json!(value));
            }
            Ok(json!({
                "fixed": fixed,
                "summary": audit::playground_summary(r.failing, r.total),
                "failing": audit::playground_failing(r.failing),
            }))
        }
        _ => Err(OpError::Unknown),
    }
}
