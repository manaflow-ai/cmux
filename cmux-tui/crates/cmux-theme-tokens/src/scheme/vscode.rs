//! VS Code color themes (the JSON a `contributes.themes` entry points at):
//! read into a [`Scheme`] and written back out.
//!
//! The file is JSON with comments (`//`, `/* */`) and trailing commas, as
//! VS Code itself accepts. It is detected by a top-level `colors` object of
//! `area.name` keys (`editor.background`), a `tokenColors` entry, or a
//! `vscode://schemas/color-theme` `$schema`.
//!
//! What each terminal slot reads, first match wins:
//!
//! - background: `terminal.background`, `editor.background`, the global
//!   (scope-less) `tokenColors` entry's `background`, else VS Code's default
//!   for the theme type (`#1e1e1e` dark, `#ffffff` light).
//! - foreground: `terminal.foreground`, `editor.foreground`, `foreground`,
//!   the global entry's `foreground`, else VS Code's terminal default
//!   (`#cccccc` dark, `#333333` light).
//! - cursor: `terminalCursor.foreground`, `editorCursor.foreground`, the
//!   global entry's `caret`; cursor text `terminalCursor.background`,
//!   `editorCursor.background`.
//! - selection: `terminal.selectionBackground`, `editor.selectionBackground`,
//!   the global entry's `selection`; its text `terminal.selectionForeground`,
//!   `editor.selectionForeground`.
//! - accent: `focusBorder`, `activityBarBadge.background`, `button.background`.
//! - ANSI 0...15: `terminal.ansiBlack` ... `terminal.ansiBrightWhite`.
//!
//! A theme that leaves ANSI colors out (most editor-only themes do) gets them
//! derived from its own colors, so the terminal looks like the editor:
//!
//! - red, green, yellow, blue, magenta, cyan (1...6): the theme's most
//!   colorful syntax color (`tokenColors` foregrounds, then the editor's
//!   error, warning, info, git decoration and link colors) within 30 degrees of
//!   the slot's hue; with none that close, VS Code's own terminal default.
//! - black and white (0, 7, 15) from the background and foreground: dark
//!   themes black = background mixed 15% toward foreground, white =
//!   foreground, bright white = foreground mixed halfway to white; light
//!   themes black = foreground, white = background mixed 20% toward
//!   foreground, bright white = background mixed 8% toward foreground.
//! - bright black (8): the `comment` scope's color, else background mixed
//!   45% toward foreground.
//! - a bright color (9...14) the file lacks is its normal one mixed 20%
//!   toward the foreground; a normal one it lacks, when the bright one is
//!   there, the bright one mixed 15% toward the background.
//!
//! Colors may be `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`; a translucent
//! one is composited over the background (the editor draws it so). An
//! `include` of another theme file is not followed.

use super::{Scheme, SchemeError, error, hex6, json_string, line_of, line_of_key, quantized};
use crate::Rgb;
use crate::image_palette::{chroma, hsl, hue_distance};
use crate::spec::json;

/// VS Code's `colors` keys for ANSI 0...15.
const ANSI_KEYS: [&str; 16] = [
    "terminal.ansiBlack",
    "terminal.ansiRed",
    "terminal.ansiGreen",
    "terminal.ansiYellow",
    "terminal.ansiBlue",
    "terminal.ansiMagenta",
    "terminal.ansiCyan",
    "terminal.ansiWhite",
    "terminal.ansiBrightBlack",
    "terminal.ansiBrightRed",
    "terminal.ansiBrightGreen",
    "terminal.ansiBrightYellow",
    "terminal.ansiBrightBlue",
    "terminal.ansiBrightMagenta",
    "terminal.ansiBrightCyan",
    "terminal.ansiBrightWhite",
];

/// ANSI 1...6's hues, as their slot: red, green, yellow, blue, magenta, cyan.
const HUES: [(usize, f64); 6] =
    [(1, 0.0), (2, 120.0), (3, 55.0), (4, 220.0), (5, 300.0), (6, 185.0)];

/// VS Code's built-in terminal palette (terminalColorRegistry), dark themes.
const DEFAULT_DARK: [u32; 16] = [
    0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666,
    0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xe5e5e5,
];

/// The same, light themes.
const DEFAULT_LIGHT: [u32; 16] = [
    0x000000, 0xcd3131, 0x107c10, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555, 0x666666,
    0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5,
];

/// Editor colors whose hue means the same in a terminal (after `tokenColors`).
const EDITOR_HUED_KEYS: [&str; 7] = [
    "editorError.foreground",
    "editorWarning.foreground",
    "editorInfo.foreground",
    "gitDecoration.addedResourceForeground",
    "gitDecoration.modifiedResourceForeground",
    "gitDecoration.deletedResourceForeground",
    "textLink.foreground",
];

/// `text` with JSONC's comments and trailing commas blanked to spaces, so
/// plain JSON reads it and every byte offset (and line) stays where it was.
pub(super) fn strip_jsonc(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = bytes.to_vec();
    let blank = |out: &mut Vec<u8>, from: usize, to: usize| {
        for byte in out.iter_mut().take(to).skip(from) {
            if *byte != b'\n' && *byte != b'\r' {
                *byte = b' ';
            }
        }
    };
    let mut i = 0;
    let mut in_string = false;
    // The last `,` outside a string with only blanks and comments since.
    let mut pending_comma: Option<usize> = None;
    while let Some(&b) = bytes.get(i) {
        if in_string {
            match b {
                b'\\' => i += 1,
                b'"' => in_string = false,
                _ => {}
            }
            i += 1;
            continue;
        }
        match (b, bytes.get(i + 1).copied()) {
            (b'/', Some(b'/')) => {
                let rest = bytes.get(i..).unwrap_or_default();
                let end = rest.iter().position(|&c| c == b'\n').map_or(bytes.len(), |n| i + n);
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            (b'/', Some(b'*')) => {
                let rest = text.get(i + 2..).unwrap_or_default();
                let end = rest.find("*/").map_or(bytes.len(), |n| i + 2 + n + 2);
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            (b'"', _) => {
                in_string = true;
                pending_comma = None;
            }
            (b',', _) => pending_comma = Some(i),
            (b'}' | b']', _) => {
                if let Some(byte) = pending_comma.take().and_then(|at| out.get_mut(at)) {
                    *byte = b' ';
                }
            }
            (c, _) if c.is_ascii_whitespace() => {}
            _ => pending_comma = None,
        }
        i += 1;
    }
    // Only ASCII bytes were replaced, each by an ASCII space: still UTF-8.
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// Whether `text` (JSON or JSONC) is a VS Code color theme: a top-level
/// `colors` object of dotted keys, a `tokenColors` entry, or VS Code's
/// theme `$schema`.
pub(super) fn looks_like_vscode(text: &str) -> bool {
    match json::parse(&strip_jsonc(text)) {
        Ok(doc) => {
            // VS Code's color keys are all `area.name` (`editor.background`);
            // a cmux theme file's `colors` object has plain keys.
            matches!(doc.get("colors"), Some(json::Value::Object(entries))
                if entries.iter().any(|(key, _)| key.contains('.')))
                || doc.get("tokenColors").is_some()
                || doc
                    .get("$schema")
                    .and_then(json::Value::as_str)
                    .is_some_and(|s| s.contains("vscode://schemas/color-theme"))
        }
        // A file that does not parse: name it VS Code when it says so, so
        // the error comes from the reader the file was meant for.
        Err(_) => text.contains("\"tokenColors\"") || text.contains("\"editor.background\""),
    }
}

/// A VS Code color, composited over `base` when translucent.
fn vscode_color(value: &str, base: Rgb) -> Option<Rgb> {
    let hex = value.trim().strip_prefix('#')?;
    if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let n = u32::from_str_radix(hex, 16).ok()?;
    let nibble = |shift: u32| f64::from(((n >> shift) & 0xf) * 17) / 255.0;
    let byte = |shift: u32| f64::from((n >> shift) & 0xff) / 255.0;
    let color = match hex.len() {
        3 => Rgb::new(nibble(8), nibble(4), nibble(0), 1.0),
        4 => Rgb::new(nibble(12), nibble(8), nibble(4), nibble(0)),
        6 => Rgb::new(byte(16), byte(8), byte(0), 1.0),
        8 => Rgb::new(byte(24), byte(16), byte(8), byte(0)),
        _ => return None,
    };
    Some(quantized(color.composited(base)))
}

/// Whether the theme is light: its `type` (`light`, `hcLight`, `hc-light`,
/// `vs`), else its background's luminance, else dark.
fn is_light(doc: &json::Value, background: Option<Rgb>) -> bool {
    match doc.get("type").and_then(json::Value::as_str).map(str::to_ascii_lowercase) {
        Some(kind) if kind.contains("light") || kind == "vs" => true,
        Some(kind) if kind.contains("dark") || kind.starts_with("hc") || kind == "vs-dark" => false,
        _ => background.is_some_and(|bg| bg.relative_luminance() > 0.4),
    }
}

/// The scopes of one `tokenColors` entry.
fn scopes(entry: &json::Value) -> Vec<String> {
    match entry.get("scope") {
        Some(json::Value::String(s)) => s.split(',').map(|s| s.trim().to_owned()).collect(),
        Some(json::Value::Array(items)) => {
            items.iter().filter_map(json::Value::as_str).map(|s| s.trim().to_owned()).collect()
        }
        _ => Vec::new(),
    }
}

pub(super) fn parse_vscode(text: &str, file: &str) -> Result<Scheme, SchemeError> {
    let stripped = strip_jsonc(text);
    let doc = json::parse(&stripped).map_err(|message| {
        let at = message
            .rsplit_once("at byte ")
            .and_then(|(_, n)| n.trim().parse::<usize>().ok())
            .unwrap_or(0);
        error(file, line_of(text, at), message)
    })?;
    if !matches!(doc, json::Value::Object(_)) {
        return Err(error(file, 1, "not a JSON object"));
    }
    let colors = match doc.get("colors") {
        None | Some(json::Value::Null) => None,
        Some(object @ json::Value::Object(_)) => Some(object),
        Some(_) => return Err(error(file, line_of_key(text, "colors"), "colors is not an object")),
    };
    let token_colors: &[json::Value] = match doc.get("tokenColors") {
        Some(json::Value::Array(items)) => items,
        _ => &[],
    };
    if colors.is_none() && token_colors.is_empty() {
        return Err(error(file, 1, "no colors object or tokenColors array"));
    }
    // The global (scope-less) tokenColors entry, as TextMate themes carry
    // the editor's own colors.
    let global = token_colors
        .iter()
        .find(|entry| entry.get("scope").is_none())
        .and_then(|entry| entry.get("settings"));
    let global_raw = |key: &str| global.and_then(|g| g.get(key)).and_then(json::Value::as_str);

    // `colors[key]`, composited over `base`; a value that is not a color
    // is an error naming its line, an empty or null one is absent.
    let color = |key: &str, base: Rgb| -> Result<Option<Rgb>, SchemeError> {
        match colors.and_then(|c| c.get(key)) {
            None | Some(json::Value::Null) => Ok(None),
            Some(json::Value::String(s)) if s.trim().is_empty() => Ok(None),
            Some(json::Value::String(s)) => vscode_color(s, base).map(Some).ok_or_else(|| {
                error(file, line_of_key(text, key), format!("{key} is not a color: {s:?}"))
            }),
            Some(_) => Err(error(file, line_of_key(text, key), format!("{key} is not a string"))),
        }
    };
    let first =
        |keys: &[&str], global_key: Option<&str>, base: Rgb| -> Result<Option<Rgb>, SchemeError> {
            for key in keys {
                if let Some(found) = color(key, base)? {
                    return Ok(Some(found));
                }
            }
            Ok(global_key.and_then(global_raw).and_then(|s| vscode_color(s, base)))
        };

    // The background first (everything translucent composites over it).
    let declared_bg =
        first(&["terminal.background", "editor.background"], Some("background"), Rgb::BLACK)?;
    let light = is_light(&doc, declared_bg);
    let defaults = if light { DEFAULT_LIGHT } else { DEFAULT_DARK };
    let background = declared_bg.unwrap_or(if light { Rgb::WHITE } else { Rgb::hex(0x1e1e1e) });
    let foreground = first(
        &["terminal.foreground", "editor.foreground", "foreground"],
        Some("foreground"),
        background,
    )?
    .unwrap_or(Rgb::hex(if light { 0x333333 } else { 0xcccccc }));
    let cursor = first(
        &["terminalCursor.foreground", "editorCursor.foreground"],
        Some("caret"),
        background,
    )?;
    let cursor_text =
        first(&["terminalCursor.background", "editorCursor.background"], None, background)?;
    let selection_background = first(
        &["terminal.selectionBackground", "editor.selectionBackground"],
        Some("selection"),
        background,
    )?;
    let selection_foreground =
        first(&["terminal.selectionForeground", "editor.selectionForeground"], None, background)?;
    let accent = first(
        &["focusBorder", "activityBarBadge.background", "button.background"],
        None,
        background,
    )?;

    let mut declared: [Option<Rgb>; 16] = [None; 16];
    for (slot, key) in declared.iter_mut().zip(ANSI_KEYS) {
        *slot = color(key, background)?;
    }

    // The theme's own hued colors: syntax first, then the editor's.
    let mut hued: Vec<Rgb> = token_colors
        .iter()
        .filter_map(|entry| entry.get("settings")?.get("foreground")?.as_str())
        .filter_map(|s| vscode_color(s, background))
        .collect();
    for key in EDITOR_HUED_KEYS {
        if let Ok(Some(c)) = color(key, background) {
            hued.push(c);
        }
    }
    let nearest = |target: f64| -> Option<Rgb> {
        hued.iter()
            .copied()
            .filter(|c| chroma(*c) >= 0.15 && hue_distance(hsl(*c).0, target) <= 30.0)
            .min_by(|a, b| {
                let score = |c: Rgb| hue_distance(hsl(c).0, target) - 40.0 * chroma(c);
                score(*a).total_cmp(&score(*b))
            })
    };
    let comment = token_colors
        .iter()
        .find(|entry| scopes(entry).iter().any(|s| s == "comment" || s.starts_with("comment.")))
        .and_then(|entry| entry.get("settings")?.get("foreground")?.as_str())
        .and_then(|s| vscode_color(s, background));

    let mut palette = declared;
    {
        // ANSI 0...7 and their brights 8...15: slot `n`'s bright is `brights[n]`.
        let (normals, brights) = palette.split_at_mut(8);
        for (slot, hue) in HUES {
            let (Some(normal), Some(bright)) = (normals.get_mut(slot), brights.get_mut(slot))
            else {
                continue;
            };
            let default = defaults.get(slot).map(|&hex| Rgb::hex(hex));
            *normal = normal
                .or_else(|| bright.map(|b| quantized(b.mixed(background, 0.15))))
                .or_else(|| nearest(hue))
                .or(default);
            *bright = bright.or_else(|| normal.map(|n| quantized(n.mixed(foreground, 0.2))));
        }
    }
    let mix = |a: Rgb, b: Rgb, t: f64| quantized(a.mixed(b, t));
    let (black, white, bright_white) = if light {
        (foreground, mix(background, foreground, 0.2), mix(background, foreground, 0.08))
    } else {
        (mix(background, foreground, 0.15), foreground, mix(foreground, Rgb::WHITE, 0.5))
    };
    palette[0] = palette[0].or(Some(black));
    palette[7] = palette[7].or(Some(white));
    palette[15] = palette[15].or(Some(bright_white));
    palette[8] = palette[8].or(comment).or_else(|| Some(mix(background, foreground, 0.45)));

    let palette = palette.map(|c| c.unwrap_or(Rgb::BLACK));
    let text_field = |key: &str| {
        doc.get(key)
            .and_then(json::Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    Ok(Scheme {
        name: text_field("name"),
        author: text_field("author"),
        background,
        foreground,
        cursor,
        cursor_text,
        selection_background,
        selection_foreground,
        palette,
        accent,
        base16: None,
    })
}

impl Scheme {
    /// The scheme as a VS Code color theme: the terminal and editor colors,
    /// no syntax rules (`tokenColors` empty).
    pub(super) fn to_vscode(&self) -> String {
        let light = self.background.relative_luminance() > self.foreground.relative_luminance();
        let mut fields: Vec<(String, Rgb)> = Vec::new();
        let mut put = |key: &str, color: Option<Rgb>| {
            if let Some(color) = color {
                fields.push((key.to_owned(), color));
            }
        };
        put("editor.background", Some(self.background));
        put("editor.foreground", Some(self.foreground));
        put("terminal.background", Some(self.background));
        put("terminal.foreground", Some(self.foreground));
        put("terminalCursor.foreground", self.cursor);
        put("terminalCursor.background", self.cursor_text);
        put("terminal.selectionBackground", self.selection_background);
        put("terminal.selectionForeground", self.selection_foreground);
        put("focusBorder", self.accent);
        for (key, color) in ANSI_KEYS.iter().zip(self.palette) {
            put(key, Some(color));
        }
        let body: Vec<String> = fields
            .iter()
            .map(|(key, color)| format!("        \"{key}\": \"#{}\"", hex6(*color)))
            .collect();
        format!(
            "{{\n    \"$schema\": \"vscode://schemas/color-theme\",\n    \"name\": {},\n    \"type\": \"{}\",\n    \"colors\": {{\n{}\n    }},\n    \"tokenColors\": []\n}}\n",
            json_string(self.name.as_deref().unwrap_or("Untitled")),
            if light { "light" } else { "dark" },
            body.join(",\n"),
        )
    }
}
