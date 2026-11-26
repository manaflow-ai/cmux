//! The golden store: content-addressed PNG objects plus a manifest naming them.
//!
//! ```text
//! <root>/goldens.json            {"schema": "cmux-shotdiff.goldens/v1", "goldens": {"<name>": {hash, width, height, spec?}}}
//! <root>/objects/<h[0..2]>/<hash>.png
//! ```
//!
//! The hash is the decoded pixels' (`Rgba::content_hash`), and objects are stored re-encoded with fixed
//! settings, so one hash is always one file's bytes: a Mac that rendered a surface once uploads it by hash and
//! every Linux run after compares against it (mac-golden-cache). Names are slash paths such as
//! `ios/home/light`; the manifest is sorted, so blessing one golden changes one line.

use crate::compare::{self, Comparison, Spec};
use crate::image::{self, Rgba};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

pub const MANIFEST_SCHEMA: &str = "cmux-shotdiff.goldens/v1";
pub const REPORT_SCHEMA: &str = "cmux-shotdiff.report/v1";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Golden {
    pub hash: String,
    pub width: u32,
    pub height: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spec: Option<Spec>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: String,
    /// The spec a golden without its own uses (else the built-in defaults).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_spec: Option<Spec>,
    pub goldens: BTreeMap<String, Golden>,
}

impl Default for Manifest {
    fn default() -> Self {
        Manifest { schema: MANIFEST_SCHEMA.into(), default_spec: None, goldens: BTreeMap::new() }
    }
}

pub struct Store {
    pub root: PathBuf,
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.split('/').all(|seg| {
            !seg.is_empty()
                && seg != "."
                && seg != ".."
                && seg
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '@' | '+'))
        })
}

impl Store {
    pub fn open(root: impl Into<PathBuf>) -> Self {
        Store { root: root.into() }
    }

    fn manifest_path(&self) -> PathBuf {
        self.root.join("goldens.json")
    }

    pub fn object_path(&self, hash: &str) -> PathBuf {
        self.root.join("objects").join(&hash[..2.min(hash.len())]).join(format!("{hash}.png"))
    }

    pub fn manifest(&self) -> Result<Manifest, String> {
        let path = self.manifest_path();
        match fs::read(&path) {
            Ok(bytes) => {
                let m: Manifest = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                if m.schema != MANIFEST_SCHEMA {
                    return Err(format!(
                        "{}: schema {} (want {MANIFEST_SCHEMA})",
                        path.display(),
                        m.schema
                    ));
                }
                Ok(m)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Manifest::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    pub fn save_manifest(&self, m: &Manifest) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|e| format!("{}: {e}", self.root.display()))?;
        let mut text = serde_json::to_string_pretty(m).map_err(|e| e.to_string())?;
        text.push('\n');
        write_atomic(&self.manifest_path(), text.as_bytes())
    }

    /// Stores the pixels under their hash (idempotent) and returns the hash.
    pub fn put(&self, img: &Rgba) -> Result<String, String> {
        let hash = img.content_hash();
        let path = self.object_path(&hash);
        if !path.exists() {
            let bytes = image::encode_png(img).map_err(|e| e.to_string())?;
            if let Some(dir) = path.parent() {
                fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            }
            write_atomic(&path, &bytes)?;
        }
        Ok(hash)
    }

    pub fn get(&self, hash: &str) -> Result<Rgba, String> {
        let path = self.object_path(hash);
        let bytes = fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let img = image::decode_png(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
        let got = img.content_hash();
        if got != hash {
            return Err(format!("{}: holds {got}, not {hash}", path.display()));
        }
        Ok(img)
    }

    /// Makes `img` the golden for `name`. A `spec` of None keeps the golden's current spec.
    pub fn bless(&self, name: &str, img: &Rgba, spec: Option<Spec>) -> Result<Golden, String> {
        if !valid_name(name) {
            return Err(format!(
                "golden name {name:?}: use slash-separated [A-Za-z0-9._@+-] segments"
            ));
        }
        let hash = self.put(img)?;
        let mut m = self.manifest()?;
        let spec = spec.or_else(|| m.goldens.get(name).and_then(|g| g.spec.clone()));
        let golden = Golden { hash, width: img.width, height: img.height, spec };
        m.goldens.insert(name.to_string(), golden.clone());
        self.save_manifest(&m)?;
        Ok(golden)
    }

    pub fn spec_for(&self, m: &Manifest, name: &str) -> Spec {
        m.goldens
            .get(name)
            .and_then(|g| g.spec.clone())
            .or_else(|| m.default_spec.clone())
            .unwrap_or_default()
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, bytes).map_err(|e| format!("{}: {e}", tmp.display()))?;
    fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

/// Every `*.png` under `dir`, as (golden name, path), sorted by name: `dir/ios/home/light.png` is
/// `ios/home/light`.
pub fn collect_pngs(dir: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) -> Result<(), String> {
        let mut entries: Vec<_> = fs::read_dir(dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .collect();
        entries.sort();
        for path in entries {
            if path.is_dir() {
                walk(root, &path, out)?;
            } else if path.extension().is_some_and(|e| e == "png") {
                let rel = path.strip_prefix(root).unwrap_or(&path).with_extension("");
                let name = rel
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy())
                    .collect::<Vec<_>>()
                    .join("/");
                out.push((name, path));
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out)?;
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    /// Same pixels as the golden.
    Identical,
    /// Within the spec's thresholds.
    Pass,
    Fail,
    /// A head with no golden.
    New,
    /// A golden with no head.
    Missing,
    /// The head or golden could not be read.
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub name: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verdict: Option<compare::Verdict>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diff_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub schema: String,
    pub pass: bool,
    pub counts: BTreeMap<String, usize>,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct BatchOptions {
    /// A head with no golden passes (else it fails: bless it first).
    pub allow_new: bool,
    /// A golden with no head fails (else it is only reported).
    pub require_all: bool,
}

/// Checks every PNG under `heads` against the store; writes diff images under `out/diff/<name>.png` for the
/// ones that are not identical.
pub fn batch(
    store: &Store,
    heads: &Path,
    out: Option<&Path>,
    opts: BatchOptions,
) -> Result<Report, String> {
    let manifest = store.manifest()?;
    let found = collect_pngs(heads)?;
    let mut entries = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for (name, path) in &found {
        seen.insert(name.clone());
        let Some(golden) = manifest.goldens.get(name) else {
            entries.push(Entry {
                name: name.clone(),
                status: Status::New,
                verdict: None,
                diff_image: None,
                error: None,
            });
            continue;
        };
        let head = match fs::read(path)
            .map_err(|e| e.to_string())
            .and_then(|b| image::decode_png(&b).map_err(|e| e.to_string()))
        {
            Ok(img) => img,
            Err(e) => {
                entries.push(error_entry(name, format!("{}: {e}", path.display())));
                continue;
            }
        };
        let base = match store.get(&golden.hash) {
            Ok(img) => img,
            Err(e) => {
                entries.push(error_entry(name, e));
                continue;
            }
        };
        let spec = store.spec_for(&manifest, name);
        let Comparison { verdict, diff_image } = compare::compare(&base, &head, &spec);
        let status = if verdict.identical {
            Status::Identical
        } else if verdict.pass {
            Status::Pass
        } else {
            Status::Fail
        };
        let mut diff_path = None;
        if let (Some(out), Some(diff), false) = (out, diff_image, verdict.identical) {
            let p = out.join("diff").join(format!("{name}.png"));
            if let Some(dir) = p.parent() {
                fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            }
            fs::write(&p, image::encode_png(&diff).map_err(|e| e.to_string())?)
                .map_err(|e| format!("{}: {e}", p.display()))?;
            diff_path = Some(format!("diff/{name}.png"));
        }
        entries.push(Entry {
            name: name.clone(),
            status,
            verdict: Some(verdict),
            diff_image: diff_path,
            error: None,
        });
    }
    for name in manifest.goldens.keys() {
        if !seen.contains(name) {
            entries.push(Entry {
                name: name.clone(),
                status: Status::Missing,
                verdict: None,
                diff_image: None,
                error: None,
            });
        }
    }
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    let mut counts = BTreeMap::new();
    let mut pass = true;
    for e in &entries {
        let key = serde_json::to_value(e.status)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        *counts.entry(key).or_insert(0) += 1;
        pass &= match e.status {
            Status::Identical | Status::Pass => true,
            Status::New => opts.allow_new,
            Status::Missing => !opts.require_all,
            Status::Fail | Status::Error => false,
        };
    }
    let report = Report { schema: REPORT_SCHEMA.into(), pass, counts, entries };
    if let Some(out) = out {
        fs::create_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
        let mut text = serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?;
        text.push('\n');
        fs::write(out.join("report.json"), text).map_err(|e| e.to_string())?;
    }
    Ok(report)
}

fn error_entry(name: &str, error: String) -> Entry {
    Entry {
        name: name.to_string(),
        status: Status::Error,
        verdict: None,
        diff_image: None,
        error: Some(error),
    }
}

/// A markdown summary for $GITHUB_STEP_SUMMARY: counts, then every entry that is not identical.
pub fn markdown(report: &Report, title: &str) -> String {
    let mut s = format!("### {title}\n\n");
    s.push_str(if report.pass { "**pass**" } else { "**fail**" });
    for (k, v) in &report.counts {
        s.push_str(&format!(" · {k} {v}"));
    }
    s.push_str("\n\n");
    let rows: Vec<&Entry> =
        report.entries.iter().filter(|e| e.status != Status::Identical).collect();
    if !rows.is_empty() {
        s.push_str("| screenshot | status | changed | ssim | why |\n|---|---|---|---|---|\n");
        for e in rows {
            let (changed, ssim, why) = match &e.verdict {
                Some(v) => (
                    format!("{:.3}%", v.changed_ratio * 100.0),
                    format!("{:.4}", v.ssim),
                    v.reasons.join("; "),
                ),
                None => ("".into(), "".into(), e.error.clone().unwrap_or_default()),
            };
            let status = serde_json::to_value(e.status)
                .ok()
                .and_then(|v| v.as_str().map(str::to_string))
                .unwrap_or_default();
            s.push_str(&format!(
                "| `{}` | {status} | {changed} | {ssim} | {} |\n",
                e.name,
                why.replace('|', "\\|")
            ));
        }
    }
    s
}
