//! Input keys for Mac-rendered goldens (mac-golden-cache, B9 in cmuxterm-hq
//! `docs/findings/2026-11-25-linux-everything-map.md`).
//!
//! A family names the files that can change a set of screenshots (view code, theme, the renderer pins). Its
//! key is the SHA-256 of the family's entry and of `mode blob path` for every file at a git revision its paths
//! match. A Mac renders a family once per key; every run after that, on any runner, finds the goldens by the
//! key and compares against them, so a push that touches none of the family's files spends no Mac minutes.
//!
//! The families live in a JSON file (`.github/golden-inputs.json`):
//!
//! ```json
//! {"version": 1, "families": {"ios-gate": {"doc": "...", "variants": ["iphone", "ipad"],
//!   "paths": ["cmux-next-ios/**", "!**/*.md"], "spec": {...}?}}}
//! ```
//!
//! Paths are globs from the repository root: `**` is any number of folders, `*` and `?` stay within one name,
//! the last matching path wins and `!` excludes. A family's goldens for one key live in their own store
//! ([`key_store_path`]): `ROOT/<family>/<variant>/<key>/`, a plain [`crate::Store`]. The first render of a key
//! wins; a later render of the same key never replaces it.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

/// Bumped when the key's preimage changes, so old and new keys never collide.
pub const KEY_VERSION: &str = "golden-key/v2";

/// One family from the inputs file.
#[derive(Debug, Clone)]
pub struct Family {
    pub name: String,
    pub variants: Vec<String>,
    rules: Vec<(bool, Vec<String>)>,
    canonical: String,
}

/// A computed key and how many files fed it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputKey {
    pub family: String,
    pub variant: String,
    pub key: String,
    pub files: usize,
}

/// A name a store path can carry: lowercase letters, digits, `.`, `_`, `-`, at most 64, not starting with a
/// separator.
pub fn valid_key_name(name: &str) -> bool {
    let b = name.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && b.first().is_some_and(u8::is_ascii_alphanumeric)
        && b.iter().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'_' | b'-')
        })
}

impl Family {
    /// Parses one family's entry.
    pub fn from_value(name: &str, entry: &Value) -> Result<Self, String> {
        if !valid_key_name(name) {
            return Err(format!("bad family name {name:?}"));
        }
        let obj = entry.as_object().ok_or_else(|| format!("family {name}: not an object"))?;
        for k in obj.keys() {
            if !matches!(k.as_str(), "doc" | "paths" | "variants" | "spec") {
                return Err(format!("family {name}: unknown key {k:?}"));
            }
        }
        let paths: Vec<String> = match obj.get("paths") {
            Some(Value::Array(a)) => a
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .ok_or_else(|| format!("family {name}: paths must be strings"))
                })
                .collect::<Result<_, _>>()?,
            _ => Vec::new(),
        };
        if paths.first().is_none_or(|p| p.starts_with('!')) {
            return Err(format!("family {name}: paths must start with an include"));
        }
        let variants: Vec<String> = match obj.get("variants") {
            None => Vec::new(),
            Some(Value::Array(a)) => a
                .iter()
                .map(|v| match v.as_str() {
                    Some(s) if valid_key_name(s) => Ok(s.to_string()),
                    _ => Err(format!("family {name}: bad variant {v}")),
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err(format!("family {name}: variants must be a list")),
        };
        let rules = paths
            .iter()
            .map(|p| {
                let (neg, pat) = match p.strip_prefix('!') {
                    Some(rest) => (true, rest),
                    None => (false, p.as_str()),
                };
                if pat.is_empty() || pat.starts_with('/') {
                    return Err(format!("family {name}: bad path {p:?}"));
                }
                Ok((neg, pat.split('/').map(str::to_string).collect()))
            })
            .collect::<Result<_, String>>()?;
        Ok(Family { name: name.to_string(), variants, rules, canonical: canonical_json(entry) })
    }

    /// Whether the family reads this repository path (the last matching rule wins).
    pub fn wants(&self, path: &str) -> bool {
        let segs: Vec<&str> = path.split('/').collect();
        let mut keep = false;
        for (neg, pat) in &self.rules {
            if glob_segments(pat, &segs) {
                keep = !neg;
            }
        }
        keep
    }

    /// The variant to key by: `default` when the family has none and none was asked for.
    pub fn variant<'a>(&self, asked: Option<&'a str>) -> Result<&'a str, String> {
        match asked {
            None | Some("") if self.variants.is_empty() => Ok("default"),
            None | Some("") => {
                Err(format!("family {}: pass --variant (one of {:?})", self.name, self.variants))
            }
            Some(v) if !valid_key_name(v) => Err(format!("bad variant {v:?}")),
            Some(v) if !self.variants.is_empty() && !self.variants.iter().any(|x| x == v) => {
                Err(format!("family {}: variant {v:?} not in {:?}", self.name, self.variants))
            }
            Some(v) => Ok(v),
        }
    }

    /// The key over `(mode, blob, path)` rows, in the order git lists them.
    pub fn key_over<'r>(
        &self,
        variant: &str,
        rows: impl IntoIterator<Item = (&'r str, &'r str, &'r str)>,
    ) -> Result<InputKey, String> {
        let mut h = Sha256::new();
        h.update(format!("{KEY_VERSION}\n{}\n{variant}\n{}\n", self.name, self.canonical));
        let mut files = 0;
        for (mode, blob, path) in rows {
            if self.wants(path) {
                h.update(format!("{mode} {blob} {path}\n"));
                files += 1;
            }
        }
        if files == 0 {
            return Err(format!("family {}: no file matches its paths", self.name));
        }
        Ok(InputKey {
            family: self.name.clone(),
            variant: variant.to_string(),
            key: format!("{:x}", h.finalize()),
            files,
        })
    }
}

/// Reads `family` from an inputs file.
pub fn load_family(inputs: &Path, family: &str) -> Result<Family, String> {
    let bytes = std::fs::read(inputs).map_err(|e| format!("{}: {e}", inputs.display()))?;
    let doc: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", inputs.display()))?;
    let families = doc
        .get("families")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("{}: no \"families\" object", inputs.display()))?;
    let entry = families.get(family).ok_or_else(|| {
        let have: Vec<&String> = families.keys().collect();
        format!("{}: no family {family:?} (have {have:?})", inputs.display())
    })?;
    Family::from_value(family, entry)
}

/// `(mode, blob, path)` for every file at `rev`, from the repository root (`git ls-tree -r -z --full-tree`).
pub fn tree_rows(repo: &Path, rev: &str) -> Result<Vec<(String, String, String)>, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["ls-tree", "-r", "-z", "--full-tree", rev])
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(format!("git ls-tree {rev}: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    let text = String::from_utf8(out.stdout)
        .map_err(|_| "git ls-tree: a path is not UTF-8".to_string())?;
    text.split('\0')
        .filter(|s| !s.is_empty())
        .map(|item| {
            let (meta, path) =
                item.split_once('\t').ok_or_else(|| format!("git ls-tree: bad row {item:?}"))?;
            let mut parts = meta.split(' ');
            match (parts.next(), parts.next(), parts.next()) {
                (Some(mode), Some(_kind), Some(blob)) => {
                    Ok((mode.to_string(), blob.to_string(), path.to_string()))
                }
                _ => Err(format!("git ls-tree: bad row {item:?}")),
            }
        })
        .collect()
}

/// The family's key at `rev` in `repo`.
pub fn input_key(
    family: &Family,
    variant: &str,
    repo: &Path,
    rev: &str,
) -> Result<InputKey, String> {
    let rows = tree_rows(repo, rev)?;
    family
        .key_over(variant, rows.iter().map(|(m, b, p)| (m.as_str(), b.as_str(), p.as_str())))
        .map_err(|e| format!("{e} at {rev}"))
}

/// Where one key's goldens live under a store root: `ROOT/<family>/<variant>/<key>`.
pub fn key_store_path(root: &str, key: &InputKey) -> String {
    format!("{}/{}/{}/{}", root.trim_end_matches('/'), key.family, key.variant, key.key)
}

/// Glob over path segments: a `**` segment matches any number of segments (at the end, at least one, so
/// `dir/**` names what is below `dir`, not `dir` itself); `*` and `?` match within a segment.
fn glob_segments(pat: &[String], path: &[&str]) -> bool {
    match pat.split_first() {
        None => path.is_empty(),
        Some((first, rest)) if first == "**" => {
            if rest.is_empty() {
                return !path.is_empty();
            }
            (0..=path.len()).any(|i| path.get(i..).is_some_and(|tail| glob_segments(rest, tail)))
        }
        Some((first, rest)) => match path.split_first() {
            Some((seg, prest)) => {
                glob_name(first.as_bytes(), seg.as_bytes()) && glob_segments(rest, prest)
            }
            None => false,
        },
    }
}

fn glob_name(pat: &[u8], name: &[u8]) -> bool {
    match pat.split_first() {
        None => name.is_empty(),
        Some((b'*', rest)) => {
            (0..=name.len()).any(|i| name.get(i..).is_some_and(|tail| glob_name(rest, tail)))
        }
        Some((b'?', rest)) => name.split_first().is_some_and(|(_, tail)| glob_name(rest, tail)),
        Some((c, rest)) => match name.split_first() {
            Some((n, tail)) => n == c && glob_name(rest, tail),
            None => false,
        },
    }
}

/// JSON with object keys sorted at every depth and no whitespace, so the key does not depend on how the
/// inputs file is formatted or on serde_json's map order.
pub fn canonical_json(v: &Value) -> String {
    match v {
        Value::Object(m) => {
            let sorted: BTreeMap<&String, &Value> = m.iter().collect();
            let body: Vec<String> = sorted
                .into_iter()
                .map(|(k, v)| format!("{}:{}", Value::String(k.clone()), canonical_json(v)))
                .collect();
            format!("{{{}}}", body.join(","))
        }
        Value::Array(a) => {
            format!("[{}]", a.iter().map(canonical_json).collect::<Vec<_>>().join(","))
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fam(paths: &[&str]) -> Family {
        Family::from_value("f", &json!({"paths": paths})).unwrap()
    }

    #[test]
    fn globs() {
        let f = fam(&["app/**", "!**/*.md", "Cargo.toml", "pkg/*/Sources/**", "!pkg/**/Tests/**"]);
        assert!(f.wants("app/a.swift"));
        assert!(f.wants("app/deep/b.swift"));
        assert!(!f.wants("app"));
        assert!(!f.wants("app/README.md"));
        assert!(!f.wants("README.md"));
        assert!(f.wants("Cargo.toml"));
        assert!(!f.wants("x/Cargo.toml"));
        assert!(f.wants("pkg/Kit/Sources/a.swift"));
        assert!(!f.wants("pkg/Kit/Sources/Tests/a.swift"));
        assert!(!f.wants("pkg/Kit/Other/a.swift"));
        assert!(glob_name(b"a?c*", b"abcdef"));
        assert!(!glob_name(b"a?c", b"ac"));
    }

    #[test]
    fn rejects_bad_families() {
        assert!(Family::from_value("f", &json!({"paths": ["!x"]})).is_err());
        assert!(Family::from_value("f", &json!({"paths": []})).is_err());
        assert!(Family::from_value("F", &json!({"paths": ["x"]})).is_err());
        assert!(Family::from_value("f", &json!({"paths": ["x"], "extra": 1})).is_err());
        assert!(Family::from_value("f", &json!({"paths": ["/x"]})).is_err());
    }

    #[test]
    fn variants() {
        let f = Family::from_value("f", &json!({"paths": ["x"], "variants": ["iphone", "ipad"]}))
            .unwrap();
        assert_eq!(f.variant(Some("ipad")).unwrap(), "ipad");
        assert!(f.variant(Some("duo")).is_err());
        assert!(f.variant(None).is_err());
        assert_eq!(fam(&["x"]).variant(None).unwrap(), "default");
    }

    #[test]
    fn key_moves_only_with_inputs() {
        let f = fam(&["app/**", "!**/*.md"]);
        let rows = |blob: &'static str, doc: &'static str| {
            vec![
                ("100644", blob, "app/a.swift"),
                ("100644", doc, "app/README.md"),
                ("100644", "z", "other.rs"),
            ]
        };
        let a = f.key_over("default", rows("b1", "d1")).unwrap();
        assert_eq!(a.files, 1);
        assert_eq!(
            a,
            f.key_over("default", rows("b1", "d2")).unwrap(),
            "an excluded file moved the key"
        );
        assert_ne!(a.key, f.key_over("default", rows("b2", "d1")).unwrap().key);
        assert_ne!(
            a.key,
            f.key_over("other", rows("b1", "d1")).unwrap().key,
            "variant is in the key"
        );
        let g = fam(&["app/**"]);
        assert_ne!(
            a.key,
            g.key_over("default", rows("b1", "d1")).unwrap().key,
            "the family entry is in the key"
        );
        assert!(f.key_over("default", vec![("100644", "z", "other.rs")]).is_err());
    }

    #[test]
    fn canonical_is_format_independent() {
        let a: Value =
            serde_json::from_str(r#"{"b": [1, {"y": 2, "x": "é"}], "a": true}"#).unwrap();
        let b: Value = serde_json::from_str(r#"{"a":true,"b":[1,{"x":"é","y":2}]}"#).unwrap();
        assert_eq!(canonical_json(&a), canonical_json(&b));
        assert_eq!(canonical_json(&a), r#"{"a":true,"b":[1,{"x":"é","y":2}]}"#);
    }

    #[test]
    fn store_path() {
        let k = InputKey {
            family: "ios-gate".into(),
            variant: "ipad".into(),
            key: "ab".into(),
            files: 1,
        };
        assert_eq!(key_store_path("s3://b/goldens/", &k), "s3://b/goldens/ios-gate/ipad/ab");
    }
}
