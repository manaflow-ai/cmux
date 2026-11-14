//! 16-color schemes in the formats other terminals and the ricing world
//! share, read into one [`Scheme`] and written back out (extensibility
//! design 12.4, step 13):
//!
//! - **base16** YAML (`base00: "1d1f21"`, flat or nested under `palette:`
//!   as tinted-theming writes it), with base16-shell's terminal mapping:
//!   background base00, foreground and cursor base05, selection base02,
//!   ANSI 0-7 from base00/08/0B/0A/0D/0E/0C/05 and 8-15 the same with base03
//!   and base07. The 16 base colors are kept, so base16 in, base16 out is
//!   exact; a scheme from another format gets the six base colors the
//!   terminal mapping leaves out (01, 04, 06, 09, 0F) mixed from its own.
//! - **iTerm2** `.itermcolors` (an XML property list of 0...1 components).
//! - **Windows Terminal** scheme JSON (`black` ... `brightWhite`,
//!   `background`, `foreground`, `cursorColor`, `selectionBackground`), the
//!   same shape VS Code's `terminal.ansi*` exports reduce to.
//! - **Ghostty** theme files, the format cmux's theme files are.
//!
//! Every color is read as opaque 8-bit sRGB, so a scheme written and read
//! back is the same value. A file that does not parse is a [`SchemeError`]
//! naming the file and the line.

use std::fmt;
use std::path::PathBuf;

use crate::config::{THEME_ACCENT_KEY, theme_file_accent, theme_override_value};
use crate::spec::json;
use crate::{Env, Rgb, ThemeInput, parse_color};

/// A 16-color terminal scheme.
#[derive(Clone, Debug, PartialEq)]
pub struct Scheme {
    /// The scheme's own name, when the file has one.
    pub name: Option<String>,
    /// The scheme's author, when the file has one.
    pub author: Option<String>,
    pub background: Rgb,
    pub foreground: Rgb,
    pub cursor: Option<Rgb>,
    pub cursor_text: Option<Rgb>,
    pub selection_background: Option<Rgb>,
    pub selection_foreground: Option<Rgb>,
    /// ANSI 0...15.
    pub palette: [Rgb; 16],
    /// The chrome accent (`# cmux-accent` in a Ghostty theme file).
    pub accent: Option<Rgb>,
    /// base00...base0F, kept from a base16 file so it writes back exactly.
    pub base16: Option<[Rgb; 16]>,
}

/// A scheme file format.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchemeFormat {
    Base16,
    Iterm2,
    WindowsTerminal,
    Ghostty,
}

impl SchemeFormat {
    /// Every format, in the order `cmux theme` lists them.
    pub const ALL: [SchemeFormat; 4] = [
        SchemeFormat::Ghostty,
        SchemeFormat::Base16,
        SchemeFormat::Iterm2,
        SchemeFormat::WindowsTerminal,
    ];

    /// The format's name on the CLI and the wire.
    pub fn name(self) -> &'static str {
        match self {
            SchemeFormat::Base16 => "base16",
            SchemeFormat::Iterm2 => "iterm2",
            SchemeFormat::WindowsTerminal => "windows-terminal",
            SchemeFormat::Ghostty => "ghostty",
        }
    }

    /// The format a name (or a common alias) names.
    pub fn from_name(name: &str) -> Option<SchemeFormat> {
        match name.trim().to_ascii_lowercase().as_str() {
            "base16" | "base16-yaml" | "tinted" | "yaml" | "yml" => Some(SchemeFormat::Base16),
            "iterm2" | "iterm" | "itermcolors" => Some(SchemeFormat::Iterm2),
            "windows-terminal" | "wt" | "json" | "windowsterminal" => {
                Some(SchemeFormat::WindowsTerminal)
            }
            "ghostty" | "conf" => Some(SchemeFormat::Ghostty),
            _ => None,
        }
    }

    /// The usual file extension (empty for Ghostty, whose themes have none).
    pub fn extension(self) -> &'static str {
        match self {
            SchemeFormat::Base16 => "yaml",
            SchemeFormat::Iterm2 => "itermcolors",
            SchemeFormat::WindowsTerminal => "json",
            SchemeFormat::Ghostty => "",
        }
    }

    /// The format of `text`, from `file`'s extension and then the text: an
    /// XML plist is iTerm2, a JSON object Windows Terminal, `baseXX:` lines
    /// base16, anything else a Ghostty theme.
    pub fn detect(file: &str, text: &str) -> SchemeFormat {
        let extension = file.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase());
        match extension.as_deref() {
            Some("yaml" | "yml") => return SchemeFormat::Base16,
            Some("itermcolors") => return SchemeFormat::Iterm2,
            Some("json") => return SchemeFormat::WindowsTerminal,
            _ => {}
        }
        let body = text.trim_start_matches('\u{FEFF}').trim_start();
        if body.starts_with("<?xml") || body.starts_with("<plist") || body.starts_with("<!DOCTYPE")
        {
            SchemeFormat::Iterm2
        } else if body.starts_with('{') {
            SchemeFormat::WindowsTerminal
        } else if text.lines().any(|line| base16_slot(line.trim()).is_some()) {
            SchemeFormat::Base16
        } else {
            SchemeFormat::Ghostty
        }
    }
}

impl fmt::Display for SchemeFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// A scheme file that does not parse: the file, the 1-based line (0 when
/// the problem is the whole file) and what is wrong.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SchemeError {
    pub file: String,
    pub line: usize,
    pub message: String,
}

impl fmt::Display for SchemeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}: {}", self.file, self.line, self.message)
    }
}

impl std::error::Error for SchemeError {}

fn error(file: &str, line: usize, message: impl Into<String>) -> SchemeError {
    SchemeError { file: file.to_owned(), line, message: message.into() }
}

/// Opaque 8-bit sRGB, so every format round-trips to the same value.
fn quantized(color: Rgb) -> Rgb {
    Rgb::hex(color.to_hex())
}

fn hex6(color: Rgb) -> String {
    format!("{:06x}", color.to_hex())
}

/// base16-shell's ANSI slots: ANSI index -> base index.
const BASE16_ANSI: [usize; 16] =
    [0x0, 0x8, 0xB, 0xA, 0xD, 0xE, 0xC, 0x5, 0x3, 0x8, 0xB, 0xA, 0xD, 0xE, 0xC, 0x7];

/// The names of ANSI 0...15 in a Windows Terminal scheme.
const WT_NAMES: [&str; 16] = [
    "black",
    "red",
    "green",
    "yellow",
    "blue",
    "purple",
    "cyan",
    "white",
    "brightBlack",
    "brightRed",
    "brightGreen",
    "brightYellow",
    "brightBlue",
    "brightPurple",
    "brightCyan",
    "brightWhite",
];

/// Most bytes a scheme file may have (the largest shipped themes are a few KB).
pub const MAX_SCHEME_BYTES: usize = 256 * 1024;

impl Scheme {
    /// A scheme from a terminal theme's colors.
    pub fn from_theme_input(input: &ThemeInput) -> Scheme {
        Scheme {
            name: None,
            author: None,
            background: quantized(input.background),
            foreground: quantized(input.foreground),
            cursor: input.cursor.map(quantized),
            cursor_text: None,
            selection_background: input.selection_background.map(quantized),
            selection_foreground: input.selection_foreground.map(quantized),
            palette: input.palette.map(quantized),
            accent: input.accent_color.map(quantized),
            base16: None,
        }
    }

    /// The terminal theme `ThemeTokens::derive` takes (opaque, no blur,
    /// neutral `appearance.accent`; the scheme's accent is the theme's own).
    pub fn theme_input(&self) -> ThemeInput {
        ThemeInput {
            background: self.background,
            foreground: self.foreground,
            palette: self.palette,
            selection_background: self.selection_background,
            selection_foreground: self.selection_foreground,
            cursor: self.cursor,
            accent_color: self.accent,
            ..ThemeInput::GHOSTTY_DEFAULT
        }
    }

    /// Reads `text` as `format`, or the detected format when `None`. `file`
    /// names the file in errors.
    pub fn parse(
        text: &str,
        file: &str,
        format: Option<SchemeFormat>,
    ) -> Result<Scheme, SchemeError> {
        if text.len() > MAX_SCHEME_BYTES {
            return Err(error(file, 0, format!("larger than {MAX_SCHEME_BYTES} bytes")));
        }
        let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
        match format.unwrap_or_else(|| SchemeFormat::detect(file, text)) {
            SchemeFormat::Base16 => parse_base16(text, file),
            SchemeFormat::Iterm2 => parse_iterm2(text, file),
            SchemeFormat::WindowsTerminal => parse_windows_terminal(text, file),
            SchemeFormat::Ghostty => parse_ghostty(text, file),
        }
    }

    /// The scheme as a `format` file.
    pub fn export(&self, format: SchemeFormat) -> String {
        match format {
            SchemeFormat::Base16 => self.to_base16(),
            SchemeFormat::Iterm2 => self.to_iterm2(),
            SchemeFormat::WindowsTerminal => self.to_windows_terminal(),
            SchemeFormat::Ghostty => self.to_ghostty(),
        }
    }

    /// base00...base0F: the kept base16 colors, else the terminal mapping
    /// read backward, with the five colors it leaves out mixed in.
    pub fn base16_colors(&self) -> [Rgb; 16] {
        if let Some(base) = self.base16 {
            return base;
        }
        let (bg, fg) = (self.background, self.foreground);
        let ansi = |i: usize| self.palette.get(i).copied().unwrap_or(fg);
        let mix = |a: Rgb, b: Rgb, t: f64| quantized(a.mixed(b, t));
        [
            bg,
            mix(bg, fg, 0.08),
            self.selection_background.unwrap_or_else(|| mix(bg, fg, 0.18)),
            ansi(8),
            mix(bg, fg, 0.7),
            fg,
            mix(fg, ansi(15), 0.5),
            ansi(15),
            ansi(1),
            mix(ansi(1), ansi(3), 0.5),
            ansi(3),
            ansi(2),
            ansi(6),
            ansi(4),
            ansi(5),
            mix(ansi(1), bg, 0.35),
        ]
    }

    fn to_base16(&self) -> String {
        let mut out = String::from("system: \"base16\"\n");
        out.push_str(&format!(
            "name: {}\n",
            yaml_string(self.name.as_deref().unwrap_or("Untitled"))
        ));
        if let Some(author) = &self.author {
            out.push_str(&format!("author: {}\n", yaml_string(author)));
        }
        let variant = if self.background.relative_luminance() < self.foreground.relative_luminance()
        {
            "dark"
        } else {
            "light"
        };
        out.push_str(&format!("variant: \"{variant}\"\npalette:\n"));
        for (i, color) in self.base16_colors().iter().enumerate() {
            out.push_str(&format!("  base0{i:X}: \"#{}\"\n", hex6(*color)));
        }
        out
    }

    fn to_ghostty(&self) -> String {
        let mut out = String::new();
        if let Some(name) = &self.name {
            out.push_str(&format!("# {}\n", one_line(name)));
        }
        let mut line = |key: &str, color: Option<Rgb>| {
            if let Some(color) = color {
                out.push_str(&format!("{key} = #{}\n", hex6(color)));
            }
        };
        line("background", Some(self.background));
        line("foreground", Some(self.foreground));
        line("cursor-color", self.cursor);
        line("cursor-text", self.cursor_text);
        line("selection-background", self.selection_background);
        line("selection-foreground", self.selection_foreground);
        for (i, color) in self.palette.iter().enumerate() {
            out.push_str(&format!("palette = {i}=#{}\n", hex6(*color)));
        }
        if let Some(accent) = self.accent {
            out.push_str(&format!("# {THEME_ACCENT_KEY} = #{}\n", hex6(accent)));
        }
        out
    }

    fn to_windows_terminal(&self) -> String {
        let mut fields =
            vec![("name".to_owned(), json_string(self.name.as_deref().unwrap_or("Untitled")))];
        let mut color = |key: &str, color: Option<Rgb>| {
            if let Some(color) = color {
                fields.push((key.to_owned(), format!("\"#{}\"", hex6(color).to_ascii_uppercase())));
            }
        };
        color("background", Some(self.background));
        color("foreground", Some(self.foreground));
        color("cursorColor", self.cursor);
        color("selectionBackground", self.selection_background);
        for (name, ansi) in WT_NAMES.iter().zip(self.palette) {
            color(name, Some(ansi));
        }
        let body: Vec<String> =
            fields.iter().map(|(key, value)| format!("    \"{key}\": {value}")).collect();
        format!("{{\n{}\n}}\n", body.join(",\n"))
    }

    fn to_iterm2(&self) -> String {
        let mut out = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n",
        );
        let mut entry = |key: &str, color: Option<Rgb>| {
            let Some(color) = color else { return };
            out.push_str(&format!("\t<key>{key}</key>\n\t<dict>\n"));
            out.push_str("\t\t<key>Alpha Component</key>\n\t\t<real>1</real>\n");
            out.push_str(&format!(
                "\t\t<key>Blue Component</key>\n\t\t<real>{:.6}</real>\n",
                color.b
            ));
            out.push_str("\t\t<key>Color Space</key>\n\t\t<string>sRGB</string>\n");
            out.push_str(&format!(
                "\t\t<key>Green Component</key>\n\t\t<real>{:.6}</real>\n",
                color.g
            ));
            out.push_str(&format!(
                "\t\t<key>Red Component</key>\n\t\t<real>{:.6}</real>\n",
                color.r
            ));
            out.push_str("\t</dict>\n");
        };
        for (i, color) in self.palette.iter().enumerate() {
            entry(&format!("Ansi {i} Color"), Some(*color));
        }
        entry("Background Color", Some(self.background));
        entry("Cursor Color", self.cursor);
        entry("Cursor Text Color", self.cursor_text);
        entry("Foreground Color", Some(self.foreground));
        entry("Selected Text Color", self.selection_foreground);
        entry("Selection Color", self.selection_background);
        out.push_str("</dict>\n</plist>\n");
        out
    }
}

fn one_line(s: &str) -> String {
    s.chars().map(|c| if c.is_control() { ' ' } else { c }).collect()
}

fn yaml_string(s: &str) -> String {
    json_string(s)
}

fn json_string(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// MARK: base16

/// `baseXX` slot and value of a `baseXX: value` line.
fn base16_slot(line: &str) -> Option<(usize, &str)> {
    let rest = line.strip_prefix("base0").or_else(|| line.strip_prefix("BASE0"))?;
    let (digit, value) = rest.split_once(':')?;
    let mut chars = digit.trim_end().chars();
    let slot = chars.next()?.to_digit(16)?;
    if chars.next().is_some() {
        return None;
    }
    Some((usize::try_from(slot).ok()?, value))
}

/// A YAML scalar without quotes and a trailing ` # comment`.
fn yaml_scalar(value: &str) -> &str {
    let value = value.trim();
    if let Some(inner) = value.strip_prefix('"') {
        return inner.split_once('"').map_or(inner, |(v, _)| v);
    }
    if let Some(inner) = value.strip_prefix('\'') {
        return inner.split_once('\'').map_or(inner, |(v, _)| v);
    }
    value.split_once(" #").map_or(value, |(v, _)| v).trim()
}

fn parse_base16(text: &str, file: &str) -> Result<Scheme, SchemeError> {
    let mut base: [Option<Rgb>; 16] = [None; 16];
    let (mut name, mut author) = (None, None);
    let mut last = 0;
    for (index, raw) in text.lines().enumerate() {
        let number = index.saturating_add(1);
        last = number;
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line == "---" || line == "..." {
            continue;
        }
        if let Some((slot, value)) = base16_slot(line) {
            let scalar = yaml_scalar(value);
            let digits = scalar.strip_prefix('#').unwrap_or(scalar);
            let color = (digits.len() == 6 && digits.bytes().all(|b| b.is_ascii_hexdigit()))
                .then(|| u32::from_str_radix(digits, 16).ok().map(Rgb::hex))
                .flatten()
                .ok_or_else(|| {
                    error(file, number, format!("base0{slot:X} is not a #rrggbb color: {scalar:?}"))
                })?;
            if let Some(entry) = base.get_mut(slot) {
                *entry = Some(color);
            }
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            return Err(error(file, number, format!("not a `key: value` line: {line:?}")));
        };
        let value = yaml_scalar(value);
        match key.trim() {
            "scheme" | "name" if !value.is_empty() => name = Some(value.to_owned()),
            "author" if !value.is_empty() => author = Some(value.to_owned()),
            _ => {}
        }
    }
    let mut colors = [Rgb::BLACK; 16];
    for (slot, (out, color)) in colors.iter_mut().zip(base).enumerate() {
        *out = color.ok_or_else(|| error(file, last, format!("no base0{slot:X} color")))?;
    }
    let at = |i: usize| colors.get(i).copied().unwrap_or(Rgb::BLACK);
    Ok(Scheme {
        name,
        author,
        background: at(0x0),
        foreground: at(0x5),
        cursor: Some(at(0x5)),
        cursor_text: Some(at(0x0)),
        selection_background: Some(at(0x2)),
        selection_foreground: Some(at(0x5)),
        palette: BASE16_ANSI.map(at),
        accent: None,
        base16: Some(colors),
    })
}

// MARK: Ghostty

fn parse_ghostty(text: &str, file: &str) -> Result<Scheme, SchemeError> {
    let default = ThemeInput::GHOSTTY_DEFAULT;
    let mut scheme = Scheme::from_theme_input(&default);
    let mut any = false;
    let mut last = 0;
    let mut name = None;
    for (index, raw) in text.lines().enumerate() {
        let number = index.saturating_add(1);
        last = number;
        let line = raw.trim();
        if let Some(comment) = line.strip_prefix('#') {
            // A leading `# Name` comment names the scheme (as `export` writes it).
            let comment = comment.trim();
            if !any && name.is_none() && !comment.is_empty() && !comment.contains('=') {
                name = Some(comment.split(':').next().unwrap_or(comment).trim().to_owned());
            }
            continue;
        }
        if line.is_empty() {
            continue;
        }
        let (key, value) = match line.split_once('=') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => (line, ""),
        };
        let value = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
        let color = |value: &str| {
            parse_color(value)
                .map(quantized)
                .ok_or_else(|| error(file, number, format!("invalid {key} {value:?}")))
        };
        // `cell-foreground` / `cell-background` follow the cell: no fixed color.
        let optional = |value: &str| {
            if value.is_empty() || value.starts_with("cell-") {
                Ok(None)
            } else {
                color(value).map(Some)
            }
        };
        match key {
            "background" => scheme.background = color(value)?,
            "foreground" => scheme.foreground = color(value)?,
            "cursor-color" => scheme.cursor = optional(value)?,
            "cursor-text" => scheme.cursor_text = optional(value)?,
            "selection-background" => scheme.selection_background = optional(value)?,
            "selection-foreground" => scheme.selection_foreground = optional(value)?,
            "palette" => {
                let bad = || error(file, number, format!("invalid palette {value:?}"));
                let (index, entry) = value.split_once('=').ok_or_else(bad)?;
                let index: usize = index.trim().parse().map_err(|_| bad())?;
                let slot = scheme.palette.get_mut(index).ok_or_else(bad)?;
                *slot = color(entry)?;
            }
            _ => continue,
        }
        any = true;
    }
    if !any {
        return Err(error(file, last, "no colors (background, foreground or palette lines)"));
    }
    scheme.name = name;
    scheme.accent = theme_file_accent(text);
    Ok(scheme)
}

// MARK: Windows Terminal

/// The 1-based line of byte `offset` in `text`.
fn line_of(text: &str, offset: usize) -> usize {
    text.get(..offset.min(text.len()))
        .map_or(1, |head| head.bytes().filter(|b| *b == b'\n').count().saturating_add(1))
}

/// The line a JSON key first appears on (for errors about its value).
fn line_of_key(text: &str, key: &str) -> usize {
    let quoted = format!("\"{key}\"");
    text.find(&quoted).map_or(1, |at| line_of(text, at))
}

fn parse_windows_terminal(text: &str, file: &str) -> Result<Scheme, SchemeError> {
    let doc = json::parse(text).map_err(|message| {
        let at = message
            .rsplit_once("at byte ")
            .and_then(|(_, n)| n.trim().parse::<usize>().ok())
            .unwrap_or(0);
        error(file, line_of(text, at), message)
    })?;
    // A `schemes` array (a whole settings.json) gives its first scheme.
    let scheme = match doc.get("schemes") {
        Some(json::Value::Array(items)) => items.first().cloned().unwrap_or(json::Value::Null),
        _ => doc,
    };
    if !matches!(scheme, json::Value::Object(_)) {
        return Err(error(file, 1, "not a JSON object"));
    }
    let color = |key: &str| -> Result<Option<Rgb>, SchemeError> {
        match scheme.get(key) {
            None | Some(json::Value::Null) => Ok(None),
            Some(json::Value::String(s)) => {
                parse_color(s).map(quantized).map(Some).ok_or_else(|| {
                    error(file, line_of_key(text, key), format!("{key} is not a color: {s:?}"))
                })
            }
            Some(_) => Err(error(file, line_of_key(text, key), format!("{key} is not a string"))),
        }
    };
    let required = |key: &str| -> Result<Rgb, SchemeError> {
        color(key)?.ok_or_else(|| error(file, 1, format!("no {key} color")))
    };
    let mut palette = [Rgb::BLACK; 16];
    for (slot, key) in palette.iter_mut().zip(WT_NAMES) {
        *slot = required(key)?;
    }
    Ok(Scheme {
        name: scheme.get("name").and_then(json::Value::as_str).map(str::to_owned),
        author: None,
        background: required("background")?,
        foreground: required("foreground")?,
        cursor: color("cursorColor")?,
        cursor_text: None,
        selection_background: color("selectionBackground")?,
        selection_foreground: None,
        palette,
        accent: None,
        base16: None,
    })
}

// MARK: iTerm2

/// One XML element or text run of a plist, with its line.
#[derive(Debug, PartialEq)]
enum Token<'a> {
    Open(&'a str),
    Close(&'a str),
    /// `<tag/>`.
    Empty(&'a str),
    Text(&'a str),
}

/// The plist's tags and text, skipping the declaration, doctype and comments.
fn plist_tokens<'a>(text: &'a str, file: &str) -> Result<Vec<(Token<'a>, usize)>, SchemeError> {
    let mut out = Vec::new();
    let mut rest = text;
    let mut line = 1usize;
    while !rest.is_empty() {
        let Some(open) = rest.find('<') else {
            let run = rest.trim();
            if !run.is_empty() {
                out.push((Token::Text(run), line));
            }
            break;
        };
        let (run, tail) = rest.split_at(open);
        if !run.trim().is_empty() {
            let skip = run.len().saturating_sub(run.trim_start().len());
            let at = line.saturating_add(run.get(..skip).map_or(0, |s| s.matches('\n').count()));
            out.push((Token::Text(run.trim()), at));
        }
        line = line.saturating_add(run.matches('\n').count());
        let (end_marker, skip) = if tail.starts_with("<!--") {
            ("-->", true)
        } else if tail.starts_with("<?") || tail.starts_with("<!") {
            (">", true)
        } else {
            (">", false)
        };
        let Some(close) = tail.find(end_marker) else {
            return Err(error(file, line, "unterminated tag"));
        };
        let end = close.saturating_add(end_marker.len());
        let (tag, after) = tail.split_at(end);
        if !skip {
            let inner = tag.trim_start_matches('<').trim_end_matches('>').trim();
            let token = if let Some(name) = inner.strip_prefix('/') {
                Token::Close(name.trim())
            } else if let Some(name) = inner.strip_suffix('/') {
                Token::Empty(name.split_whitespace().next().unwrap_or(""))
            } else {
                Token::Open(inner.split_whitespace().next().unwrap_or(""))
            };
            out.push((token, line));
        }
        line = line.saturating_add(tag.matches('\n').count());
        rest = after;
    }
    Ok(out)
}

/// The value of an iTerm2 color dict: its components and the line it starts on.
#[derive(Default)]
struct PlistColor {
    r: Option<f64>,
    g: Option<f64>,
    b: Option<f64>,
}

fn parse_iterm2(text: &str, file: &str) -> Result<Scheme, SchemeError> {
    let tokens = plist_tokens(text, file)?;
    let mut iter = tokens.iter().peekable();
    // Find the top-level <dict>.
    loop {
        match iter.next() {
            Some((Token::Open("dict"), _)) => break,
            Some((Token::Open("plist") | Token::Close("plist"), _)) => {}
            Some((token, line)) => {
                return Err(error(
                    file,
                    *line,
                    format!("expected the property list's <dict>, found {token:?}"),
                ));
            }
            None => return Err(error(file, line_of(text, text.len()), "no <dict>")),
        }
    }
    let mut colors: Vec<(String, Rgb, usize)> = Vec::new();
    let expect_text = |token: Option<&&(Token<'_>, usize)>,
                       what: &str,
                       at: usize|
     -> Result<String, SchemeError> {
        match token {
            Some((Token::Text(t), _)) => Ok(xml_unescape(t)),
            Some((_, line)) => Err(error(file, *line, format!("expected {what}"))),
            None => Err(error(file, at, format!("expected {what}"))),
        }
    };
    loop {
        let (token, line) = match iter.next() {
            Some((token, line)) => (token, *line),
            None => return Err(error(file, line_of(text, text.len()), "unterminated <dict>")),
        };
        match token {
            Token::Close("dict") => break,
            Token::Open("key") => {}
            other => return Err(error(file, line, format!("expected <key>, found {other:?}"))),
        }
        let key = expect_text(iter.next().as_ref(), "a key name", line)?;
        match iter.next() {
            Some((Token::Close("key"), _)) => {}
            _ => return Err(error(file, line, "expected </key>")),
        }
        match iter.next() {
            Some((Token::Open("dict"), dict_line)) => {
                let mut color = PlistColor::default();
                loop {
                    let (token, line) = match iter.next() {
                        Some((token, line)) => (token, *line),
                        None => return Err(error(file, *dict_line, "unterminated color <dict>")),
                    };
                    match token {
                        Token::Close("dict") => break,
                        Token::Open("key") => {}
                        other => {
                            return Err(error(
                                file,
                                line,
                                format!("expected <key>, found {other:?}"),
                            ));
                        }
                    }
                    let component = expect_text(iter.next().as_ref(), "a key name", line)?;
                    if !matches!(iter.next(), Some((Token::Close("key"), _))) {
                        return Err(error(file, line, "expected </key>"));
                    }
                    let value = match iter.next() {
                        Some((Token::Open(tag @ ("real" | "integer" | "string")), value_line)) => {
                            let value = match iter.peek() {
                                Some((Token::Text(t), _)) => {
                                    iter.next();
                                    xml_unescape(t)
                                }
                                _ => String::new(),
                            };
                            if !matches!(iter.next(), Some((Token::Close(close), _)) if close == tag)
                            {
                                return Err(error(file, *value_line, format!("expected </{tag}>")));
                            }
                            Some((value, *tag, *value_line))
                        }
                        Some((Token::Empty(_), _)) => None,
                        Some((_, line)) => {
                            return Err(error(
                                file,
                                *line,
                                format!("unexpected value for {component}"),
                            ));
                        }
                        None => return Err(error(file, line, "unterminated color <dict>")),
                    };
                    let Some((value, tag, value_line)) = value else { continue };
                    if tag == "string" {
                        continue;
                    }
                    let number: f64 = value.trim().parse().map_err(|_| {
                        error(file, value_line, format!("{component} is not a number: {value:?}"))
                    })?;
                    if !(0.0..=1.0).contains(&number) {
                        return Err(error(
                            file,
                            value_line,
                            format!("{component} {number} is outside 0...1"),
                        ));
                    }
                    match component.as_str() {
                        "Red Component" => color.r = Some(number),
                        "Green Component" => color.g = Some(number),
                        "Blue Component" => color.b = Some(number),
                        _ => {}
                    }
                }
                let (Some(r), Some(g), Some(b)) = (color.r, color.g, color.b) else {
                    return Err(error(
                        file,
                        *dict_line,
                        format!("{key} lacks a red, green or blue component"),
                    ));
                };
                colors.push((key, quantized(Rgb::new(r, g, b, 1.0)), *dict_line));
            }
            Some((Token::Open(tag), value_line)) => {
                // Another value (a string, a number): skip to its close.
                let tag = *tag;
                loop {
                    match iter.next() {
                        Some((Token::Close(close), _)) if *close == tag => break,
                        Some(_) => {}
                        None => {
                            return Err(error(file, *value_line, format!("unterminated <{tag}>")));
                        }
                    }
                }
            }
            Some((Token::Empty(_), _)) => {}
            Some((_, line)) => return Err(error(file, *line, format!("no value for {key}"))),
            None => return Err(error(file, line, format!("no value for {key}"))),
        }
    }
    let find = |key: &str| colors.iter().find(|(k, _, _)| k == key).map(|(_, c, _)| *c);
    let end = line_of(text, text.len());
    let required = |key: &str| find(key).ok_or_else(|| error(file, end, format!("no {key}")));
    let mut palette = [Rgb::BLACK; 16];
    for (i, slot) in palette.iter_mut().enumerate() {
        *slot = required(&format!("Ansi {i} Color"))?;
    }
    Ok(Scheme {
        name: None,
        author: None,
        background: required("Background Color")?,
        foreground: required("Foreground Color")?,
        cursor: find("Cursor Color"),
        cursor_text: find("Cursor Text Color"),
        selection_background: find("Selection Color"),
        selection_foreground: find("Selected Text Color"),
        palette,
        accent: None,
        base16: None,
    })
}

fn xml_unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

// MARK: theme files

/// Whether `name` can be a user theme file's name: one theme name exactly as
/// `theme = NAME` reads it (no `light:`/`dark:` pair, no `,`, `#`, `=`, `"`
/// or control characters; see [`theme_override_value`]), no `/` or `\`, no
/// leading dot, no surrounding spaces, at most 255 bytes (the file-name
/// limit). As Swift `GhosttyThemeFiles.isValidName`.
pub fn is_valid_theme_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && theme_override_value(name) == Some(name)
        && !name.starts_with('.')
        && !name.contains(['/', '\\', ','])
        && !name.starts_with("light:")
        && !name.starts_with("dark:")
}

/// The file of the installed theme `name`: the first of Ghostty's theme
/// directories ([`Env::theme_dirs`]) that has it, user themes first.
pub fn find_theme_file(env: &Env, name: &str) -> Option<PathBuf> {
    if !is_valid_theme_name(name) {
        return None;
    }
    env.theme_dirs().into_iter().map(|dir| dir.join(name)).find(|path| path.is_file())
}

/// Why a scheme was not installed.
#[derive(Debug)]
pub enum InstallError {
    /// Not one theme name Ghostty and the pickers accept as a file name.
    InvalidName,
    /// A theme cmux or Ghostty ships has this name; a user file would hide it.
    ShippedName(PathBuf),
    /// A user theme has this name and replacing it was not asked for.
    Exists(PathBuf),
    /// No config home (`HOME` and `XDG_CONFIG_HOME` unset).
    NoConfigHome,
    Io(PathBuf, std::io::Error),
}

impl fmt::Display for InstallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InstallError::InvalidName => f.write_str(
                "not a theme name (no /, \\, comma, #, =, quote, leading dot or light:/dark: pair)",
            ),
            InstallError::ShippedName(path) => {
                write!(f, "a shipped theme has this name ({})", path.display())
            }
            InstallError::Exists(path) => {
                write!(f, "{} exists (pass replace to overwrite it)", path.display())
            }
            InstallError::NoConfigHome => {
                f.write_str("no config home (HOME and XDG_CONFIG_HOME are unset)")
            }
            InstallError::Io(path, error) => write!(f, "{}: {error}", path.display()),
        }
    }
}

impl std::error::Error for InstallError {}

/// Writes `scheme` as the Ghostty theme file `name` in the user's themes
/// folder (`<config home>/ghostty/themes`, where Ghostty and every cmux
/// picker look), colors only. A shipped theme is never shadowed and a user
/// theme is replaced only when `replace`. Returns the file.
pub fn install_scheme(
    env: &Env,
    name: &str,
    scheme: &Scheme,
    replace: bool,
) -> Result<PathBuf, InstallError> {
    if !is_valid_theme_name(name) {
        return Err(InstallError::InvalidName);
    }
    let user = env.user_theme_dir().ok_or(InstallError::NoConfigHome)?;
    if let Some(shipped) = env
        .theme_dirs()
        .into_iter()
        .filter(|dir| !env.is_user_theme_dir(dir))
        .map(|dir| dir.join(name))
        .find(|p| p.is_file())
    {
        return Err(InstallError::ShippedName(shipped));
    }
    let target = user.join(name);
    if !replace && target.exists() {
        return Err(InstallError::Exists(target));
    }
    std::fs::create_dir_all(&user).map_err(|e| InstallError::Io(user.clone(), e))?;
    let mut named = scheme.clone();
    named.name = Some(name.to_owned());
    // Write beside the target and rename, so Ghostty never reads half a file.
    let partial = user.join(format!(".{name}.cmux-partial"));
    std::fs::write(&partial, named.export(SchemeFormat::Ghostty))
        .and_then(|()| std::fs::rename(&partial, &target))
        .map_err(|e| {
            let _ = std::fs::remove_file(&partial);
            InstallError::Io(target.clone(), e)
        })?;
    Ok(target)
}

#[cfg(test)]
mod tests;
