//! The apps this machine can run: validated packages from the bundle
//! directories and the local development directory, plus the deployment list
//! of default first-party apps. Every package passes the one manifest v2
//! validator (`cmux-app-manifest`) before the supervisor knows it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::mirror::{Facts, Source, Tier};

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

    /// The app's catalog ops as `(name, entry)`: the `operations` list of
    /// its catalog fragment (`catalog: "<file>"`, cmux-app-catalog.schema.json,
    /// which validate_package checks at install).
    pub fn catalog_ops(&self) -> Vec<(String, Value)> {
        let Some(catalog) = self.catalog_fragment() else { return Vec::new() };
        catalog
            .get("operations")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|e| Some((e.get("name")?.as_str()?.to_string(), e.clone())))
            .collect()
    }

    /// The app's catalog fragment (`catalog: "<file>"`).
    fn catalog_fragment(&self) -> Option<Value> {
        let file = self.manifest.get("catalog").and_then(Value::as_str)?;
        self.read(file).and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
    }

    /// The fragment's `family` and the entry of `op`.
    pub fn catalog_op(&self, op: &str) -> Option<(String, Value)> {
        let catalog = self.catalog_fragment()?;
        let family = catalog.get("family").and_then(Value::as_str)?.to_string();
        let entry = catalog
            .get("operations")?
            .as_array()?
            .iter()
            .find(|e| e.get("name").and_then(Value::as_str) == Some(op))?
            .clone();
        Some((family, entry))
    }

    /// The catalog ops whose user runs get an open token: `options.openOps`
    /// of the app's terminal backend and connector implementations.
    pub fn open_ops(&self) -> BTreeSet<String> {
        ["cmux.terminal.backend/1", "cmux.terminal.connector/1"]
            .iter()
            .filter_map(|interface| {
                self.manifest.get("implements")?.get(*interface)?.pointer("/options/openOps")
            })
            .filter_map(Value::as_array)
            .flatten()
            .filter_map(|op| op.as_str().map(str::to_string))
            .collect()
    }

    /// The fragment name of `op`. Full names are canonical: for a
    /// first-party app `cmux.<name>` resolves to its op `<name>`
    /// (`cmux.cloud.machine.list` -> `cloud.machine.list`), and the short
    /// name stays accepted. A third-party op name is already its namespace
    /// (`<publisher>.<name>.<verb>`), so nothing is stripped.
    pub fn resolve_op<'a>(&self, op: &'a str) -> &'a str {
        match op.strip_prefix("cmux.") {
            Some(short)
                if self.tier == Tier::FirstParty
                    && self.catalog_op(op).is_none()
                    && self.catalog_op(short).is_some() =>
            {
                short
            }
            _ => op,
        }
    }

    /// The full name of a server event `name` of this app: `cmux.<name>`
    /// for a first-party app, unchanged for a third-party one.
    pub fn full_name(&self, name: &str) -> String {
        if self.tier == Tier::FirstParty && !name.starts_with("cmux.") {
            format!("cmux.{name}")
        } else {
            name.to_string()
        }
    }

    /// The export behind a catalog op of the app.
    pub fn export_for_op(&self, op: &str) -> Option<String> {
        let (_, entry) = self.catalog_ops().into_iter().find(|(name, _)| name == op)?;
        entry.get("export")?.as_str().map(str::to_string)
    }

    /// The app's palette commands for `apps-list`: the catalog ops with a
    /// `palette` entry, as `{op, title, when?}`.
    pub fn palette_commands(&self) -> Vec<Value> {
        self.catalog_ops()
            .into_iter()
            .filter_map(|(op, entry)| {
                let palette = entry.get("palette")?.as_object()?;
                let title =
                    palette.get("title").cloned().unwrap_or_else(|| Value::String(op.clone()));
                let mut command = serde_json::json!({ "op": op, "title": title });
                if let Some(when) = palette.get("when") {
                    command["when"] = when.clone();
                }
                Some(command)
            })
            .collect()
    }

    /// Whether the app has a script (`runtime.main`). A native-pane app
    /// (`cmux.pane/1` with `native`) has none: it installs and lists like
    /// any app, and the supervisor never spawns a host for it.
    pub fn has_runtime(&self) -> bool {
        self.manifest.pointer("/runtime/main").and_then(Value::as_str).is_some()
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
    /// The first-party bundles shipped with cmux: every valid package here is
    /// a default app (installed for everyone with its required scopes,
    /// hideable, removable with a tombstone). The Mac app passes
    /// `Contents/Resources/apps/first-party` as `CMUX_APPS_FIRST_PARTY_DIR`;
    /// elsewhere it is `apps/first-party` next to the daemon.
    pub first_party: Option<PathBuf>,
    /// Directories of other app packages shipped with cmux (samples).
    pub bundled: Vec<PathBuf>,
    /// The local development directory (`<state>/apps/local`).
    pub local: Option<PathBuf>,
    /// `CMUX_APPS_DEFAULT` (comma separated): replaces the first-party
    /// directory as the default set when present.
    pub defaults: Option<Vec<String>>,
}

impl Sources {
    pub fn from_env(state_dir: Option<&Path>) -> Self {
        let exe_dir =
            std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf));
        let first_party = std::env::var_os("CMUX_APPS_FIRST_PARTY_DIR")
            .map(PathBuf::from)
            .or_else(|| exe_dir.as_ref().map(|d| d.join("apps").join("first-party")));
        let bundled = match std::env::var_os("CMUX_APPS_DIRS") {
            Some(list) => std::env::split_paths(&list).collect(),
            None => exe_dir.map(|d| vec![d.join("apps")]).unwrap_or_default(),
        };
        let defaults = std::env::var("CMUX_APPS_DEFAULT").ok().map(|list| {
            list.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
        });
        Self {
            first_party,
            bundled,
            local: state_dir.map(|d| d.join("apps").join("local")),
            defaults,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DirKind {
    FirstParty,
    Bundled,
    Local,
}

pub fn load(sources: &Sources) -> Catalog {
    let mut catalog = Catalog::default();
    let mut dirs: Vec<(PathBuf, DirKind)> = Vec::new();
    dirs.extend(sources.first_party.iter().map(|d| (d.clone(), DirKind::FirstParty)));
    dirs.extend(sources.bundled.iter().map(|d| (d.clone(), DirKind::Bundled)));
    dirs.extend(sources.local.iter().map(|d| (d.clone(), DirKind::Local)));
    let mut shipped_first_party = Vec::new();
    for (root, kind) in dirs {
        let Ok(entries) = std::fs::read_dir(&root) else { continue };
        let mut paths: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.join("cmux-app.json").is_file() || p.join(V2_MANIFEST).is_file())
            .collect();
        paths.sort();
        for dir in paths {
            match package(&dir, kind) {
                // First source wins: the first-party directory, then bundled,
                // then local (a local package never shadows a shipped id).
                Ok(package) if !catalog.packages.contains_key(&package.id) => {
                    if kind == DirKind::FirstParty {
                        shipped_first_party.push(package.id.clone());
                    }
                    catalog.packages.insert(package.id.clone(), package);
                }
                Ok(_) => {}
                Err(issue) => catalog.rejected.push((dir, issue)),
            }
        }
    }
    catalog.defaults = sources.defaults.clone().unwrap_or(shipped_first_party);
    for id in &catalog.defaults {
        if let Some(package) = catalog.packages.get_mut(id) {
            package.source = Source::Default;
        }
    }
    catalog
}

/// First-party bundles carry their manifest v2 here next to the v1 file the
/// in-app prototype still reads; the supervisor prefers it.
pub const V2_MANIFEST: &str = "cmux-app.v2.json";

/// The manifest file the supervisor reads in `dir`: the v2 file in the
/// first-party directory, else `cmux-app.json`, else a v2-only package's
/// `cmux-app.v2.json` (native-pane apps such as Home ship only that).
pub fn manifest_file(dir: &Path, first_party_dir: bool) -> &'static str {
    let v2 = dir.join(V2_MANIFEST).is_file();
    if v2 && (first_party_dir || !dir.join("cmux-app.json").is_file()) {
        V2_MANIFEST
    } else {
        "cmux-app.json"
    }
}

fn package(dir: &Path, kind: DirKind) -> Result<Package, String> {
    let report = cmux_app_manifest::validate_package_file(
        dir,
        manifest_file(dir, kind == DirKind::FirstParty),
    );
    if !report.is_valid() {
        let first = report.issues.iter().find(|i| i.severity == cmux_app_manifest::Severity::Error);
        return Err(first
            .map(|i| format!("{} {}: {}", i.path, i.code, i.message))
            .unwrap_or_default());
    }
    let manifest = report.manifest.ok_or("no manifest")?;
    let id = manifest["id"].as_str().unwrap_or_default().to_string();
    let publisher = id.split('/').next().unwrap_or_default();
    let first_party = FIRST_PARTY.contains(&publisher);
    match kind {
        DirKind::Local if publisher != "local" => {
            return Err(format!("{id}: the local directory only holds local/ apps"));
        }
        DirKind::FirstParty if !first_party => {
            return Err(format!("{id}: the first-party directory only holds first-party apps"));
        }
        _ => {}
    }
    let tier =
        if first_party && kind != DirKind::Local { Tier::FirstParty } else { Tier::Unverified };
    let source = if kind == DirKind::Local || publisher == "local" {
        Source::Local
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalog_fragments_give_exports_and_palette_commands() {
        let dir = std::env::temp_dir().join(format!("cmux-apps-catalog-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let catalog = json!({ "family": "notes", "operations": [
            { "name": "notes.export", "export": "exportNotes", "palette": { "title": { "en": "Export" }, "when": "paneFocused:editor" } },
            { "name": "notes.open", "export": "open" }
        ] });
        std::fs::write(dir.join("catalog.json"), catalog.to_string()).unwrap();
        let package = Package {
            id: "cmux/notes".into(),
            version: "1.0.0".into(),
            tier: Tier::FirstParty,
            source: Source::Bundled,
            dir: dir.clone(),
            manifest: json!({ "catalog": "catalog.json" }),
        };
        let export = package.export_for_op("notes.open");
        let commands = package.palette_commands();
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(export.as_deref(), Some("open"));
        assert_eq!(
            commands,
            vec![
                json!({ "op": "notes.export", "title": { "en": "Export" }, "when": "paneFocused:editor" })
            ]
        );
    }
}
