//! The apps this machine can run: validated packages from the bundle
//! directories and the local development directory, plus the deployment list
//! of default first-party apps. Every package passes the one manifest v2
//! validator (`cmux-app-manifest`) before the supervisor knows it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::mirror::{Facts, Source, Tier};
use cmux_json::JsonSet as _;

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
    /// The catalog fragment (`catalog: "<file>"`) as the validator read it
    /// when the package loaded. `apps-list` asks every package for its
    /// palette commands under the supervisor lock: read from disk there,
    /// each list read and parsed every app's fragment while every other apps
    /// request waited.
    pub fragment: Option<std::sync::Arc<Value>>,
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

    /// The app's catalog fragment (`catalog: "<file>"`), as loaded.
    fn catalog_fragment(&self) -> Option<&Value> {
        self.manifest.get("catalog").and_then(Value::as_str)?;
        self.fragment.as_deref()
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

    /// The backend op `op` this first-party server app serves
    /// (`serves.ops`), with the backend catalog's policy; `None` when the
    /// app does not serve it, is not a first-party app with a server, or no
    /// server may run it (`super::serves`). `consumes.ops` (ops an app
    /// calls) is never routed to the app's server.
    pub(super) fn served_op(&self, op: &str) -> Option<super::serves::Policy> {
        if self.tier != Tier::FirstParty || self.manifest.get("server").is_none() {
            return None;
        }
        let served = self.manifest.pointer("/serves/ops")?.as_array()?;
        if !served.iter().any(|name| name.as_str() == Some(op)) {
            return None;
        }
        super::serves::policy(op)
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

    /// `presentation.hiddenByDefault`: a default app that starts installed
    /// but hidden until the user shows it (still reachable from the palette,
    /// the CLI and the App Store).
    pub fn hidden_by_default(&self) -> bool {
        self.manifest.pointer("/presentation/hiddenByDefault") == Some(&Value::Bool(true))
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
                    command.set("when", when.clone());
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

    /// The main script's path in the package (`runtime.main`): load errors name it.
    pub fn main_name(&self) -> Option<String> {
        self.manifest.pointer("/runtime/main")?.as_str().map(str::to_string)
    }

    /// The app's main script, read when its host starts.
    pub fn main_source(&self) -> Option<String> {
        let main = self.manifest.pointer("/runtime/main")?.as_str()?;
        String::from_utf8(self.read(main)?).ok()
    }

    /// A file of the package, refused when it (or a symlink on the way)
    /// leaves the package directory.
    pub(super) fn read(&self, relative: &str) -> Option<Vec<u8>> {
        #[cfg(test)]
        work::count(|w| w.package_file_reads += 1);
        let root = self.dir.canonicalize().ok()?;
        let path = self.dir.join(relative).canonicalize().ok()?;
        if !path.starts_with(&root) {
            return None;
        }
        std::fs::read(path).ok()
    }

    /// `strings/<locale>.json` for the full tag (`de-CH`), then its
    /// language (`de`), falling back to English.
    pub fn strings(&self, locale: &str) -> Value {
        let Some(dir) = self.manifest.get("strings").and_then(Value::as_str) else {
            return Value::Null;
        };
        let language = locale.split('-').next().unwrap_or(locale);
        for candidate in [locale, language, "en"] {
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
    /// The setups' views layers that loaded, top first (`Sources::setups`).
    pub setup_layers: Vec<String>,
}

/// Where packages come from.
#[derive(Debug, Clone, Default)]
pub struct Sources {
    /// The first-party bundles shipped with cmux: every valid package here is
    /// a default app (installed for everyone with its required scopes,
    /// hide-only: hidden, never removed). Inside the Mac app it is the
    /// bundle's one copy, found from the daemon's own executable; elsewhere
    /// `apps/first-party` next to the daemon (`crate::first_party_dir`).
    pub first_party: Option<PathBuf>,
    /// Directories of other app packages shipped with cmux (samples), next
    /// to the daemon's real executable.
    pub bundled: Vec<PathBuf>,
    /// `CMUX_APPS_DIRS` (replaces `bundled` when set): its packages are
    /// never first-party, whatever their publisher (no native server, no
    /// served ops).
    pub extra: Vec<PathBuf>,
    /// The local development directory (`<state>/apps/local`).
    pub local: Option<PathBuf>,
    /// The user's own customization app (cx-swovq.1): one package folder,
    /// `$CMUX_CUSTOMIZE_DIR`, else `$XDG_CONFIG_HOME/cmux/customize`, else
    /// `~/.config/cmux/customize`. Its id is `local/customize`; it installs
    /// by itself with its required scopes (the user wrote it) and reloads
    /// when its files change (`local_reload.rs`).
    pub customize: Option<PathBuf>,
    /// Installed setups' own views layers (`cmux setup install`): the
    /// `setups` folder next to the customize folder. Only the folders its
    /// `layers.json` names load, in its order (top first), each as the app
    /// `local/setup-OWNER-NAME`; a setup never writes the person's own
    /// customize folder (cmux-customize `setup::layers`).
    pub setups: Option<PathBuf>,
    /// The person's saved prompts (`cmux agent-config commands add --agent cmux`): one `NAME.md`
    /// each, `$CMUX_COMMANDS_DIR`, else `$XDG_CONFIG_HOME/cmux/commands`, else
    /// `~/.config/cmux/commands`. `apps.composer.list` answers them first, so the composer's `/`
    /// menu lists them in every chat (`composer.rs`).
    pub saved_prompts: Option<PathBuf>,
    /// `CMUX_APPS_DEFAULT` (comma separated): replaces the first-party
    /// directory as the default set when present.
    pub defaults: Option<Vec<String>>,
}

impl Sources {
    pub fn from_env(state_dir: Option<&Path>) -> Self {
        // The real path: a symlinked binary never points the shipped samples at
        // a user-writable directory.
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|exe| std::fs::canonicalize(exe).ok())
            .and_then(|exe| exe.parent().map(Path::to_path_buf));
        // From the daemon's own bundle; the override counts only inside it (cx-0uo1, cx-e0cs).
        let first_party = crate::first_party_dir::current();
        let (bundled, extra) = match crate::first_party_dir::apps_dirs() {
            Some(list) => (Vec::new(), std::env::split_paths(&list).collect()),
            None => (exe_dir.map(|d| vec![d.join("apps")]).unwrap_or_default(), Vec::new()),
        };
        let defaults = std::env::var("CMUX_APPS_DEFAULT").ok().map(|list| {
            list.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
        });
        Self {
            first_party,
            bundled,
            extra,
            local: state_dir.map(|d| d.join("apps").join("local")),
            customize: customize_dir(),
            setups: setups_dir(),
            saved_prompts: std::env::var_os("HOME").filter(|h| !h.is_empty()).map(|home| {
                cmux_agent_customize::paths::cmux_commands_dir(Path::new(&home), |name| {
                    std::env::var_os(name)
                })
            }),
            defaults,
        }
    }
}

/// The customization folder (`Sources::customize`).
pub fn customize_dir() -> Option<PathBuf> {
    let non_empty =
        |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
    if let Some(dir) = non_empty("CMUX_CUSTOMIZE_DIR") {
        return Some(dir);
    }
    let config =
        non_empty("XDG_CONFIG_HOME").or_else(|| non_empty("HOME").map(|h| h.join(".config")))?;
    Some(config.join("cmux").join("customize"))
}

/// The setups' layers folder (`Sources::setups`): `setups` next to the
/// customize folder, as cmux-customize's `Roots::setups_dir`.
pub fn setups_dir() -> Option<PathBuf> {
    customize_dir().map(|dir| dir.with_file_name("setups"))
}

/// The id prefix of a setup's views layer: such an app loads only from the
/// setups folder's index.
pub const SETUP_LAYER_PREFIX: &str = "local/setup-";

/// The setups folder's index of the layers that are on, top first.
pub const SETUP_LAYERS_INDEX: &str = "layers.json";

/// One row of `layers.json` (cmux-customize `setup::layers::IndexRow`).
#[derive(Debug, Clone, serde::Deserialize)]
struct LayerRow {
    app: String,
    dir: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct LayerIndex {
    #[serde(rename = "cmuxSetupLayers")]
    format: u32,
    layers: Vec<LayerRow>,
}

/// (expected app id, folder) per loaded layer, and (path, why) per refusal.
type SetupLayers = (Vec<(String, PathBuf)>, Vec<(PathBuf, String)>);

/// The layers `layers.json` in `root` names, top first: (expected app id,
/// folder). A row whose folder is not a plain `setup-...` name in `root`,
/// or whose app is not `local/<folder>`, is refused with why.
fn setup_layers(root: &Path) -> SetupLayers {
    let file = root.join(SETUP_LAYERS_INDEX);
    let Ok(text) = std::fs::read_to_string(&file) else { return (Vec::new(), Vec::new()) };
    let index: LayerIndex = match serde_json::from_str(&text) {
        Ok(index) => index,
        Err(error) => return (Vec::new(), vec![(file, format!("not readable: {error}"))]),
    };
    if index.format != 1 {
        return (
            Vec::new(),
            vec![(file, format!("format {} is not one this cmux reads", index.format))],
        );
    }
    let mut layers = Vec::new();
    let mut refused = Vec::new();
    for row in index.layers {
        let plain = row.dir.starts_with("setup-")
            && row.dir.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if !plain || row.app != format!("local/{}", row.dir) {
            refused.push((file.clone(), format!("{}: not a setup layer ({})", row.app, row.dir)));
            continue;
        }
        if layers.iter().any(|(app, _)| app == &row.app) {
            continue;
        }
        layers.push((row.app, root.join(&row.dir)));
    }
    (layers, refused)
}

/// The customization app's id: its manifest must use it.
pub const CUSTOMIZE_APP: &str = "local/customize";

#[derive(Clone, Copy, PartialEq, Eq)]
enum DirKind {
    FirstParty,
    Bundled,
    Extra,
    Local,
}

pub fn load(sources: &Sources) -> Catalog {
    load_reusing(sources, &|_| None, &|_| None)
}

/// A package folder's earlier read (`Ok` package or `Err` refusal), when
/// the folder is unchanged since it (`local_reload::PrintsBefore`).
pub type Reuse<'a> = dyn Fn(&Path) -> Option<Result<Package, String>> + 'a;

/// A package root's package folders, sorted, when the caller already knows
/// them (`local_reload::PrintsBefore::listed`); `None` lists the root.
pub type Listed<'a> = dyn Fn(&Path) -> Option<Vec<PathBuf>> + 'a;

/// `load`, taking each package folder's read from `reuse` and each root's
/// package folders from `listed` when they have them: a reload pass a save
/// makes reads and lists only the folders that changed, not every app's
/// manifest and script (one save among 200 apps read 200 scripts).
pub fn load_reusing(sources: &Sources, reuse: &Reuse<'_>, listed: &Listed<'_>) -> Catalog {
    let read = |dir: &Path, kind: DirKind| reuse(dir).unwrap_or_else(|| package(dir, kind));
    let mut catalog = Catalog::default();
    let mut dirs: Vec<(PathBuf, DirKind)> = Vec::new();
    dirs.extend(sources.first_party.iter().map(|d| (d.clone(), DirKind::FirstParty)));
    dirs.extend(sources.bundled.iter().map(|d| (d.clone(), DirKind::Bundled)));
    dirs.extend(sources.extra.iter().map(|d| (d.clone(), DirKind::Extra)));
    dirs.extend(sources.local.iter().map(|d| (d.clone(), DirKind::Local)));
    let mut shipped_first_party = Vec::new();
    for (root, kind) in dirs {
        let paths = match listed(&root) {
            Some(paths) => paths,
            None => {
                let Ok(entries) = std::fs::read_dir(&root) else { continue };
                let mut paths: Vec<PathBuf> = entries
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| p.join("cmux-app.json").is_file() || p.join(V2_MANIFEST).is_file())
                    .collect();
                paths.sort();
                paths
            }
        };
        for dir in paths {
            match read(&dir, kind) {
                // The customize app may run the person's own actions, so only
                // their customize folder (below) provides it.
                Ok(package) if package.id == CUSTOMIZE_APP => catalog
                    .rejected
                    .push((dir, format!("{CUSTOMIZE_APP} loads only from the customize folder"))),
                // A setup's layer is the person's consented install, in its
                // stated order: only the setups folder's index provides one.
                Ok(package) if package.id.starts_with(SETUP_LAYER_PREFIX) => {
                    catalog.rejected.push((
                        dir,
                        format!("{}: a setup layer loads only from the setups folder", package.id),
                    ));
                }
                // First source wins: the first-party directory, then bundled,
                // then local (a local package never shadows a shipped id).
                Ok(package) if !catalog.packages.contains_key(&package.id) => {
                    if kind == DirKind::FirstParty {
                        shipped_first_party.push(package.id.clone());
                    }
                    catalog.packages.insert(package.id.clone(), package);
                }
                // A second folder with a loaded id is refused with the folder
                // that has it, so a person whose saves there change nothing
                // can see why (base: it was dropped without a word).
                Ok(package) => {
                    let first = catalog
                        .packages
                        .get(&package.id)
                        .map(|p| p.dir.display().to_string())
                        .unwrap_or_default();
                    catalog
                        .rejected
                        .push((dir, format!("{}: already loaded from {first}", package.id)));
                }
                Err(issue) => catalog.rejected.push((dir, issue)),
            }
        }
    }
    if let Some(dir) = sources
        .customize
        .as_ref()
        .filter(|dir| dir.join("cmux-app.json").is_file() || dir.join(V2_MANIFEST).is_file())
    {
        match read(dir, DirKind::Local) {
            Ok(package)
                if package.id == CUSTOMIZE_APP && !catalog.packages.contains_key(CUSTOMIZE_APP) =>
            {
                catalog.packages.insert(package.id.clone(), package);
            }
            Ok(package) => catalog.rejected.push((
                dir.clone(),
                format!("{}: the customize folder holds {CUSTOMIZE_APP} only", package.id),
            )),
            Err(issue) => catalog.rejected.push((dir.clone(), issue)),
        }
    }
    if let Some(root) = &sources.setups {
        let (layers, refused) = setup_layers(root);
        catalog.rejected.extend(refused);
        for (app, dir) in layers {
            if !dir.join("cmux-app.json").is_file() && !dir.join(V2_MANIFEST).is_file() {
                continue;
            }
            match read(&dir, DirKind::Local) {
                Ok(package) if package.id == app && !catalog.packages.contains_key(&app) => {
                    catalog.setup_layers.push(app.clone());
                    catalog.packages.insert(app, package);
                }
                Ok(package) => catalog
                    .rejected
                    .push((dir, format!("{}: the layer {app} holds {app} only", package.id))),
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

/// Work counters for the constant-cost tests (`supervisor_scale_tests.rs`):
/// the packages a reload pass validated and the package files an
/// `apps-list` read, on the calling thread.
#[cfg(test)]
pub(super) mod work {
    use std::cell::Cell;

    #[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
    pub struct Work {
        /// Packages read and validated (`catalog::package`).
        pub packages_validated: usize,
        /// Files read through `Package::read` (fragments, scripts, strings).
        pub package_file_reads: usize,
    }

    thread_local! {
        static WORK: Cell<Work> = Cell::new(Work::default());
    }

    pub fn count(f: impl FnOnce(&mut Work)) {
        WORK.with(|cell| {
            let mut work = cell.get();
            f(&mut work);
            cell.set(work);
        });
    }

    /// The work `f` did on this thread.
    pub fn of<T>(f: impl FnOnce() -> T) -> (T, Work) {
        let before = WORK.with(Cell::take);
        let out = f();
        let done = WORK.with(|cell| cell.replace(before));
        (out, done)
    }
}

fn package(dir: &Path, kind: DirKind) -> Result<Package, String> {
    #[cfg(test)]
    work::count(|w| w.packages_validated += 1);
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
    let fragment = report.catalog.map(std::sync::Arc::new);
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
    // First-party only from the shipped directories (the first-party dir and
    // the samples next to the daemon's real executable): a cmux/ or
    // manaflow-ai/ id in a CMUX_APPS_DIRS directory (the store packages) is
    // Verified when cmux's store key signed exactly these files
    // (`store_trust`), else unverified (no native server, no served ops).
    let tier = if first_party && matches!(kind, DirKind::FirstParty | DirKind::Bundled) {
        Tier::FirstParty
    } else if first_party
        && kind == DirKind::Extra
        && super::store_trust::verify(
            dir,
            &id,
            manifest.get("version").and_then(Value::as_str).unwrap_or_default(),
            &super::store_trust::trusted_keys(),
        )
        .is_ok()
    {
        Tier::Verified
    } else {
        Tier::Unverified
    };
    let source = if kind == DirKind::Local || publisher == "local" {
        Source::Local
    } else {
        Source::Bundled
    };
    let package = Package {
        version: manifest["version"].as_str().unwrap_or_default().to_string(),
        id,
        tier,
        source,
        dir: dir.to_path_buf(),
        manifest,
        fragment,
    };
    // A fragment may not define an op the backend catalog owns: such an op
    // is served only through serves.ops, with the backend's policy (fail
    // closed, never a weaker app-declared policy).
    if let Some((name, _)) =
        package.catalog_ops().into_iter().find(|(name, _)| super::serves::is_backend_op(name))
    {
        return Err(format!(
            "{}: its catalog fragment defines {name}, a backend-owned op; list it in serves.ops instead",
            package.id
        ));
    }
    Ok(package)
}

#[cfg(test)]
#[path = "catalog_tests.rs"]
mod tests;
