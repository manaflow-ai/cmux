//! WCAG contrast of a look (Leo, 2026-11-18: "you guys also need to watch for if there's light on
//! light or dark on dark"): every pair of ink and fill a look draws, in the app chrome and in the
//! agent chat, from the same derived colors the app paints (`ThemeTokens::derive`, the agent
//! pane's `AgentPaneTheme`, `SurfaceBackgrounds`), each held to its WCAG 2 minimum: 4.5:1 for text,
//! 3:1 for large text and UI marks (the thresholds of the webviews look-addons browser test).
//!
//! The derived inks already meet their minimums on the theme's own surfaces; what a look can break
//! is a surface it paints itself (`appearance.surfaces.<surface>.color`), an accent or a status
//! color it names, and the terminal's own colors (a selection that hides the text on it). So each
//! pair is read on the fill the look gives that place. A surface's color is laid over the window's
//! color (the theme background) at its opacity, as `SurfaceBackgrounds.fill` paints it; a picture
//! behind a translucent window is not known here and counts as the window's color.
//!
//! `cmux theme check` reports a theme file's failures; the shipped and example theme files are held
//! to none (`tests.rs`).

use std::collections::BTreeMap;

use cmux_theme_tokens::{Rgb, ThemeAccent, ThemeInput, ThemeTokens, mix_oklab, parse_color};
use serde::Serialize;
use serde_json::Value;

use super::ThemeFile;
use crate::keypath::key_path;
use crate::text::ThemeSpec;
use crate::value::value_at;

/// Text (WCAG 2 AA, body size).
pub const TEXT: f64 = 4.5;
/// Large text, glyphs and UI marks (WCAG 2 AA, 1.4.3 large and 1.4.11).
pub const UI: f64 = 3.0;

/// The chat's fixed fills and inks, as a share of the text over the page (webviews
/// `agent-session/shared/styles.css`, `conversation/conversation.css` and the content surface levels
/// of `pages/shared/desktop.css`; `contrast_tests.rs` reads them and fails when one of these no
/// longer matches).
pub(crate) mod chat {
    /// `--cv-bubble`: the prompt bubble, the text at 5% over the page.
    pub const BUBBLE: f64 = 0.05;
    /// `--cv-codeblock-bg`: a code card (`--ds-surface-card`), the text at 4%.
    pub const CODE_CARD: f64 = 0.04;
    /// `--cv-codeblock-text`: a code card's text, the text at 90%.
    pub const CODE_TEXT: f64 = 0.90;
    /// `--cv-code-bg`: inline code (`--ds-surface-inset`), the text at 8%.
    pub const INLINE_CODE: f64 = 0.08;
    /// `--agent-link-base`: links are blue in every theme, light or dark.
    pub const LINK_LIGHT: u32 = 0x0b63d6;
    pub const LINK_DARK: u32 = 0x5aa2ff;
    /// `--agent-link`: that blue at 80% in oklab, the rest the theme's bright blue (ANSI 12).
    pub const LINK_SHARE: f64 = 0.80;
}

/// One ink on one fill, both opaque, as the screen shows them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ContrastPair {
    /// What draws it: `sidebar text`, `chat prompt bubble text`.
    pub element: &'static str,
    pub foreground: Rgb,
    pub background: Rgb,
    /// The least ratio it must reach ([`TEXT`] or [`UI`]).
    pub required: f64,
}

impl ContrastPair {
    pub fn ratio(&self) -> f64 {
        self.foreground.contrast(self.background)
    }
}

/// A pair under its minimum, as `cmux theme check` prints it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ContrastFailure {
    /// The terminal theme the look was read with (`Claude Light`).
    pub theme: String,
    pub element: String,
    /// `#rrggbb`.
    pub foreground: String,
    /// `#rrggbb`.
    pub background: String,
    /// Rounded down to two places, so a printed ratio never reads as passing.
    pub ratio: f64,
    pub required: f64,
}

impl ContrastFailure {
    /// `Claude Light: chat link #5aa2ff on #faf9f5 is 2.61:1, needs 4.5:1`.
    pub fn display(&self) -> String {
        format!(
            "{}: {} {} on {} is {:.2}:1, needs {}:1",
            self.theme, self.element, self.foreground, self.background, self.ratio, self.required
        )
    }
}

/// A surface override (`appearance.surfaces.<surface>`): a color, an opacity, or both.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Surface {
    pub color: Option<Rgb>,
    pub opacity: Option<f64>,
}

/// The colors of one look in one appearance: the terminal theme's and the app theme's (each with
/// the look's edits and accent) and what the look paints over the derived chrome.
#[derive(Debug, Clone, PartialEq)]
pub struct LookColors {
    /// The terminal theme (`appearance.theme`): what Ghostty draws.
    pub terminal: ThemeInput,
    /// The theme the chrome and the pages derive from: the app theme (`appearance.appTheme`)
    /// when it names one, else the terminal theme.
    pub chrome: ThemeInput,
    /// `appearance.surfaces`, by surface (`sidebar`, `tabBar`, `terminal`, `agentPane`, ...).
    pub surfaces: BTreeMap<String, Surface>,
    /// `appearance.backgroundOpacity` (the window's opacity); `None`: opaque.
    pub window_opacity: Option<f64>,
    /// `appearance.statusIndicator.color`.
    pub status_color: Option<Rgb>,
    /// Ghostty's `minimum-contrast` (1 to 21; Ghostty's default and cmux's is 1, no change).
    pub minimum_contrast: f64,
}

fn hex(color: Rgb) -> String {
    format!("#{:06x}", color.to_hex())
}

/// The ink Ghostty's text shader draws for `ink` on `ground` under `minimum-contrast`
/// (`contrasted_color` in `shaders.metal`): under the minimum, white or black, whichever reads
/// better on the ground; else the ink itself. At the default 1 it never changes the ink.
pub fn ghostty_ink(ink: Rgb, ground: Rgb, minimum_contrast: f64) -> Rgb {
    if minimum_contrast <= 1.0 || ink.contrast(ground) >= minimum_contrast {
        return ink;
    }
    if Rgb::WHITE.contrast(ground) > Rgb::BLACK.contrast(ground) { Rgb::WHITE } else { Rgb::BLACK }
}

impl LookColors {
    /// What `surface` shows: its override over the window's color, else `fallback`
    /// (`SurfaceBackgrounds.fill`: a color at its opacity, else the window's; an opacity alone
    /// keeps the theme's color).
    fn ground(&self, surface: &str, window: Rgb, fallback: Rgb) -> Rgb {
        match self.surfaces.get(surface) {
            Some(Surface { color: Some(color), opacity }) => {
                let alpha = color.a * opacity.or(self.window_opacity).unwrap_or(1.0);
                color.with_alpha(alpha.clamp(0.0, 1.0)).composited(window)
            }
            _ => fallback.composited(window),
        }
    }

    /// Every pair the look draws, chrome first, then the terminal, then the chat.
    pub fn pairs(&self) -> Vec<ContrastPair> {
        let tokens = ThemeTokens::derive(&self.chrome);
        let window = tokens.window_background.with_alpha(1.0);
        let mut pairs = Vec::new();
        let mut add = |element, foreground: Rgb, background: Rgb, required| {
            pairs.push(ContrastPair {
                element,
                foreground: foreground.composited(background),
                background,
                required,
            });
        };

        // The sidebar: its rows' titles and captions, the selected and hovered row, status marks.
        let sidebar = self.ground("sidebar", window, tokens.sidebar_background);
        let selected_row = tokens.selection_fill.composited(sidebar);
        add("sidebar text", tokens.text_primary, sidebar, TEXT);
        add("sidebar muted text", tokens.text_secondary, sidebar, TEXT);
        add("sidebar dim text", tokens.text_tertiary, sidebar, UI);
        add("sidebar selected row text", tokens.text_primary, selected_row, TEXT);
        add("sidebar selected row muted text", tokens.text_secondary, selected_row, TEXT);
        add(
            "sidebar hovered row text",
            tokens.text_primary,
            tokens.hover_fill.composited(sidebar),
            TEXT,
        );
        add("sidebar accent mark", tokens.accent, sidebar, UI);
        if let Some(status) = self.status_color {
            add("sidebar status indicator", status.with_alpha(1.0), sidebar, UI);
        }

        // Every pane's tab strip: the titles at rest and the selected tab's.
        let strip = self.ground("tabBar", window, tokens.strip_background);
        add("tab title", tokens.text_primary, strip, TEXT);
        add("tab title (inactive)", tokens.text_secondary, strip, TEXT);
        add(
            "selected tab title",
            tokens.text_primary,
            tokens.selection_fill.composited(strip),
            TEXT,
        );

        // Accent buttons: their label on the accent.
        add("accent button label", tokens.on_accent, tokens.accent.with_alpha(1.0), TEXT);

        // The terminal: Ghostty draws the terminal theme's own foreground (not the derived ink)
        // over the terminal's surface, and selected text in `selection-foreground`, else in the
        // background color (renderer `rebuildRow`: `selection_foreground ... else
        // state.colors.background`), on the selection drawn opaque. The text shader then swaps an
        // ink under `minimum-contrast` for white or black ([`ghostty_ink`]); at cmux's default of
        // 1 it swaps nothing, so a look that edits only the selection keeps its theme's selection
        // ink (Builtin Dark's and Synthwave's black, Green Phosphor CRT's gray). Mac captures of
        // Charcoal, Arcade, Leo Neon, Classic Desktop and Phosphor draw exactly these inks.
        let bg = self.terminal.background.with_alpha(1.0);
        let terminal = self.ground("terminal", window, bg);
        let foreground = self.terminal.foreground.with_alpha(1.0);
        let minimum = self.minimum_contrast;
        add("terminal text", ghostty_ink(foreground, terminal, minimum), terminal, TEXT);
        if let Some(selection) = self.terminal.selection_background {
            let selection = selection.with_alpha(1.0);
            let ink = self.terminal.selection_foreground.unwrap_or(bg).with_alpha(1.0);
            add("terminal selected text", ghostty_ink(ink, selection, minimum), selection, TEXT);
        }

        // The agent chat (`AgentPaneTheme`): text, muted and soft text, links, the prompt bubble,
        // code and cards on the pane's page, and Send on the accent.
        let page = self.ground("agentPane", window, tokens.content_background);
        let text = tokens.text_primary.with_alpha(1.0);
        let over = |share: f64| text.with_alpha(share).composited(page);
        let link_base = Rgb::hex(if tokens.is_dark { chat::LINK_DARK } else { chat::LINK_LIGHT });
        let link = mix_oklab(tokens.ansi[12], link_base, chat::LINK_SHARE);
        add("chat text", text, page, TEXT);
        add("chat muted text", tokens.text_secondary, page, TEXT);
        add("chat dim text", tokens.text_tertiary, page, UI);
        add("chat link", link, page, TEXT);
        add("chat prompt bubble text", text, over(chat::BUBBLE), TEXT);
        add("chat prompt bubble muted text", tokens.text_secondary, over(chat::BUBBLE), TEXT);
        add("chat code card text", text.with_alpha(chat::CODE_TEXT), over(chat::CODE_CARD), TEXT);
        add("chat inline code", text, over(chat::INLINE_CODE), TEXT);
        // A card (`--agent-surface-elevated`): the elevated background over the page.
        let card = tokens.elevated_background.composited(page);
        add("chat card text", text, card, TEXT);
        add("chat card muted text", tokens.text_secondary, card, TEXT);
        // Send: the page's opaque color (`accentText`) as the glyph on the accent.
        add("chat send button glyph", page, tokens.accent.with_alpha(1.0), UI);
        pairs
    }

    /// The pairs under their minimum, named for `theme`.
    pub fn failures(&self, theme: &str) -> Vec<ContrastFailure> {
        self.pairs()
            .into_iter()
            .filter_map(|pair| {
                let ratio = pair.ratio();
                // A hundredth of slack: the browser and the app round channels to bytes.
                (ratio + 0.005 < pair.required).then(|| ContrastFailure {
                    theme: theme.to_string(),
                    element: pair.element.to_string(),
                    foreground: hex(pair.foreground),
                    background: hex(pair.background),
                    ratio: (ratio * 100.0).floor() / 100.0,
                    required: pair.required,
                })
            })
            .collect()
    }
}

fn color_at(root: &Value, dotted: &str) -> Option<Rgb> {
    value_at(root, &key_path(dotted)).and_then(Value::as_str).and_then(parse_color)
}

/// The theme `name` as `root` shows it: `base` (its own colors; `None`: Ghostty's defaults) with
/// its `appearance.themeEdits` over them and the chrome accent `appearance.accent`.
pub fn edited_theme(root: &Value, name: &str, base: Option<ThemeInput>) -> ThemeInput {
    let mut input = base.unwrap_or_default();
    let edits = value_at(root, &key_path("appearance.themeEdits"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let edit = |token: &str| {
        edits.get(&format!("{name}/{token}")).and_then(Value::as_str).and_then(parse_color)
    };
    if let Some(color) = edit("background") {
        input.background = color;
    }
    if let Some(color) = edit("foreground") {
        input.foreground = color;
    }
    if let Some(color) = edit("selection") {
        input.selection_background = Some(color);
    }
    if let Some(color) = edit("cursor") {
        input.cursor = Some(color);
    }
    if let Some(color) = edit("accent") {
        input.accent_color = Some(color);
    }
    for (index, slot) in input.palette.iter_mut().enumerate() {
        if let Some(color) = edit(&index.to_string()) {
            *slot = color;
        }
    }
    input.accent = value_at(root, &key_path("appearance.accent"))
        .and_then(Value::as_str)
        .and_then(ThemeAccent::parse)
        .unwrap_or_default();
    input
}

/// The look `root` (settings with a theme file applied) shows with the terminal theme
/// `terminal` and the chrome's theme `chrome` (each already [`edited_theme`]).
pub fn look_colors(root: &Value, terminal: ThemeInput, chrome: ThemeInput) -> LookColors {
    let surfaces = value_at(root, &key_path("appearance.surfaces"))
        .and_then(Value::as_object)
        .map(|all| {
            all.iter()
                .filter_map(|(surface, value)| {
                    let color = value.get("color").and_then(Value::as_str).and_then(parse_color);
                    let opacity = value.get("opacity").and_then(Value::as_f64);
                    (color.is_some() || opacity.is_some())
                        .then(|| (surface.clone(), Surface { color, opacity }))
                })
                .collect()
        })
        .unwrap_or_default();
    LookColors {
        terminal,
        chrome,
        surfaces,
        window_opacity: value_at(root, &key_path("appearance.backgroundOpacity"))
            .and_then(Value::as_f64),
        status_color: color_at(root, "appearance.statusIndicator.color"),
        minimum_contrast: 1.0,
    }
}

/// `appearance.theme` or `appearance.appTheme` in `root`, as (light, dark) names.
fn theme_names(root: &Value, key: &str) -> Option<(String, String)> {
    value_at(root, &key_path(key))
        .and_then(Value::as_str)
        .filter(|value| *value != "followTerminal")
        .and_then(ThemeSpec::parse)
        .map(|spec| (spec.light, spec.dark))
}

impl ThemeFile {
    /// The contrast failures of this file's look over `root` (the settings it applies over), in
    /// light and in dark (once when both name the same themes). `theme` gives a theme's own
    /// colors by name (`None`: unknown, Ghostty's defaults under the look's edits; a file with
    /// its own `colors` needs none).
    pub fn contrast(
        &self,
        root: &Value,
        theme: &dyn Fn(&str) -> Option<ThemeInput>,
    ) -> Vec<ContrastFailure> {
        let applied = self.applied(root, &Default::default());
        let terminal = theme_names(&applied, "appearance.theme").unwrap_or_default();
        let app = theme_names(&applied, "appearance.appTheme");
        let light = (terminal.0.clone(), app.as_ref().map(|a| a.0.clone()));
        let dark = (terminal.1, app.as_ref().map(|a| a.1.clone()));
        let looks = if dark == light { vec![light] } else { vec![light, dark] };
        looks
            .into_iter()
            .flat_map(|(name, app)| {
                let terminal = edited_theme(&applied, &name, theme(&name));
                let chrome = match &app {
                    Some(app) => edited_theme(&applied, app, theme(app)),
                    None => terminal,
                };
                let mut label = if name.is_empty() { "default theme".to_string() } else { name };
                if let Some(app) = app {
                    label = format!("{label} (app theme {app})");
                }
                look_colors(&applied, terminal, chrome).failures(&label)
            })
            .collect()
    }
}
