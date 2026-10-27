//! The spec's `design-tokens.json` (`theme.formulas`, `theme.constants`),
//! compiled into the crate and read once. `ThemeTokens::derive` takes every
//! plain color formula from it, so a changed formula in the json changes the
//! tokens with no code change.
//!
//! A formula's `value` starts with one of these forms (text after the form,
//! such as `: why` or `; with appearance.accent: ...`, is a note):
//! - `= token`: the same color as another formula's token.
//! - `alpha(src, amount)`: `src` at opacity `amount`.
//! - `mix(src, src, amount)`: linear sRGB mix (`Rgb::mixed`).
//!
//! `src` is `bg`, `fg`, `black` or `white`; `amount` is a number,
//! `dark ? a : b` or `background-opacity`. The formulas written as prose
//! (`readable`, `muted`, status colors, `highlightText`, `textSelection`,
//! `accent`) stay in `tokens.rs`. Another form fails loudly: read it, never
//! guess.

use std::sync::OnceLock;

use crate::Rgb;

/// The spec file, relative to this source file (repo root
/// `plans/cmux-next/spec-proposals/visuals/design-tokens.json`).
pub(crate) const DESIGN_TOKENS: &str =
    include_str!("../../../../plans/cmux-next/spec-proposals/visuals/design-tokens.json");

/// A color source in a formula.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Source {
    Bg,
    Fg,
    Black,
    White,
}

/// A formula amount: fixed, by light/dark, or `background-opacity`.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Amount {
    Fixed(f64),
    Pick { dark: f64, light: f64 },
    Opacity,
}

/// One parsed `theme.formulas.<token>.value`.
#[derive(Clone, Debug, PartialEq)]
enum Formula {
    Same(String),
    Alpha(Source, Amount),
    Mix(Source, Source, Amount),
}

/// What a formula is evaluated against.
pub(crate) struct Inputs {
    pub bg: Rgb,
    pub fg: Rgb,
    pub opacity: f64,
    pub is_dark: bool,
}

/// The parsed theme section.
pub(crate) struct Spec {
    formulas: Vec<(String, Formula)>,
    pub minimum_text_contrast: f64,
    pub minimum_mark_contrast: f64,
}

/// The compiled-in spec, parsed on first use. The file is part of the
/// crate and the token oracle (`spec/tests.rs`) parses it and derives every
/// reference theme, so a broken file fails the tests; at run time it gives
/// no formulas (clear colors) rather than a crash.
pub(crate) fn spec() -> &'static Spec {
    static SPEC: OnceLock<Spec> = OnceLock::new();
    SPEC.get_or_init(|| {
        Spec::parse(DESIGN_TOKENS).unwrap_or(Spec {
            formulas: Vec::new(),
            minimum_text_contrast: crate::MINIMUM_TEXT_CONTRAST,
            minimum_mark_contrast: crate::MINIMUM_MARK_CONTRAST,
        })
    })
}

impl Spec {
    pub(crate) fn parse(text: &str) -> Result<Spec, String> {
        let doc = json::parse(text)?;
        let theme = doc.get("theme").ok_or("no theme")?;
        let constant = |key: &str| {
            theme
                .get("constants")
                .and_then(|c| c.get(key))
                .and_then(|c| c.get("value"))
                .and_then(json::Value::as_f64)
                .ok_or_else(|| format!("no theme.constants.{key}.value"))
        };
        let Some(json::Value::Object(entries)) = theme.get("formulas") else {
            return Err("no theme.formulas object".into());
        };
        let mut formulas = Vec::new();
        for (token, entry) in entries {
            let value = entry
                .get("value")
                .and_then(json::Value::as_str)
                .ok_or_else(|| format!("theme.formulas.{token}.value is not a string"))?;
            // Prose formulas are read by name in tokens.rs, not here.
            if let Some(formula) = parse_formula(value) {
                formulas.push((token.clone(), formula));
            }
        }
        Ok(Spec {
            formulas,
            minimum_text_contrast: constant("minimumTextContrast")?,
            minimum_mark_contrast: constant("minimumMarkContrast")?,
        })
    }

    /// `theme.formulas.<token>` for `inputs`; clear when the spec has no
    /// such formula in a form this crate reads (the oracle test catches it).
    pub(crate) fn color(&self, token: &str, inputs: &Inputs) -> Rgb {
        self.eval(token, inputs, 0)
    }

    fn eval(&self, token: &str, inputs: &Inputs, depth: usize) -> Rgb {
        let Some(formula) = self.formulas.iter().find(|(name, _)| name == token).map(|(_, f)| f)
        else {
            return Rgb::default();
        };
        let source = |s: Source| match s {
            Source::Bg => inputs.bg,
            Source::Fg => inputs.fg,
            Source::Black => Rgb::BLACK,
            Source::White => Rgb::WHITE,
        };
        let amount = |a: Amount| match a {
            Amount::Fixed(v) => v,
            Amount::Pick { dark, light } => {
                if inputs.is_dark {
                    dark
                } else {
                    light
                }
            }
            Amount::Opacity => inputs.opacity,
        };
        match formula {
            // A reference loop gives clear (the oracle test catches it).
            Formula::Same(_) if depth >= 8 => Rgb::default(),
            Formula::Same(other) => self.eval(other, inputs, depth + 1),
            Formula::Alpha(s, a) => source(*s).with_alpha(amount(*a)),
            Formula::Mix(from, to, a) => source(*from).mixed(source(*to), amount(*a)),
        }
    }
}

/// The leading formula of a `value`, or `None` when it is prose.
fn parse_formula(value: &str) -> Option<Formula> {
    let value = value.trim();
    if let Some(rest) = value.strip_prefix('=') {
        let name: String =
            rest.trim_start().chars().take_while(char::is_ascii_alphanumeric).collect();
        return (!name.is_empty()).then_some(Formula::Same(name));
    }
    let (op, rest) = value.split_once('(')?;
    let (args, _) = rest.split_once(')')?;
    let args: Vec<&str> = args.split(',').map(str::trim).collect();
    match (op, args.as_slice()) {
        ("alpha", [src, amount]) => Some(Formula::Alpha(parse_source(src)?, parse_amount(amount)?)),
        ("mix", [from, to, amount]) => {
            Some(Formula::Mix(parse_source(from)?, parse_source(to)?, parse_amount(amount)?))
        }
        _ => None,
    }
}

fn parse_source(s: &str) -> Option<Source> {
    match s {
        "bg" => Some(Source::Bg),
        "fg" => Some(Source::Fg),
        "black" => Some(Source::Black),
        "white" => Some(Source::White),
        _ => None,
    }
}

fn parse_amount(s: &str) -> Option<Amount> {
    if s == "background-opacity" {
        return Some(Amount::Opacity);
    }
    if let Some(pick) = s.strip_prefix("dark ?") {
        let (dark, light) = pick.split_once(':')?;
        return Some(Amount::Pick {
            dark: dark.trim().parse().ok()?,
            light: light.trim().parse().ok()?,
        });
    }
    s.parse().ok().map(Amount::Fixed)
}

/// A small JSON reader (the crate has no dependencies). Strict enough for
/// the spec file; numbers are `f64`.
pub(crate) mod json {
    // Bool and Array payloads are read only by the token oracle test.
    #[allow(dead_code)]
    #[derive(Clone, Debug, PartialEq)]
    pub enum Value {
        Null,
        Bool(bool),
        Number(f64),
        String(String),
        Array(Vec<Value>),
        /// Keys in file order.
        Object(Vec<(String, Value)>),
    }

    impl Value {
        pub fn get(&self, key: &str) -> Option<&Value> {
            match self {
                Value::Object(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
                _ => None,
            }
        }

        pub fn as_str(&self) -> Option<&str> {
            if let Value::String(s) = self { Some(s) } else { None }
        }

        pub fn as_f64(&self) -> Option<f64> {
            if let Value::Number(n) = self { Some(*n) } else { None }
        }

        #[cfg(test)]
        pub fn as_array(&self) -> Option<&[Value]> {
            if let Value::Array(items) = self { Some(items) } else { None }
        }

        #[cfg(test)]
        pub fn as_bool(&self) -> Option<bool> {
            if let Value::Bool(b) = self { Some(*b) } else { None }
        }
    }

    pub fn parse(text: &str) -> Result<Value, String> {
        let mut p = Parser { s: text.as_bytes(), i: 0 };
        let v = p.value()?;
        p.ws();
        if p.i != p.s.len() {
            return Err(p.err("trailing text"));
        }
        Ok(v)
    }

    struct Parser<'a> {
        s: &'a [u8],
        i: usize,
    }

    impl Parser<'_> {
        fn err(&self, what: &str) -> String {
            format!("{what} at byte {}", self.i)
        }

        fn ws(&mut self) {
            while self.s.get(self.i).is_some_and(u8::is_ascii_whitespace) {
                self.i += 1;
            }
        }

        fn eat(&mut self, lit: &str) -> bool {
            if self.s.get(self.i..).is_some_and(|rest| rest.starts_with(lit.as_bytes())) {
                self.i += lit.len();
                true
            } else {
                false
            }
        }

        fn value(&mut self) -> Result<Value, String> {
            self.ws();
            let next = self.s.get(self.i).copied();
            match next {
                Some(b'{') => self.object(),
                Some(b'[') => self.array(),
                Some(b'"') => self.string().map(Value::String),
                Some(b't') if self.eat("true") => Ok(Value::Bool(true)),
                Some(b'f') if self.eat("false") => Ok(Value::Bool(false)),
                Some(b'n') if self.eat("null") => Ok(Value::Null),
                Some(b'-' | b'0'..=b'9') => self.number(),
                _ => Err(self.err("unexpected character")),
            }
        }

        fn object(&mut self) -> Result<Value, String> {
            self.i += 1;
            let mut entries = Vec::new();
            self.ws();
            if self.eat("}") {
                return Ok(Value::Object(entries));
            }
            loop {
                self.ws();
                if self.s.get(self.i) != Some(&b'"') {
                    return Err(self.err("expected a key"));
                }
                let key = self.string()?;
                self.ws();
                if !self.eat(":") {
                    return Err(self.err("expected ':'"));
                }
                entries.push((key, self.value()?));
                self.ws();
                if self.eat(",") {
                    continue;
                }
                if self.eat("}") {
                    return Ok(Value::Object(entries));
                }
                return Err(self.err("expected ',' or '}'"));
            }
        }

        fn array(&mut self) -> Result<Value, String> {
            self.i += 1;
            let mut items = Vec::new();
            self.ws();
            if self.eat("]") {
                return Ok(Value::Array(items));
            }
            loop {
                items.push(self.value()?);
                self.ws();
                if self.eat(",") {
                    continue;
                }
                if self.eat("]") {
                    return Ok(Value::Array(items));
                }
                return Err(self.err("expected ',' or ']'"));
            }
        }

        fn string(&mut self) -> Result<String, String> {
            self.i += 1;
            let mut out = String::new();
            loop {
                let start = self.i;
                while let Some(&b) = self.s.get(self.i) {
                    if b == b'"' || b == b'\\' {
                        break;
                    }
                    self.i += 1;
                }
                let run = self.s.get(start..self.i).ok_or_else(|| self.err("bad string"))?;
                out.push_str(std::str::from_utf8(run).map_err(|_| self.err("bad UTF-8"))?);
                match self.s.get(self.i) {
                    Some(b'"') => {
                        self.i += 1;
                        return Ok(out);
                    }
                    Some(b'\\') => {
                        self.i += 1;
                        let c = *self.s.get(self.i).ok_or_else(|| self.err("bad escape"))?;
                        self.i += 1;
                        match c {
                            b'"' => out.push('"'),
                            b'\\' => out.push('\\'),
                            b'/' => out.push('/'),
                            b'b' => out.push('\u{8}'),
                            b'f' => out.push('\u{c}'),
                            b'n' => out.push('\n'),
                            b'r' => out.push('\r'),
                            b't' => out.push('\t'),
                            b'u' => {
                                let unit = self.hex4()?;
                                let code = if (0xD800..0xDC00).contains(&unit) && self.eat("\\u") {
                                    0x10000 + ((unit - 0xD800) << 10) + (self.hex4()? - 0xDC00)
                                } else {
                                    unit
                                };
                                out.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
                            }
                            _ => return Err(self.err("bad escape")),
                        }
                    }
                    _ => return Err(self.err("unterminated string")),
                }
            }
        }

        fn hex4(&mut self) -> Result<u32, String> {
            let digits = self.s.get(self.i..self.i + 4).ok_or_else(|| self.err("bad \\u"))?;
            let v = std::str::from_utf8(digits)
                .ok()
                .and_then(|d| u32::from_str_radix(d, 16).ok())
                .ok_or_else(|| self.err("bad \\u"))?;
            self.i += 4;
            Ok(v)
        }

        fn number(&mut self) -> Result<Value, String> {
            let start = self.i;
            while self
                .s
                .get(self.i)
                .is_some_and(|b| matches!(b, b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9'))
            {
                self.i += 1;
            }
            self.s
                .get(start..self.i)
                .and_then(|n| std::str::from_utf8(n).ok())
                .and_then(|n| n.parse().ok())
                .map(Value::Number)
                .ok_or_else(|| self.err("bad number"))
        }
    }
}

#[cfg(test)]
mod tests;
