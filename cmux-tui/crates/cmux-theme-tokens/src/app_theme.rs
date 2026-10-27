//! `AppTheme`: cmux's app tokens derived from a terminal palette, and the
//! accent `appearance.accent` gives the chrome (port of cmux-next
//! `AppTheme.swift` and `ThemeAccent.swift`, CmuxTheme package on
//! `feat-cmux-next`; the Swift is a line-for-line port of the web module
//! `webviews/src/theme/appTheme.ts` and `color.ts`). Every token is opaque.
//! Each pair in the contract meets its WCAG 2 minimum (4.5:1 text, 3:1 UI
//! marks); OKLCH lightness moves keep a color's hue. `ThemeTokens::derive`
//! reads the accent and onAccent from here when the accent is not neutral or
//! the theme has its own accent color.

use crate::Rgb;

/// Where the chrome's accent comes from (`appearance.accent`; Swift
/// `ThemeAccent`). `Neutral` (the default) is the foreground without hue;
/// `Theme` is the palette's signature hue (magenta, else blue, else cyan,
/// else neutral); a color name is that ANSI slot (the more colorful of its
/// normal and bright variants).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum ThemeAccent {
    #[default]
    Neutral,
    Theme,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
}

impl ThemeAccent {
    /// Every value, in the schema's order.
    pub const ALL: [ThemeAccent; 8] = [
        Self::Neutral,
        Self::Theme,
        Self::Red,
        Self::Green,
        Self::Yellow,
        Self::Blue,
        Self::Magenta,
        Self::Cyan,
    ];

    /// The cmux.json value (`"neutral"`, `"red"`, ...).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::Theme => "theme",
            Self::Red => "red",
            Self::Green => "green",
            Self::Yellow => "yellow",
            Self::Blue => "blue",
            Self::Magenta => "magenta",
            Self::Cyan => "cyan",
        }
    }

    /// The value of a cmux.json string; None for anything else (Swift
    /// `AccentSetting.parse` then uses neutral with a diagnostic).
    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.as_str() == value)
    }

    /// The (normal, bright) ANSI pair of a named accent.
    fn hue(self, hues: &Hues) -> Option<(Rgb, Rgb)> {
        match self {
            Self::Neutral | Self::Theme => None,
            Self::Red => Some(hues.red),
            Self::Green => Some(hues.green),
            Self::Yellow => Some(hues.yellow),
            Self::Blue => Some(hues.blue),
            Self::Magenta => Some(hues.magenta),
            Self::Cyan => Some(hues.cyan),
        }
    }
}

/// The six ANSI hues of a palette, each as its (normal, bright) pair: slots
/// 1..=6 and their bright variants 9..=14.
struct Hues {
    red: (Rgb, Rgb),
    green: (Rgb, Rgb),
    yellow: (Rgb, Rgb),
    blue: (Rgb, Rgb),
    magenta: (Rgb, Rgb),
    cyan: (Rgb, Rgb),
}

impl Hues {
    fn of(palette: &[Rgb; 16]) -> Self {
        let [
            _,
            red,
            green,
            yellow,
            blue,
            magenta,
            cyan,
            _,
            _,
            bright_red,
            bright_green,
            bright_yellow,
            bright_blue,
            bright_magenta,
            bright_cyan,
            _,
        ] = *palette;
        Self {
            red: (red, bright_red),
            green: (green, bright_green),
            yellow: (yellow, bright_yellow),
            blue: (blue, bright_blue),
            magenta: (magenta, bright_magenta),
            cyan: (cyan, bright_cyan),
        }
    }
}

/// One token of the app theme contract (Swift `AppTheme.Token`, in its
/// order).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AppToken {
    Window,
    Sidebar,
    Content,
    Elevated,
    Control,
    Hover,
    Pressed,
    Selection,
    Separator,
    ControlStroke,
    Text,
    TextSecondary,
    Icon,
    Accent,
    OnAccent,
    AccentText,
    FocusRing,
    Danger,
    Warning,
    Success,
}

impl AppToken {
    /// Every token, in the contract's order.
    pub const ALL: [AppToken; 20] = [
        Self::Window,
        Self::Sidebar,
        Self::Content,
        Self::Elevated,
        Self::Control,
        Self::Hover,
        Self::Pressed,
        Self::Selection,
        Self::Separator,
        Self::ControlStroke,
        Self::Text,
        Self::TextSecondary,
        Self::Icon,
        Self::Accent,
        Self::OnAccent,
        Self::AccentText,
        Self::FocusRing,
        Self::Danger,
        Self::Warning,
        Self::Success,
    ];

    /// The CSS custom property web pages read (`--cmux-app-*`).
    pub fn variable(self) -> &'static str {
        match self {
            Self::Window => "--cmux-app-window",
            Self::Sidebar => "--cmux-app-sidebar",
            Self::Content => "--cmux-app-content",
            Self::Elevated => "--cmux-app-elevated",
            Self::Control => "--cmux-app-control",
            Self::Hover => "--cmux-app-hover",
            Self::Pressed => "--cmux-app-pressed",
            Self::Selection => "--cmux-app-selection",
            Self::Separator => "--cmux-app-separator",
            Self::ControlStroke => "--cmux-app-control-stroke",
            Self::Text => "--cmux-app-text",
            Self::TextSecondary => "--cmux-app-text-secondary",
            Self::Icon => "--cmux-app-icon",
            Self::Accent => "--cmux-app-accent",
            Self::OnAccent => "--cmux-app-on-accent",
            Self::AccentText => "--cmux-app-accent-text",
            Self::FocusRing => "--cmux-app-focus-ring",
            Self::Danger => "--cmux-app-danger",
            Self::Warning => "--cmux-app-warning",
            Self::Success => "--cmux-app-success",
        }
    }
}

/// The app theme of a terminal palette (Swift `AppTheme`).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AppTheme {
    /// The palette is dark (its background darker than its foreground).
    pub is_dark: bool,
    /// Every token, opaque, indexed by `AppToken as usize`.
    pub tokens: [Rgb; 20],
}

const TEXT_MINIMUM: f64 = 4.5;
const UI_MINIMUM: f64 = 3.0;
/// A slot reads as a hue (not a gray) at this OKLCH chroma or more.
const HUED_CHROMA: f64 = 0.05;
/// Surface tint strengths, tried in order until every pair passes.
const TINT_SCALES: [f64; 6] = [1.0, 0.7, 0.45, 0.25, 0.1, 0.0];

use AppToken as T;

// Every token has a slot in a 20-entry table: fieldless discriminants run 0.. in
// declaration order, and `Success` is the last of the 20.
const _: () = assert!(AppToken::ALL.len() == 20 && AppToken::Success as usize == 19);

/// The table entry of `token`.
#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: AppToken discriminants are 0..20 (asserted at build time above) and a token table has 20 entries"
)]
fn slot(table: &[Rgb; 20], token: AppToken) -> &Rgb {
    &table[token as usize]
}

/// [`slot`], mutable.
#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: AppToken discriminants are 0..20 (asserted at build time above) and a token table has 20 entries"
)]
fn slot_mut(table: &mut [Rgb; 20], token: AppToken) -> &mut Rgb {
    &mut table[token as usize]
}
const PLAIN_SURFACES: [AppToken; 4] = [T::Window, T::Sidebar, T::Content, T::Elevated];
const TEXT_SURFACES: [AppToken; 8] = [
    T::Window,
    T::Sidebar,
    T::Content,
    T::Elevated,
    T::Control,
    T::Hover,
    T::Pressed,
    T::Selection,
];
const STATUS_SURFACES: [AppToken; 5] = [T::Window, T::Sidebar, T::Content, T::Elevated, T::Hover];

impl AppTheme {
    /// The token's color.
    pub fn get(&self, token: AppToken) -> Rgb {
        *slot(&self.tokens, token)
    }

    /// Every pair the tokens are used in: (token, on, minimum) (Swift
    /// `AppTheme.contract`).
    pub fn contract() -> Vec<(AppToken, AppToken, f64)> {
        let mut pairs = Vec::new();
        let mut add = |token: AppToken, on: &[AppToken], minimum: f64| {
            pairs.extend(on.iter().map(|o| (token, *o, minimum)));
        };
        add(T::Text, &TEXT_SURFACES, TEXT_MINIMUM);
        add(T::TextSecondary, &TEXT_SURFACES, TEXT_MINIMUM);
        add(T::Icon, &TEXT_SURFACES, UI_MINIMUM);
        add(
            T::ControlStroke,
            &[T::Window, T::Sidebar, T::Content, T::Elevated, T::Control],
            UI_MINIMUM,
        );
        add(T::Accent, &PLAIN_SURFACES, UI_MINIMUM);
        add(T::FocusRing, &PLAIN_SURFACES, UI_MINIMUM);
        add(T::OnAccent, &[T::Accent], TEXT_MINIMUM);
        add(
            T::AccentText,
            &[T::Window, T::Sidebar, T::Content, T::Elevated, T::Hover, T::Selection],
            TEXT_MINIMUM,
        );
        add(T::Danger, &STATUS_SURFACES, TEXT_MINIMUM);
        add(T::Warning, &STATUS_SURFACES, TEXT_MINIMUM);
        add(T::Success, &STATUS_SURFACES, TEXT_MINIMUM);
        pairs
    }

    /// Whether any contract pair is below its minimum.
    fn fails(&self) -> bool {
        Self::contract()
            .into_iter()
            .any(|(token, on, minimum)| contrast(self.get(token), self.get(on)) < minimum)
    }

    /// The tokens of a terminal palette (alpha ignored) with `accent`. Every
    /// contract pair meets its minimum. `accent_color` is the theme's own
    /// accent (a `<theme>/accent` edit or the theme file's `# cmux-accent`):
    /// when set it is the accent's starting color, whatever `accent` says.
    pub fn derive(
        background: Rgb,
        foreground: Rgb,
        palette: &[Rgb; 16],
        accent: ThemeAccent,
        accent_color: Option<Rgb>,
    ) -> Self {
        let (bg, fg) = (background.with_alpha(1.0), foreground.with_alpha(1.0));
        let palette = palette.map(|c| c.with_alpha(1.0));
        let source = accent_color.map(|c| c.with_alpha(1.0));
        let [first_scale, weaker_scales @ ..] = TINT_SCALES;
        let mut theme = derive_at(bg, fg, &palette, accent, source, first_scale);
        for scale in weaker_scales {
            if !theme.fails() {
                break;
            }
            theme = derive_at(bg, fg, &palette, accent, source, scale);
        }
        theme
    }
}

/// The more colorful of a normal and a bright slot.
fn colorful((normal, bright): (Rgb, Rgb)) -> Rgb {
    if oklch(bright).c > oklch(normal).c + 0.02 { bright } else { normal }
}

/// The accent's starting color (Swift `AppTheme.accentSeed`): the theme's
/// own color when it has one, else the named accent.
fn accent_seed(accent: ThemeAccent, color: Option<Rgb>, fg: Rgb, palette: &[Rgb; 16]) -> Rgb {
    if let Some(color) = color {
        return color;
    }
    let neutral = from_oklch(Oklch { l: oklch(fg).l, c: 0.0, h: 0.0 });
    let hues = Hues::of(palette);
    if let Some(hue) = accent.hue(&hues) {
        return colorful(hue);
    }
    if accent != ThemeAccent::Theme {
        return neutral;
    }
    for hue in [hues.magenta, hues.blue, hues.cyan] {
        let color = colorful(hue);
        if oklch(color).c >= HUED_CHROMA {
            return color;
        }
    }
    neutral
}

fn derive_at(
    bg: Rgb,
    fg: Rgb,
    palette: &[Rgb; 16],
    accent: ThemeAccent,
    accent_color: Option<Rgb>,
    tint: f64,
) -> AppTheme {
    let is_dark = luminance(bg) < luminance(fg);
    let hues = Hues::of(palette);
    let dark = |d: f64, l: f64| if is_dark { d } else { l };
    let q = quantized;
    let mut t = [Rgb::BLACK; 20];
    let window = q(bg);
    *slot_mut(&mut t, T::Window) = window;
    *slot_mut(&mut t, T::Content) = q(bg);
    *slot_mut(&mut t, T::Sidebar) = q(bg.mixed(fg, dark(0.04, 0.035) * tint));
    *slot_mut(&mut t, T::Elevated) =
        q(if is_dark { bg.mixed(fg, 0.075 * tint) } else { bg.mixed(Rgb::WHITE, 0.7 * tint) });
    *slot_mut(&mut t, T::Control) = q(bg.mixed(fg, dark(0.1, 0.065) * tint));
    *slot_mut(&mut t, T::Hover) = q(bg.mixed(fg, dark(0.06, 0.045) * tint));
    *slot_mut(&mut t, T::Pressed) = q(bg.mixed(fg, dark(0.12, 0.09) * tint));
    *slot_mut(&mut t, T::Separator) = q(bg.mixed(fg, dark(0.13, 0.11)));
    let on = |t: &[Rgb; 20], names: &[AppToken], minimum: f64| -> Vec<Constraint> {
        names.iter().map(|n| Constraint { on: *slot(t, *n), minimum }).collect()
    };
    let (lighter, darker) = (Some(Direction::Lighter), Some(Direction::Darker));
    let away = if is_dark { lighter } else { darker };

    let on_accent_wanted = if is_dark { window } else { Rgb::WHITE };
    let mut accent_on = on(&t, &PLAIN_SURFACES, UI_MINIMUM);
    accent_on.push(Constraint { on: on_accent_wanted, minimum: TEXT_MINIMUM });
    let accent = fit(accent_seed(accent, accent_color, fg, palette), &accent_on, away);
    *slot_mut(&mut t, T::Accent) = accent;
    *slot_mut(&mut t, T::FocusRing) = accent;
    let on_accent_rule = [Constraint { on: accent, minimum: TEXT_MINIMUM }];
    *slot_mut(&mut t, T::OnAccent) = if meets(on_accent_wanted, &on_accent_rule) {
        on_accent_wanted
    } else {
        fit(if is_dark { Rgb::BLACK } else { Rgb::WHITE }, &on_accent_rule, None)
    };
    *slot_mut(&mut t, T::Selection) = q(bg.mixed(accent, dark(0.26, 0.16) * tint));

    let text = fit(fg, &on(&t, &TEXT_SURFACES, TEXT_MINIMUM), None);
    *slot_mut(&mut t, T::Text) = text;
    *slot_mut(&mut t, T::TextSecondary) =
        fit(text.mixed(bg, 0.34), &on(&t, &TEXT_SURFACES, TEXT_MINIMUM), away);
    *slot_mut(&mut t, T::Icon) =
        fit(text.mixed(bg, 0.3), &on(&t, &TEXT_SURFACES, UI_MINIMUM), away);
    *slot_mut(&mut t, T::ControlStroke) = fit(
        bg.mixed(fg, 0.42),
        &on(&t, &[T::Window, T::Sidebar, T::Content, T::Elevated, T::Control], UI_MINIMUM),
        away,
    );
    let status_and_selection =
        [T::Window, T::Sidebar, T::Content, T::Elevated, T::Hover, T::Selection];
    *slot_mut(&mut t, T::AccentText) =
        fit(accent, &on(&t, &status_and_selection, TEXT_MINIMUM), away);
    *slot_mut(&mut t, T::Danger) =
        fit(colorful(hues.red), &on(&t, &STATUS_SURFACES, TEXT_MINIMUM), away);
    *slot_mut(&mut t, T::Warning) =
        fit(colorful(hues.yellow), &on(&t, &STATUS_SURFACES, TEXT_MINIMUM), away);
    *slot_mut(&mut t, T::Success) =
        fit(colorful(hues.green), &on(&t, &STATUS_SURFACES, TEXT_MINIMUM), away);
    AppTheme { is_dark, tokens: t }
}

// The color math (Swift `AppColor`, the web `color.ts`).

#[derive(Clone, Copy)]
struct Oklch {
    l: f64,
    c: f64,
    h: f64,
}

#[derive(Clone, Copy)]
struct Constraint {
    on: Rgb,
    minimum: f64,
}

#[derive(Clone, Copy, PartialEq)]
enum Direction {
    Lighter,
    Darker,
}

fn byte(v: f64) -> f64 {
    (v.clamp(0.0, 1.0) * 255.0).round()
}

/// The color as its 8-bit hex rounds it (opaque).
fn quantized(c: Rgb) -> Rgb {
    Rgb::new(byte(c.r) / 255.0, byte(c.g) / 255.0, byte(c.b) / 255.0, 1.0)
}

fn linear(c: f64) -> f64 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn gamma(c: f64) -> f64 {
    if c <= 0.0031308 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

fn luminance(c: Rgb) -> f64 {
    0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
}

fn contrast(a: Rgb, b: Rgb) -> f64 {
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

fn oklch(c: Rgb) -> Oklch {
    let (r, g, b) = (linear(c.r), linear(c.g), linear(c.b));
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    let lightness = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
    let a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
    let bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
    let hue = bb.atan2(a) * 180.0 / std::f64::consts::PI;
    Oklch { l: lightness, c: a.hypot(bb), h: if hue < 0.0 { hue + 360.0 } else { hue } }
}

fn to_linear(v: Oklch) -> (f64, f64, f64) {
    let radians = v.h * std::f64::consts::PI / 180.0;
    let (a, b) = (v.c * radians.cos(), v.c * radians.sin());
    let l = (v.l + 0.3963377774 * a + 0.2158037573 * b).powf(3.0);
    let m = (v.l - 0.1055613458 * a - 0.0638541728 * b).powf(3.0);
    let s = (v.l - 0.0894841775 * a - 1.291485548 * b).powf(3.0);
    (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
    )
}

fn in_gamut((r, g, b): (f64, f64, f64)) -> bool {
    [r, g, b].iter().all(|v| *v >= -1e-4 && *v <= 1.0 + 1e-4)
}

/// The sRGB color of an OKLCH value; out of gamut, chroma drops until it fits.
fn from_oklch(v: Oklch) -> Rgb {
    let l = v.l.clamp(0.0, 1.0);
    let mut low = 0.0;
    let mut high = v.c.max(0.0);
    if !in_gamut(to_linear(Oklch { l, c: high, h: v.h })) {
        for _ in 0..24 {
            let middle = (low + high) / 2.0;
            if in_gamut(to_linear(Oklch { l, c: middle, h: v.h })) {
                low = middle;
            } else {
                high = middle;
            }
        }
        high = low;
    }
    let (r, g, b) = to_linear(Oklch { l, c: high, h: v.h });
    let channel = |c: f64| gamma(c.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    Rgb::new(channel(r), channel(g), channel(b), 1.0)
}

fn meets(color: Rgb, constraints: &[Constraint]) -> bool {
    constraints.iter().all(|c| contrast(color, c.on) >= c.minimum)
}

/// `color` with the smallest OKLCH lightness change that meets every
/// constraint (the web `fit`).
fn fit(color: Rgb, constraints: &[Constraint], prefer: Option<Direction>) -> Rgb {
    let start = quantized(color);
    if meets(start, constraints) {
        return start;
    }
    let lch = oklch(start);
    let average =
        constraints.iter().map(|c| luminance(c.on)).sum::<f64>() / constraints.len().max(1) as f64;
    let first =
        prefer.unwrap_or(if average < 0.18 { Direction::Lighter } else { Direction::Darker });
    let second = if first == Direction::Lighter { Direction::Darker } else { Direction::Lighter };
    for direction in [first, second] {
        let pole = if direction == Direction::Lighter { 1.0 } else { 0.0 };
        let at = |t: f64| {
            quantized(from_oklch(Oklch { l: lch.l + (pole - lch.l) * t, c: lch.c, h: lch.h }))
        };
        if !meets(at(1.0), constraints) {
            continue;
        }
        let (mut low, mut high) = (0.0, 1.0);
        for _ in 0..28 {
            let middle = (low + high) / 2.0;
            if meets(at(middle), constraints) {
                high = middle;
            } else {
                low = middle;
            }
        }
        return at(high);
    }
    let worst =
        |pole: Rgb| constraints.iter().map(|c| contrast(pole, c.on)).fold(f64::INFINITY, f64::min);
    let (white, black) =
        if constraints.is_empty() { (0.0, 0.0) } else { (worst(Rgb::WHITE), worst(Rgb::BLACK)) };
    if white >= black { Rgb::WHITE } else { Rgb::BLACK }
}
