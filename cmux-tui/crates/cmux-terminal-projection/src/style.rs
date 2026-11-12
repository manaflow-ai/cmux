//! Cell styles (SGR) and the tables cells point into.

use std::collections::HashMap;
use std::fmt::Write as _;

/// A color as the program set it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Color {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

pub const BOLD: u16 = 1;
pub const FAINT: u16 = 1 << 1;
pub const ITALIC: u16 = 1 << 2;
pub const BLINK: u16 = 1 << 3;
pub const INVERSE: u16 = 1 << 4;
pub const INVISIBLE: u16 = 1 << 5;
pub const STRIKE: u16 = 1 << 6;
pub const OVERLINE: u16 = 1 << 7;

/// The style of a cell: SGR attributes and the hyperlink (OSC 8) it is in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub underline_color: Color,
    pub flags: u16,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    pub underline: u8,
    /// Index into the link table (0: no link).
    pub link: u32,
}

impl Style {
    /// What an erase leaves: the background only (BCE).
    pub fn erased(self) -> Style {
        Style { bg: self.bg, ..Style::default() }
    }

    /// A blank cell in this style looks like no cell at all.
    pub fn is_invisible_when_blank(self) -> bool {
        self.bg == Color::Default
            && self.flags & (INVERSE | STRIKE | OVERLINE) == 0
            && self.underline == 0
    }

    /// Applies one SGR sequence (its parameters, `:` sub-parameters kept).
    pub fn apply_sgr(&mut self, params: &[Vec<u16>]) {
        if params.is_empty() {
            *self = Style { link: self.link, ..Style::default() };
            return;
        }
        let mut i = 0;
        while i < params.len() {
            let group = &params[i];
            let code = group.first().copied().unwrap_or(0);
            match code {
                0 => *self = Style { link: self.link, ..Style::default() },
                1 => self.flags |= BOLD,
                2 => self.flags |= FAINT,
                3 => self.flags |= ITALIC,
                4 => {
                    self.underline = match group.get(1) {
                        Some(&kind) => kind.min(5) as u8,
                        None => 1,
                    }
                }
                5 | 6 => self.flags |= BLINK,
                7 => self.flags |= INVERSE,
                8 => self.flags |= INVISIBLE,
                9 => self.flags |= STRIKE,
                21 => self.underline = 2,
                22 => self.flags &= !(BOLD | FAINT),
                23 => self.flags &= !ITALIC,
                24 => self.underline = 0,
                25 => self.flags &= !BLINK,
                27 => self.flags &= !INVERSE,
                28 => self.flags &= !INVISIBLE,
                29 => self.flags &= !STRIKE,
                30..=37 => self.fg = Color::Indexed((code - 30) as u8),
                39 => self.fg = Color::Default,
                40..=47 => self.bg = Color::Indexed((code - 40) as u8),
                49 => self.bg = Color::Default,
                53 => self.flags |= OVERLINE,
                55 => self.flags &= !OVERLINE,
                59 => self.underline_color = Color::Default,
                90..=97 => self.fg = Color::Indexed((code - 90 + 8) as u8),
                100..=107 => self.bg = Color::Indexed((code - 100 + 8) as u8),
                38 | 48 | 58 => {
                    let (color, used) = if group.len() > 1 {
                        (extended_color(&group[1..], true), 0)
                    } else {
                        let rest: Vec<u16> = params[i + 1..]
                            .iter()
                            .map(|g| g.first().copied().unwrap_or(0))
                            .collect();
                        let used = match rest.first() {
                            Some(5) => 2,
                            Some(2) => 4,
                            _ => rest.len(),
                        };
                        (extended_color(&rest, false), used.min(rest.len()))
                    };
                    if let Some(color) = color {
                        match code {
                            38 => self.fg = color,
                            48 => self.bg = color,
                            _ => self.underline_color = color,
                        }
                    }
                    i += used;
                }
                _ => {}
            }
            i += 1;
        }
    }

    /// The SGR that sets exactly this style from any state (`ESC[0;...m`).
    pub fn write_sgr(self, out: &mut Vec<u8>) {
        let mut s = String::from("\x1b[0");
        let flag = |s: &mut String, bit: u16, code: &str| {
            if self.flags & bit != 0 {
                s.push(';');
                s.push_str(code);
            }
        };
        flag(&mut s, BOLD, "1");
        flag(&mut s, FAINT, "2");
        flag(&mut s, ITALIC, "3");
        match self.underline {
            0 => {}
            1 => s.push_str(";4"),
            kind => {
                let _ = write!(s, ";4:{kind}");
            }
        }
        flag(&mut s, BLINK, "5");
        flag(&mut s, INVERSE, "7");
        flag(&mut s, INVISIBLE, "8");
        flag(&mut s, STRIKE, "9");
        flag(&mut s, OVERLINE, "53");
        write_color(&mut s, self.fg, 30, 90, 38);
        write_color(&mut s, self.bg, 40, 100, 48);
        match self.underline_color {
            Color::Default => {}
            Color::Indexed(n) => {
                let _ = write!(s, ";58:5:{n}");
            }
            Color::Rgb(r, g, b) => {
                let _ = write!(s, ";58:2::{r}:{g}:{b}");
            }
        }
        s.push('m');
        out.extend_from_slice(s.as_bytes());
    }
}

fn write_color(s: &mut String, color: Color, base: u8, bright: u8, extended: u8) {
    match color {
        Color::Default => {}
        Color::Indexed(n) if n < 8 => {
            let _ = write!(s, ";{}", base + n);
        }
        Color::Indexed(n) if n < 16 => {
            let _ = write!(s, ";{}", bright + n - 8);
        }
        Color::Indexed(n) => {
            let _ = write!(s, ";{extended};5;{n}");
        }
        Color::Rgb(r, g, b) => {
            let _ = write!(s, ";{extended};2;{r};{g};{b}");
        }
    }
}

/// `5;n` or `2;r;g;b` (with `colon`, `2::r:g:b` or `2:r:g:b` too).
fn extended_color(rest: &[u16], colon: bool) -> Option<Color> {
    match rest.first()? {
        5 => Some(Color::Indexed((*rest.get(1)?).min(255) as u8)),
        2 => {
            // `38:2::r:g:b` carries a color space id first.
            let rgb = if colon && rest.len() >= 5 { &rest[2..5] } else { rest.get(1..4)? };
            let c = |v: u16| v.min(255) as u8;
            Some(Color::Rgb(c(rgb[0]), c(rgb[1]), c(rgb[2])))
        }
        _ => None,
    }
}

/// Styles, interned: a cell holds a `u16` id. Id 0 is the default style.
#[derive(Debug)]
pub struct StyleTable {
    styles: Vec<Style>,
    ids: HashMap<Style, u16>,
}

impl Default for StyleTable {
    fn default() -> Self {
        let mut ids = HashMap::new();
        ids.insert(Style::default(), 0);
        Self { styles: vec![Style::default()], ids }
    }
}

impl StyleTable {
    pub fn id(&mut self, style: Style) -> u16 {
        if let Some(&id) = self.ids.get(&style) {
            return id;
        }
        // Past u16 ids a style draws as the default one: never seen in practice.
        let Ok(id) = u16::try_from(self.styles.len()) else { return 0 };
        self.styles.push(style);
        self.ids.insert(style, id);
        id
    }

    pub fn get(&self, id: u16) -> Style {
        self.styles.get(usize::from(id)).copied().unwrap_or_default()
    }
}

/// Strings interned by index: graphemes (a base and its combining marks) and
/// hyperlinks. Index 0 is never handed out.
#[derive(Debug, Default)]
pub struct Interner {
    items: Vec<Box<str>>,
    ids: HashMap<Box<str>, u32>,
}

impl Interner {
    pub fn id(&mut self, item: &str) -> u32 {
        if self.items.is_empty() {
            self.items.push("".into());
        }
        if let Some(&id) = self.ids.get(item) {
            return id;
        }
        let id = u32::try_from(self.items.len()).unwrap_or(0);
        self.items.push(item.into());
        self.ids.insert(item.into(), id);
        id
    }

    pub fn get(&self, id: u32) -> &str {
        self.items.get(id as usize).map_or("", |s| s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sgr(text: &str) -> Vec<Vec<u16>> {
        text.split(';').map(|g| g.split(':').map(|v| v.parse().unwrap_or(0)).collect()).collect()
    }

    #[test]
    fn sgr_round_trips() {
        for text in ["1;31", "38;5;200;48;2;1;2;3", "4:3;58:2::9:8:7", "7;9;53;97;104", "2;3;5;8"] {
            let mut style = Style::default();
            style.apply_sgr(&sgr(text));
            let mut out = Vec::new();
            style.write_sgr(&mut out);
            let written = String::from_utf8(out).unwrap();
            let inner = &written[2..written.len() - 1];
            let mut again = Style::default();
            again.apply_sgr(&sgr(inner));
            assert_eq!(style, again, "{text} -> {written}");
        }
    }

    #[test]
    fn reset_keeps_the_link() {
        let mut style = Style { link: 3, flags: BOLD, ..Style::default() };
        style.apply_sgr(&sgr("0"));
        assert_eq!(style.link, 3);
        assert_eq!(style.flags, 0);
    }
}
