//! Which tests nextest runs beside others: cmux-tui/.config/nextest.toml read with `toml` (any
//! TOML quoting) and its filtersets parsed, matched against a test's nextest name (module path::fn)
//! and binary id from its crate's Cargo.toml.
//!
//! A test runs alone, or not at all, when in every profile CI uses (`ci` and `default`; the
//! default profile's overrides apply to `ci` too) the first override whose filter matches it sets
//! `threads-required = 'num-test-threads'` with no `platform`, or the profile's `default-filter`
//! leaves it out, or the profile runs one test thread.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use crate::source::ReadError;

/// A test as nextest names it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TestId {
    /// Module path and fn: `hub::peer_notice_cost_tests::resolves`.
    pub name: String,
    pub binary_id: Option<String>,
    pub binary: Option<String>,
    pub package: Option<String>,
    pub kind: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Matcher {
    Equal,
    Contains,
    Glob,
    Regex,
}

/// A filterset expression.
#[derive(Debug, Clone)]
pub enum Filter {
    All,
    None,
    Not(Box<Filter>),
    And(Box<Filter>, Box<Filter>),
    /// `a - b`: a and not b.
    Diff(Box<Filter>, Box<Filter>),
    Or(Box<Filter>, Box<Filter>),
    Match {
        func: String,
        matcher: Matcher,
        value: String,
        regex: Option<regex::Regex>,
    },
    /// A function a source scan can't answer (`deps()`, `platform()`, one nextest adds later).
    Unknown,
}

fn default_matcher(func: &str) -> Option<Matcher> {
    Some(match func {
        "test" | "binary" => Matcher::Contains,
        "package" | "binary_id" | "deps" | "rdeps" => Matcher::Glob,
        "kind" | "platform" => Matcher::Equal,
        _ => return None,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Op(String),
    Fn(String, String),
}

/// Parse a filterset (`test(=a) | binary_id(demo::*) & not test(/^b/)`).
pub fn parse_filter(text: &str) -> Result<Filter, String> {
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut toks = Vec::new();
    let mut i = 0;
    while let Some(&c) = chars.get(i) {
        if c.is_whitespace() {
            i += 1;
        } else if "()&|+-!".contains(c) {
            toks.push(Tok::Op(c.to_string()));
            i += 1;
        } else if c.is_alphabetic() || c == '_' {
            let mut j = i;
            while chars.get(j).is_some_and(|c| c.is_alphanumeric() || *c == '_') {
                j += 1;
            }
            let word: String = chars.get(i..j).unwrap_or_default().iter().collect();
            let mut k = j;
            while chars.get(k).is_some_and(|c| c.is_whitespace()) {
                k += 1;
            }
            if !matches!(word.as_str(), "and" | "or" | "not") && chars.get(k) == Some(&'(') {
                k += 1;
                while chars.get(k).is_some_and(|c| c.is_whitespace()) {
                    k += 1;
                }
                let arg_start = k;
                if chars.get(k) == Some(&'/') {
                    k += 1;
                    while let Some(&c) = chars.get(k).filter(|c| **c != '/') {
                        k += if c == '\\' { 2 } else { 1 };
                    }
                    k += 1;
                }
                while let Some(&c) = chars.get(k).filter(|c| **c != ')') {
                    k += if c == '\\' { 2 } else { 1 };
                }
                let Some(arg) = chars.get(arg_start..k).filter(|_| k < n) else {
                    return Err(format!("unclosed {word}( in {text:?}"));
                };
                let arg: String = arg.iter().collect();
                toks.push(Tok::Fn(word, arg.trim().to_string()));
                i = k + 1;
            } else {
                toks.push(Tok::Op(word));
                i = j;
            }
        } else {
            return Err(format!("unexpected {c:?} in {text:?}"));
        }
    }
    let mut parser = FilterParser { toks, pos: 0, text };
    let tree = parser.or_expr()?;
    if let Some(tok) = parser.peek() {
        return Err(format!("unexpected {tok:?} in {text:?}"));
    }
    Ok(tree)
}

struct FilterParser<'t> {
    toks: Vec<Tok>,
    pos: usize,
    text: &'t str,
}

impl FilterParser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn peek_op(&self, ops: &[&str]) -> Option<String> {
        match self.peek() {
            Some(Tok::Op(op)) if ops.contains(&op.as_str()) => Some(op.clone()),
            _ => None,
        }
    }

    fn or_expr(&mut self) -> Result<Filter, String> {
        let mut left = self.and_expr()?;
        while self.peek_op(&["|", "or", "+"]).is_some() {
            self.pos += 1;
            left = Filter::Or(Box::new(left), Box::new(self.and_expr()?));
        }
        Ok(left)
    }

    fn and_expr(&mut self) -> Result<Filter, String> {
        let mut left = self.unary()?;
        while let Some(op) = self.peek_op(&["&", "and", "-"]) {
            self.pos += 1;
            let right = self.unary()?;
            left = if op == "-" {
                Filter::Diff(Box::new(left), Box::new(right))
            } else {
                Filter::And(Box::new(left), Box::new(right))
            };
        }
        Ok(left)
    }

    fn unary(&mut self) -> Result<Filter, String> {
        let text = self.text;
        let Some(tok) = self.peek().cloned() else {
            return Err(format!("filter ends early: {text:?}"));
        };
        self.pos += 1;
        match tok {
            Tok::Op(op) if op == "!" || op == "not" => Ok(Filter::Not(Box::new(self.unary()?))),
            Tok::Op(op) if op == "(" => {
                let inner = self.or_expr()?;
                if self.peek_op(&[")"]).is_none() {
                    return Err(format!("unclosed ( in {text:?}"));
                }
                self.pos += 1;
                Ok(inner)
            }
            Tok::Fn(func, _) if func == "all" => Ok(Filter::All),
            Tok::Fn(func, _) if func == "none" => Ok(Filter::None),
            Tok::Fn(func, arg) => {
                let Some(mut matcher) = default_matcher(&func) else {
                    return Ok(Filter::Unknown);
                };
                let mut arg = arg.as_str();
                if let Some(first) = arg.chars().next()
                    && let Some(m) = match first {
                        '=' => Some(Matcher::Equal),
                        '~' => Some(Matcher::Contains),
                        '#' => Some(Matcher::Glob),
                        _ => None,
                    }
                {
                    matcher = m;
                    arg = arg.strip_prefix(first).unwrap_or(arg);
                } else if let Some(inner) = arg.strip_prefix('/').and_then(|a| a.strip_suffix('/'))
                {
                    matcher = Matcher::Regex;
                    arg = inner;
                }
                let value = arg.replace("\\)", ")").replace("\\,", ",");
                // A regex that does not compile is a configuration error, as nextest says:
                // read as a filter that matches nothing, it would let the scan come back clean.
                let regex =
                    if matcher == Matcher::Regex {
                        Some(regex::Regex::new(&value).map_err(|e| {
                            format!("{func}(/{value}/) is no regex in {text:?}: {e}")
                        })?)
                    } else {
                        None
                    };
                Ok(Filter::Match { func, matcher, value, regex })
            }
            Tok::Op(op) => Err(format!("unexpected {op:?} in {text:?}")),
        }
    }
}

/// `*`, `?` and `[...]` (`[!...]` negated), all of `value`.
fn glob(pattern: &[char], value: &[char]) -> bool {
    let Some((&p, rest)) = pattern.split_first() else {
        return value.is_empty();
    };
    match p {
        '*' => (0..=value.len()).filter_map(|k| value.get(k..)).any(|v| glob(rest, v)),
        '?' => value.split_first().is_some_and(|(_, v)| glob(rest, v)),
        '[' => {
            // The class's first char (`rest[0]`) may itself be `]`.
            let class = rest.iter().skip(1).position(|c| *c == ']').map(|p| p + 1);
            let Some((set, after)) = class.and_then(|close| rest.split_at_checked(close)) else {
                return value.split_first().is_some_and(|(c, v)| *c == '[' && glob(rest, v));
            };
            let after = after.get(1..).unwrap_or_default();
            let Some((&c, value_rest)) = value.split_first() else {
                return false;
            };
            let (negated, mut set) = match set.split_first() {
                Some(('!', set)) => (true, set),
                _ => (false, set),
            };
            let mut hit = false;
            while let Some((&lo, tail)) = set.split_first() {
                if let ['-', hi, next @ ..] = tail {
                    hit |= lo <= c && c <= *hi;
                    set = next;
                } else {
                    hit |= lo == c;
                    set = tail;
                }
            }
            hit != negated && glob(after, value_rest)
        }
        p => value.split_first().is_some_and(|(c, v)| *c == p && glob(rest, v)),
    }
}

/// True, false, or None when the filter asks what a source scan can't know.
pub fn eval_filter(filter: &Filter, t: &TestId) -> Option<bool> {
    match filter {
        Filter::All => Some(true),
        Filter::None => Some(false),
        Filter::Unknown => None,
        Filter::Not(inner) => eval_filter(inner, t).map(|v| !v),
        Filter::And(a, b) | Filter::Diff(a, b) => {
            let a = eval_filter(a, t);
            let mut b = eval_filter(b, t);
            if matches!(filter, Filter::Diff(..)) {
                b = b.map(|v| !v);
            }
            if a == Some(false) || b == Some(false) {
                Some(false)
            } else if a == Some(true) && b == Some(true) {
                Some(true)
            } else {
                None
            }
        }
        Filter::Or(a, b) => {
            let (a, b) = (eval_filter(a, t), eval_filter(b, t));
            if a == Some(true) || b == Some(true) {
                Some(true)
            } else if a == Some(false) && b == Some(false) {
                Some(false)
            } else {
                None
            }
        }
        Filter::Match { func, matcher, value: pattern, regex } => {
            let value = match func.as_str() {
                "test" => Some(&t.name),
                "binary_id" => t.binary_id.as_ref(),
                "binary" => t.binary.as_ref(),
                "package" => t.package.as_ref(),
                "kind" => t.kind.as_ref(),
                _ => None,
            }?;
            Some(match matcher {
                Matcher::Equal => value == pattern,
                Matcher::Contains => value.contains(pattern.as_str()),
                Matcher::Glob => {
                    let (p, v): (Vec<char>, Vec<char>) =
                        (pattern.chars().collect(), value.chars().collect());
                    glob(&p, &v)
                }
                Matcher::Regex => regex.as_ref().is_some_and(|r| r.is_match(value)),
            })
        }
    }
}

#[derive(Debug, Clone)]
struct Override {
    filter: Option<Filter>,
    platform: bool,
    threads_required: Option<toml::Value>,
}

#[derive(Debug, Clone, Default)]
struct Profile {
    overrides: Vec<Override>,
    default_filter: Option<Filter>,
    test_threads: Option<toml::Value>,
}

/// The profiles of one nextest.toml.
#[derive(Debug, Clone, Default)]
pub struct Profiles(HashMap<String, Profile>);

impl Profiles {
    pub fn parse(text: &str) -> Result<Profiles, String> {
        let data: toml::Table = text.parse().map_err(|e: toml::de::Error| e.to_string())?;
        let mut out = HashMap::new();
        let Some(profiles) = data.get("profile").and_then(toml::Value::as_table) else {
            return Ok(Profiles(out));
        };
        for (name, body) in profiles {
            let Some(body) = body.as_table() else {
                continue;
            };
            let mut overrides = Vec::new();
            for o in body.get("overrides").and_then(toml::Value::as_array).into_iter().flatten() {
                let filter = match o.get("filter").and_then(toml::Value::as_str) {
                    Some(f) => Some(parse_filter(f)?),
                    None => None,
                };
                overrides.push(Override {
                    filter,
                    platform: o.get("platform").is_some(),
                    threads_required: o.get("threads-required").cloned(),
                });
            }
            let default_filter = match body.get("default-filter").and_then(toml::Value::as_str) {
                Some(f) => Some(parse_filter(f)?),
                None => None,
            };
            out.insert(
                name.clone(),
                Profile {
                    overrides,
                    default_filter,
                    test_threads: body.get("test-threads").cloned(),
                },
            );
        }
        Ok(Profiles(out))
    }

    /// False when every profile CI uses (`ci` and `default`) runs `t` alone or leaves it out.
    pub fn runs_beside_others(&self, t: &TestId) -> bool {
        let empty = Profile::default();
        let default = self.0.get("default").unwrap_or(&empty);
        let mut names: Vec<&str> =
            ["default", "ci"].into_iter().filter(|p| self.0.contains_key(*p)).collect();
        if names.is_empty() {
            names.push("default");
        }
        for name in names {
            let profile = self.0.get(name).unwrap_or(default);
            let inherited: &[Override] = if name == "default" { &[] } else { &default.overrides };
            let default_filter =
                profile.default_filter.as_ref().or(default.default_filter.as_ref());
            if default_filter.is_some_and(|f| eval_filter(f, t) == Some(false)) {
                continue;
            }
            let threads = profile.test_threads.as_ref().or(default.test_threads.as_ref());
            if threads.and_then(toml::Value::as_integer) == Some(1) {
                continue;
            }
            let mut alone = false;
            for o in profile.overrides.iter().chain(inherited) {
                let Some(required) = &o.threads_required else {
                    continue;
                };
                let hit = o.filter.as_ref().map_or(Some(true), |f| eval_filter(f, t));
                match hit {
                    None => break, // can't tell: count it as run beside others
                    Some(true) => {
                        alone = !o.platform && required.as_str() == Some("num-test-threads");
                        break;
                    }
                    Some(false) => {}
                }
            }
            if !alone {
                return true;
            }
        }
        false
    }
}

/// How a file's tests are named, or that nextest doesn't run it (`benches/`, `examples/`).
#[derive(Debug, Clone)]
pub enum FileTests {
    NotRun,
    /// Not in a crate: the name is the module path in the file.
    Loose,
    Crate {
        file_mods: Vec<String>,
        binary_id: String,
        binary: String,
        package: String,
        kind: String,
    },
}

impl FileTests {
    pub fn id(&self, mods: &[String], name: &str) -> TestId {
        let join = |file_mods: &[String]| {
            file_mods
                .iter()
                .chain(mods)
                .map(String::as_str)
                .chain([name])
                .collect::<Vec<_>>()
                .join("::")
        };
        match self {
            FileTests::NotRun | FileTests::Loose => TestId { name: join(&[]), ..TestId::default() },
            FileTests::Crate { file_mods, binary_id, binary, package, kind } => TestId {
                name: join(file_mods),
                binary_id: Some(binary_id.clone()),
                binary: Some(binary.clone()),
                package: Some(package.clone()),
                kind: Some(kind.clone()),
            },
        }
    }
}

/// What a scan learns about a checkout's layout, once per directory.
#[derive(Default)]
pub struct Layout {
    crates: HashMap<PathBuf, Option<(String, String)>>,
    configs: HashMap<PathBuf, Option<Rc<Profiles>>>,
}

impl Layout {
    /// The package and lib name of the crate whose Cargo.toml is in `dir`, if it has a [package].
    /// No Cargo.toml there is None; one it cannot read is Err, naming it.
    fn package_in(&mut self, dir: &Path) -> Result<Option<(String, String)>, ReadError> {
        if let Some(known) = self.crates.get(dir) {
            return Ok(known.clone());
        }
        let manifest = dir.join("Cargo.toml");
        let text = match std::fs::read_to_string(&manifest) {
            Ok(text) => Some(text),
            Err(e) if absent(&e) => None,
            Err(e) => return Err(ReadError::new(&manifest, e)),
        };
        let found = text.and_then(|text| text.parse::<toml::Table>().ok()).and_then(|data| {
            let package = data.get("package")?.get("name")?.as_str()?.to_string();
            let lib = data
                .get("lib")
                .and_then(|l| l.get("name"))
                .and_then(toml::Value::as_str)
                .map_or_else(|| package.replace('-', "_"), str::to_string);
            Some((package, lib))
        });
        self.crates.insert(dir.to_path_buf(), found.clone());
        Ok(found)
    }

    /// How nextest names the tests of `path`, from the nearest Cargo.toml with a [package] at or
    /// below `checkout`. Err names a Cargo.toml on the way it could not read.
    pub fn file_tests(&mut self, path: &Path, checkout: &Path) -> Result<FileTests, ReadError> {
        let mut crate_dir = None;
        for dir in path.ancestors().skip(1) {
            if let Some(found) = self.package_in(dir)? {
                crate_dir = Some((dir.to_path_buf(), found));
                break;
            }
            if dir == checkout {
                break;
            }
        }
        let Some((root, (package, lib))) = crate_dir else {
            return Ok(FileTests::Loose);
        };
        let parts: Vec<String> = path
            .strip_prefix(&root)
            .unwrap_or(path)
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        let stem: Vec<String> =
            parts.iter().map(|p| p.strip_suffix(".rs").unwrap_or(p).to_string()).collect();
        let without = |from: &[String], drop: [&str; 2]| -> Vec<String> {
            from.iter().filter(|m| !drop.contains(&m.as_str())).cloned().collect()
        };
        let first = parts.first().map(String::as_str);
        if matches!(first, Some("benches" | "examples")) {
            return Ok(FileTests::NotRun);
        }
        let (binary, file_mods, binary_id, kind) = if first == Some("tests")
            && let [_, binary, mods @ ..] = stem.as_slice()
        {
            let binary = binary.clone();
            (binary.clone(), without(mods, ["main", "mod"]), format!("{package}::{binary}"), "test")
        } else if let [src, bin, _, ..] = parts.as_slice()
            && src == "src"
            && bin == "bin"
            && let [_, _, binary, mods @ ..] = stem.as_slice()
        {
            let binary = binary.clone();
            (
                binary.clone(),
                without(mods, ["main", "mod"]),
                format!("{package}::bin/{binary}"),
                "bin",
            )
        } else if parts == ["src", "main.rs"] {
            (package.clone(), Vec::new(), format!("{package}::bin/{package}"), "bin")
        } else {
            let mods = if first == Some("src") {
                without(stem.get(1..).unwrap_or_default(), ["lib", "mod"])
            } else {
                stem
            };
            (lib, mods, package.clone(), "lib")
        };
        Ok(FileTests::Crate { file_mods, binary_id, binary, package, kind: kind.to_string() })
    }

    /// The nextest profiles of the nearest `.config/nextest.toml` above `path`, up to `checkout`.
    /// Err names a config it could not stat, read or parse.
    pub fn profiles(
        &mut self,
        path: &Path,
        checkout: &Path,
    ) -> Result<Option<Rc<Profiles>>, String> {
        for dir in path.ancestors().skip(1) {
            if let Some(known) = self.configs.get(dir) {
                if known.is_some() {
                    return Ok(known.clone());
                }
            } else {
                let cfg = dir.join(".config/nextest.toml");
                let is_file = match std::fs::metadata(&cfg) {
                    Ok(meta) => meta.is_file(),
                    Err(e) if absent(&e) => false,
                    Err(e) => return Err(ReadError::new(&cfg, e).to_string()),
                };
                let found = if is_file {
                    let text = std::fs::read_to_string(&cfg)
                        .map_err(|e| ReadError::new(&cfg, e).to_string())?;
                    Some(Rc::new(
                        Profiles::parse(&text).map_err(|e| format!("{}: {e}", cfg.display()))?,
                    ))
                } else {
                    None
                };
                self.configs.insert(dir.to_path_buf(), found.clone());
                if found.is_some() {
                    return Ok(found);
                }
            }
            if dir == checkout {
                break;
            }
        }
        Ok(None)
    }
}

/// Whether a read failed only because the path is not there (no such file, or a part of it is
/// a file): a manifest or config that does not exist, not one the scan could not read.
fn absent(error: &std::io::Error) -> bool {
    matches!(error.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory)
}
