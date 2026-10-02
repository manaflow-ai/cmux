//! The apps this machine can run: validated packages from the bundle
//! directories and the local development directory, plus the deployment list
//! of default first-party apps. Every package passes the one manifest v2
//! validator (`cmux-app-manifest`) before the supervisor knows it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::mirror::{Facts, Source, Tier};

/// Default first-party apps of this deployment: installed for everyone with
/// their required scopes and no consent sheet (plan section 13). Empty until
/// the first first-party app ships; `CMUX_APPS_DEFAULT` (comma separated)
/// overrides it per deployment.
pub const DEFAULT_APPS: &[&str] = &[];

/// Publishers whose apps are first-party.
const FIRST_PARTY: &[&str] = &["cmux", "manaflow-ai"];

#[derive(Debug, Clone)]
pub struct Package {
    pub id: String,
    pub version: String,
    pub tier: Tier,
    pub source: Source,
    pub dir: PathBuf,
    pub manifest: Value,
}

impl Package {
    pub fn facts(&self) -> Facts {
        let keys = |key: &str| -> BTreeSet<String> {
            self.manifest
                .get(key)
                .and_then(Value::as_object)
                .map(|o| o.keys().cloned().collect())
                .unwrap_or_default()
        };
        Facts {
            tier: self.tier,
            source: self.source,
            requested: keys("scopes"),
            optional: keys("optionalScopes"),
        }
    }

    /// The export implementing `interface` (`cmux.section/1`, …), if the
    /// app implements it with a scene export.
    pub fn export_for(&self, interface: &str) -> Option<String> {
        self.manifest
            .pointer(&format!(
                "/implements/{}/export",
                interface.replace('~', "~0").replace('/', "~1")
            ))?
            .as_str()
            .map(str::to_string)
    }

    /// The export behind a catalog op of the app (`catalog` file,
    /// `operations.<op>.export`).
    pub fn export_for_op(&self, op: &str) -> Option<String> {
        let file = self.manifest.get("catalog")?.as_str()?;
        let catalog: Value = serde_json::from_slice(&self.read(file)?).ok()?;
        catalog.get("operations")?.get(op)?.get("export")?.as_str().map(str::to_string)
    }

    /// The app's main script, read when its host starts.
    pub fn main_source(&self) -> Option<String> {
        let main = self.manifest.pointer("/runtime/main")?.as_str()?;
        String::from_utf8(self.read(main)?).ok()
    }

    /// A file of the package, refused when it (or a symlink on the way)
    /// leaves the package directory.
    fn read(&self, relative: &str) -> Option<Vec<u8>> {
        let root = self.dir.canonicalize().ok()?;
        let path = self.dir.join(relative).canonicalize().ok()?;
        if !path.starts_with(&root) {
            return None;
        }
        std::fs::read(path).ok()
    }

    /// `strings/<locale>.json` falling back to English.
    pub fn strings(&self, locale: &str) -> Value {
        let Some(dir) = self.manifest.get("strings").and_then(Value::as_str) else {
            return Value::Null;
        };
        for candidate in [locale, "en"] {
            if let Some(raw) = self.read(&format!("{dir}/{candidate}.json"))
                && let Ok(value) = serde_json::from_slice::<Value>(&raw)
            {
                return value;
            }
        }
        Value::Null
    }

    /// Default values from the manifest's settings schema.
    pub fn default_settings(&self) -> Value {
        let mut out = serde_json::Map::new();
        if let Some(properties) =
            self.manifest.pointer("/settings/properties").and_then(Value::as_object)
        {
            for (key, schema) in properties {
                if let Some(default) = schema.get("default") {
                    out.insert(key.clone(), default.clone());
                }
            }
        }
        Value::Object(out)
    }
}

#[derive(Debug, Clone, Default)]
pub struct Catalog {
    pub packages: BTreeMap<String, Package>,
    pub defaults: Vec<String>,
    /// Packages that failed validation: (directory, first issue).
    pub rejected: Vec<(PathBuf, String)>,
}

/// Where packages come from.
#[derive(Debug, Clone, Default)]
pub struct Sources {
    /// Directories of app package directories shipped with cmux.
    pub bundled: Vec<PathBuf>,
    /// The local development directory (`<state>/apps/local`).
    pub local: Option<PathBuf>,
    pub defaults: Vec<String>,
}

impl Sources {
    /// Bundled dirs from `CMUX_APPS_DIRS` (path list) or `<exe dir>/apps`,
    /// the local dir under the daemon state dir, defaults from
    /// `CMUX_APPS_DEFAULT` or [`DEFAULT_APPS`].
    pub fn from_env(state_dir: Option<&Path>) -> Self {
        let bundled = match std::env::var_os("CMUX_APPS_DIRS") {
            Some(list) => std::env::split_paths(&list).collect(),
            None => std::env::current_exe()
                .ok()
                .and_then(|exe| exe.parent().map(|d| vec![d.join("apps")]))
                .unwrap_or_default(),
        };
        let defaults = match std::env::var("CMUX_APPS_DEFAULT") {
            Ok(list) => list
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
            Err(_) => DEFAULT_APPS.iter().map(|s| s.to_string()).collect(),
        };
        Self { bundled, local: state_dir.map(|d| d.join("apps").join("local")), defaults }
    }
}

pub fn load(sources: &Sources) -> Catalog {
    let mut catalog = Catalog { defaults: sources.defaults.clone(), ..Catalog::default() };
    let mut dirs: Vec<(PathBuf, bool)> =
        sources.bundled.iter().map(|d| (d.clone(), false)).collect();
    if let Some(local) = &sources.local {
        dirs.push((local.clone(), true));
    }
    for (root, local) in dirs {
        let Ok(entries) = std::fs::read_dir(&root) else { continue };
        let mut paths: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.join("cmux-app.json").is_file())
            .collect();
        paths.sort();
        for dir in paths {
            match package(&dir, local, &catalog.defaults) {
                Ok(package) => {
                    // First source wins; a local package never shadows a bundled id.
                    catalog.packages.entry(package.id.clone()).or_insert(package);
                }
                Err(issue) => catalog.rejected.push((dir, issue)),
            }
        }
    }
    catalog
}

fn package(dir: &Path, local: bool, defaults: &[String]) -> Result<Package, String> {
    let report = cmux_app_manifest::validate_package(dir);
    if !report.is_valid() {
        let first = report.issues.iter().find(|i| i.severity == cmux_app_manifest::Severity::Error);
        return Err(first
            .map(|i| format!("{} {}: {}", i.path, i.code, i.message))
            .unwrap_or_default());
    }
    let manifest = report.manifest.ok_or("no manifest")?;
    let id = manifest["id"].as_str().unwrap_or_default().to_string();
    let publisher = id.split('/').next().unwrap_or_default();
    if local && publisher != "local" {
        return Err(format!("{id}: the local directory only holds local/ apps"));
    }
    let tier = if FIRST_PARTY.contains(&publisher) && !local {
        Tier::FirstParty
    } else {
        Tier::Unverified
    };
    let source = if local || publisher == "local" {
        Source::Local
    } else if defaults.contains(&id) {
        Source::Default
    } else {
        Source::Bundled
    };
    Ok(Package {
        version: manifest["version"].as_str().unwrap_or_default().to_string(),
        id,
        tier,
        source,
        dir: dir.to_path_buf(),
        manifest,
    })
}
