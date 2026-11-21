//! Just enough JSON for wsfactory's output and its own record files. Every file the
//! parser reads was written by `Obj`'s Display, so it handles that plus ordinary JSON.

use std::fmt::{self, Write as _};

#[derive(Clone, Debug, PartialEq)]
pub enum Val {
    Null,
    Bool(bool),
    Int(i64),
    Num(f64),
    Str(String),
    Arr(Vec<Val>),
    Obj(Obj),
}

/// An object that keeps its keys in insertion order, so output reads the way it was built.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Obj(pub Vec<(String, Val)>);

impl Obj {
    pub fn new() -> Self {
        Obj(Vec::new())
    }

    pub fn with(mut self, key: &str, val: impl Into<Val>) -> Self {
        self.set(key, val);
        self
    }

    pub fn set(&mut self, key: &str, val: impl Into<Val>) {
        let val = val.into();
        match self.0.iter_mut().find(|(k, _)| k == key) {
            Some(entry) => entry.1 = val,
            None => self.0.push((key.to_string(), val)),
        }
    }

    pub fn get(&self, key: &str) -> Option<&Val> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        match self.get(key) {
            Some(Val::Str(s)) => Some(s),
            _ => None,
        }
    }

    pub fn int(&self, key: &str) -> Option<i64> {
        match self.get(key) {
            Some(Val::Int(n)) => Some(*n),
            _ => None,
        }
    }

    pub fn bool(&self, key: &str) -> Option<bool> {
        match self.get(key) {
            Some(Val::Bool(b)) => Some(*b),
            _ => None,
        }
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn arr(&self, key: &str) -> Option<&[Val]> {
        match self.get(key) {
            Some(Val::Arr(a)) => Some(a),
            _ => None,
        }
    }
}

impl From<bool> for Val {
    fn from(b: bool) -> Self {
        Val::Bool(b)
    }
}
impl From<i64> for Val {
    fn from(n: i64) -> Self {
        Val::Int(n)
    }
}
impl From<u64> for Val {
    fn from(n: u64) -> Self {
        Val::Int(n.min(i64::MAX as u64) as i64)
    }
}
impl From<f64> for Val {
    fn from(n: f64) -> Self {
        Val::Num(n)
    }
}
impl From<&str> for Val {
    fn from(s: &str) -> Self {
        Val::Str(s.to_string())
    }
}
impl From<String> for Val {
    fn from(s: String) -> Self {
        Val::Str(s)
    }
}
impl From<Obj> for Val {
    fn from(o: Obj) -> Self {
        Val::Obj(o)
    }
}
impl<T: Into<Val>> From<Vec<T>> for Val {
    fn from(v: Vec<T>) -> Self {
        Val::Arr(v.into_iter().map(Into::into).collect())
    }
}
impl<T: Into<Val>> From<Option<T>> for Val {
    fn from(v: Option<T>) -> Self {
        v.map_or(Val::Null, Into::into)
    }
}

fn write_str(f: &mut fmt::Formatter<'_>, s: &str) -> fmt::Result {
    f.write_char('"')?;
    for c in s.chars() {
        match c {
            '"' => f.write_str("\\\"")?,
            '\\' => f.write_str("\\\\")?,
            '\n' => f.write_str("\\n")?,
            '\r' => f.write_str("\\r")?,
            '\t' => f.write_str("\\t")?,
            c if (c as u32) < 0x20 => write!(f, "\\u{:04x}", c as u32)?,
            c => f.write_char(c)?,
        }
    }
    f.write_char('"')
}

impl fmt::Display for Val {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Val::Null => f.write_str("null"),
            Val::Bool(b) => write!(f, "{b}"),
            Val::Int(n) => write!(f, "{n}"),
            Val::Num(n) if n.is_finite() => write!(f, "{n:.3}"),
            Val::Num(_) => f.write_str("null"),
            Val::Str(s) => write_str(f, s),
            Val::Arr(a) => {
                f.write_char('[')?;
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        f.write_char(',')?;
                    }
                    write!(f, "{v}")?;
                }
                f.write_char(']')
            }
            Val::Obj(o) => write!(f, "{o}"),
        }
    }
}

impl fmt::Display for Obj {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_char('{')?;
        for (i, (k, v)) in self.0.iter().enumerate() {
            if i > 0 {
                f.write_char(',')?;
            }
            write_str(f, k)?;
            write!(f, ":{v}")?;
        }
        f.write_char('}')
    }
}

/// Parses a document whose top level is an object.
pub fn parse_obj(text: &str) -> Result<Obj, String> {
    let mut p = Parser {
        s: text.as_bytes(),
        i: 0,
    };
    let v = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err(format!("trailing data at byte {}", p.i));
    }
    match v {
        Val::Obj(o) => Ok(o),
        _ => Err("top level is not an object".into()),
    }
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }

    fn err<T>(&self, what: &str) -> Result<T, String> {
        Err(format!("{what} at byte {}", self.i))
    }

    fn eat(&mut self, lit: &str) -> bool {
        if self.s[self.i..].starts_with(lit.as_bytes()) {
            self.i += lit.len();
            true
        } else {
            false
        }
    }

    fn value(&mut self) -> Result<Val, String> {
        self.ws();
        match self.s.get(self.i) {
            None => self.err("unexpected end"),
            Some(b'{') => {
                self.i += 1;
                let mut o = Obj::new();
                self.ws();
                if self.eat("}") {
                    return Ok(Val::Obj(o));
                }
                loop {
                    self.ws();
                    let k = self.string()?;
                    self.ws();
                    if !self.eat(":") {
                        return self.err("expected ':'");
                    }
                    let v = self.value()?;
                    o.0.push((k, v));
                    self.ws();
                    if self.eat(",") {
                        continue;
                    }
                    if self.eat("}") {
                        return Ok(Val::Obj(o));
                    }
                    return self.err("expected ',' or '}'");
                }
            }
            Some(b'[') => {
                self.i += 1;
                let mut a = Vec::new();
                self.ws();
                if self.eat("]") {
                    return Ok(Val::Arr(a));
                }
                loop {
                    a.push(self.value()?);
                    self.ws();
                    if self.eat(",") {
                        continue;
                    }
                    if self.eat("]") {
                        return Ok(Val::Arr(a));
                    }
                    return self.err("expected ',' or ']'");
                }
            }
            Some(b'"') => Ok(Val::Str(self.string()?)),
            Some(b't') if self.eat("true") => Ok(Val::Bool(true)),
            Some(b'f') if self.eat("false") => Ok(Val::Bool(false)),
            Some(b'n') if self.eat("null") => Ok(Val::Null),
            Some(c) if *c == b'-' || c.is_ascii_digit() => {
                let start = self.i;
                while self.i < self.s.len()
                    && matches!(
                        self.s[self.i],
                        b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9'
                    )
                {
                    self.i += 1;
                }
                let t = std::str::from_utf8(&self.s[start..self.i]).unwrap_or("");
                if let Ok(n) = t.parse::<i64>() {
                    return Ok(Val::Int(n));
                }
                t.parse::<f64>()
                    .map(Val::Num)
                    .or_else(|_| self.err("bad number"))
            }
            Some(_) => self.err("unexpected character"),
        }
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let t = self
            .s
            .get(self.i..self.i + 4)
            .and_then(|b| std::str::from_utf8(b).ok());
        let n = t.and_then(|t| u32::from_str_radix(t, 16).ok());
        self.i += 4;
        n.map_or_else(|| self.err("bad \\u escape"), Ok)
    }

    fn string(&mut self) -> Result<String, String> {
        if !self.eat("\"") {
            return self.err("expected string");
        }
        let mut out = Vec::new();
        loop {
            let Some(&c) = self.s.get(self.i) else {
                return self.err("unterminated string");
            };
            self.i += 1;
            match c {
                b'"' => break,
                b'\\' => {
                    let Some(&e) = self.s.get(self.i) else {
                        return self.err("unterminated escape");
                    };
                    self.i += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let mut n = self.hex4()?;
                            // A high surrogate pairs with the \uXXXX that follows it.
                            if (0xd800..0xdc00).contains(&n) && self.eat("\\u") {
                                let lo = self.hex4()?;
                                n = 0x10000
                                    + ((n - 0xd800) << 10)
                                    + (lo.wrapping_sub(0xdc00) & 0x3ff);
                            }
                            char::from_u32(n).map_or_else(|| self.err("bad code point"), Ok)?
                        }
                        _ => return self.err("bad escape"),
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                c => out.push(c),
            }
        }
        String::from_utf8(out).or_else(|_| self.err("string is not UTF-8"))
    }
}
