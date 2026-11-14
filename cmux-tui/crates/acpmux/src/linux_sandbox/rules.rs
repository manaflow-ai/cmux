//! Seatbelt file policy, staged independently of Linux sandbox activation.
//! All loops consume finite input or collections; parsing stops at EOF/error,
//! with at most 32 nested expressions and 64 KiB of profile text. No I/O occurs.
//! Paths must already be resolved in the target's view, including symlinks.
//! Stricter than Seatbelt: noncanonical, non-UTF-8 and newline paths are refused;
//! unmatched writes are denied, and unsupported file rules reject the profile.

// No production caller until the Linux sandbox wiring lands.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use regex::Regex;

pub(crate) type Params = BTreeMap<String, PathBuf>;

#[derive(Debug, thiserror::Error)]
#[error("unsupported Seatbelt profile: {0}")]
pub(crate) struct ParseError(pub(crate) String);

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Denied {
    pub(crate) rule: String,
}

#[derive(Debug)]
pub(crate) struct WritePolicy {
    pub(crate) skipped: Vec<String>,
    writes: Vec<WriteRule>,
    reads: Vec<PathBuf>,
}

#[derive(Debug)]
struct WriteRule {
    allow: bool,
    text: String,
    filters: Vec<Filter>,
}

#[derive(Debug)]
enum Filter {
    Subpath(PathBuf),
    Literal(PathBuf),
    Regex(Regex),
}

impl WritePolicy {
    /// Use `crate::hub::remote_sandbox::PROFILE` for the production policy.
    /// Parse both write rules and read masks; unsupported file forms fail closed.
    /// The loop ends at EOF or the first invalid form.
    pub(crate) fn from_profile(sb: &str, params: &Params) -> Result<Self, ParseError> {
        if sb.len() > 64 * 1024 {
            return Err(ParseError("profile exceeds 64 KiB".into()));
        }
        let mut out = Self { skipped: Vec::new(), writes: Vec::new(), reads: Vec::new() };
        let mut reader = Reader(sb);
        reader.space();
        while !reader.0.is_empty() {
            let start = reader.0;
            let node = reader.expr(0)?;
            let text = start.get(..start.len() - reader.0.len()).unwrap_or("");
            let items = node.list()?;
            match items {
                [Expr::Atom("version"), Expr::Atom("1")]
                | [Expr::Atom("allow"), Expr::Atom("default")] => {
                    out.skipped.push(text.into());
                }
                [Expr::Atom(action @ ("allow" | "deny")), Expr::Atom(op), filters @ ..] => {
                    let allow = *action == "allow";
                    match *op {
                        "file-write*" | "file-read*" => {
                            if filters.is_empty() || (*op == "file-read*" && allow) {
                                return Err(ParseError(text.into()));
                            }
                            let filters = filters
                                .iter()
                                .map(|f| filter(f, params))
                                .collect::<Result<Vec<_>, _>>()?;
                            if *op == "file-write*" {
                                out.writes.push(WriteRule { allow, text: text.into(), filters });
                            } else {
                                for f in filters {
                                    match f {
                                        Filter::Subpath(p) | Filter::Literal(p) => {
                                            out.reads.push(p)
                                        }
                                        Filter::Regex(_) => return Err(ParseError(text.into())),
                                    }
                                }
                            }
                        }
                        _ if skipped(op, filters, allow) => {
                            out.skipped.push(text.into());
                        }
                        _ => return Err(ParseError(text.into())),
                    }
                }
                _ => return Err(ParseError(text.into())),
            }
            reader.space();
        }
        Ok(out)
    }

    /// The caller must resolve symlinks in the target's view before checking.
    /// The reverse scan stops at the first matching rule or after all rules.
    pub(crate) fn check(&self, path: &Path) -> Result<(), Denied> {
        let text = canonical_text(path).map_err(|e| Denied { rule: e.0 })?;
        for rule in self.writes.iter().rev() {
            if rule.filters.iter().any(|f| match f {
                Filter::Subpath(p) => path.starts_with(p),
                Filter::Literal(p) => path == p,
                Filter::Regex(r) => r.is_match(text),
            }) {
                return if rule.allow { Ok(()) } else { Err(Denied { rule: rule.text.clone() }) };
            }
        }
        Err(Denied { rule: "implicit deny: no matching file-write* rule".into() })
    }

    /// Read masks from a successfully parsed profile, without filesystem I/O.
    pub(crate) fn read_denies(&self) -> Vec<PathBuf> {
        self.reads.clone()
    }
}

/// Non-file operations belong to other layers, but never skip executable Scheme
/// expressions: a nested expression could itself install a file rule.
fn skipped(op: &str, filters: &[Expr<'_>], allow: bool) -> bool {
    if !allow && filters.is_empty() {
        return matches!(
            op,
            "file-link"
                | "file-mount"
                | "user-preference-write"
                | "mach-lookup"
                | "job-creation"
                | "lsopen"
                | "appleevent-send"
                | "signal"
                | "mach-priv-task-port"
                | "network-bind"
                | "network-inbound"
                | "network-outbound"
        );
    }
    !filters.is_empty()
        && filters.iter().all(|f| match f {
            Expr::List(v) => match (op, v.as_slice()) {
                ("mach-lookup", [Expr::Atom("global-name"), Expr::Text(_)]) => true,
                ("signal", [Expr::Atom("target"), Expr::Atom("same-sandbox")]) => true,
                ("network-outbound", [Expr::Atom("remote"), Expr::Atom("ip"), Expr::Text(_)]) => {
                    true
                }
                (
                    "network-outbound",
                    [Expr::Atom("remote"), Expr::Atom("unix-socket"), Expr::List(v)],
                ) => {
                    matches!(v.as_slice(), [Expr::Atom("path-literal"), Expr::Text(_)])
                }
                _ => false,
            },
            _ => false,
        })
}

fn canonical_text(path: &Path) -> Result<&str, ParseError> {
    let valid = path.to_str().filter(|s| {
        s.starts_with('/')
            && !s.contains(['\0', '\n', '\r'])
            && (*s == "/"
                || s.get(1..).unwrap_or("").split('/').all(|p| !matches!(p, "" | "." | "..")))
    });
    valid.ok_or_else(|| {
        ParseError("path must be canonical absolute UTF-8 without NUL/newlines".into())
    })
}

fn path_value(expr: &Expr<'_>, params: &Params) -> Result<String, ParseError> {
    match expr {
        Expr::Text(s) => Ok(s.clone()),
        Expr::List(v) => match v.as_slice() {
            [Expr::Atom("param"), Expr::Text(name)]
                if matches!(
                    name.as_str(),
                    "CWD" | "TMPDIR" | "HOME" | "CLAUDE_TMP_PROJECT" | "CLAUDE_PROJECT"
                ) =>
            {
                let p =
                    params.get(name).ok_or_else(|| ParseError(format!("missing param {name}")))?;
                Ok(canonical_text(p)?.into())
            }
            [Expr::Atom("string-append"), param @ Expr::List(v), Expr::Text(suffix)]
                if matches!(v.as_slice(), [Expr::Atom("param"), Expr::Text(_)]) =>
            {
                Ok(path_value(param, params)? + suffix)
            }
            _ => Err(ParseError("unsupported path expression".into())),
        },
        _ => Err(ParseError("expected a path string".into())),
    }
}

fn filter(expr: &Expr<'_>, params: &Params) -> Result<Filter, ParseError> {
    match expr.list()? {
        [Expr::Atom(kind @ ("subpath" | "literal")), value] => {
            let p = PathBuf::from(path_value(value, params)?);
            canonical_text(&p)?;
            Ok(if *kind == "subpath" { Filter::Subpath(p) } else { Filter::Literal(p) })
        }
        [Expr::Atom("regex"), Expr::Raw(s)] => Ok(Filter::Regex(profile_regex(s)?)),
        _ => Err(ParseError("unsupported file predicate".into())),
    }
}

/// Accept only the regular-expression syntax used here, plus explicit '^'.
/// The loop stops when the finite regex input is exhausted or syntax is refused.
fn profile_regex(s: &str) -> Result<Regex, ParseError> {
    let bad = || ParseError(format!("unsupported regex {s:?}"));
    let mut chars = s.chars();
    let mut previous = None;
    while let Some(c) = chars.next() {
        if c == '\\' {
            if chars.next() != Some('.') {
                return Err(bad());
            }
            previous = None;
            continue;
        }
        if !(c.is_ascii_alphanumeric() || "/_-().|*+?^$".contains(c))
            || (c == '?' && previous == Some('('))
            || (matches!(c, '*' | '+' | '?')
                && previous.is_some_and(|p| matches!(p, '*' | '+' | '?')))
        {
            return Err(bad());
        }
        previous = Some(c);
    }
    // No anchoring is added: Seatbelt searches the entire absolute path.
    Regex::new(s).map_err(|e| ParseError(format!("regex {s:?}: {e}")))
}

#[derive(Debug)]
enum Expr<'a> {
    Atom(&'a str),
    Text(String),
    Raw(String),
    List(Vec<Expr<'a>>),
}

impl<'a> Expr<'a> {
    fn list(&self) -> Result<&[Expr<'a>], ParseError> {
        match self {
            Self::List(v) => Ok(v),
            _ => Err(ParseError("expected a list".into())),
        }
    }
}

struct Reader<'a>(&'a str);

impl<'a> Reader<'a> {
    /// Stops at the next token or EOF, consuming whitespace and each comment.
    fn space(&mut self) {
        loop {
            self.0 = self.0.trim_start_matches(|c: char| c.is_ascii_whitespace());
            if !self.0.starts_with(';') {
                break;
            }
            self.0 = self.0.split_once('\n').map_or("", |(_, rest)| rest);
        }
    }

    /// Each iteration consumes a character or child; EOF, ')' or error stops it.
    /// Recursion is capped at 32, including for ignored non-file forms.
    fn expr(&mut self, depth: usize) -> Result<Expr<'a>, ParseError> {
        if depth >= 32 {
            return Err(ParseError("expression nesting exceeds 32".into()));
        }
        self.space();
        if self.0.starts_with('(') {
            self.0 = self.0.get(1..).unwrap_or("");
            let mut children = Vec::new();
            loop {
                self.space();
                if self.0.starts_with(')') {
                    self.0 = self.0.get(1..).unwrap_or("");
                    return Ok(Expr::List(children));
                }
                children.push(self.expr(depth + 1)?);
            }
        }
        let raw = self.0.starts_with("#\"");
        if raw || self.0.starts_with('"') {
            self.0 = self.0.get(if raw { 2 } else { 1 }..).unwrap_or("");
            let mut value = String::new();
            while let Some(c) = self.0.chars().next() {
                self.0 = self.0.get(c.len_utf8()..).unwrap_or("");
                match c {
                    '"' => return Ok(if raw { Expr::Raw(value) } else { Expr::Text(value) }),
                    '\\' if !raw => {
                        let c = self
                            .0
                            .chars()
                            .next()
                            .filter(|c| matches!(*c, '\\' | '"'))
                            .ok_or_else(|| ParseError("unsupported string escape".into()))?;
                        self.0 = self.0.get(c.len_utf8()..).unwrap_or("");
                        value.push(c);
                    }
                    _ => value.push(c),
                }
            }
            return Err(ParseError("unterminated string".into()));
        }
        let end = self
            .0
            .find(|c: char| c.is_ascii_whitespace() || "();\"#".contains(c))
            .unwrap_or(self.0.len());
        if end == 0 {
            return Err(ParseError("expected expression".into()));
        }
        let (atom, rest) = self.0.split_at(end);
        self.0 = rest;
        Ok(Expr::Atom(atom))
    }
}

#[cfg(test)]
mod tests;
