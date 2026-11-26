//! The doctor's folder pass and the small helpers its passes share: where a
//! customization file sits when cmux does not look there, and how a path,
//! a size or a key's line is said. Split from doctor.rs to keep it small.

use super::*;

impl Customize {
    /// Customization files where cmux does not look, and files in a part's
    /// folder that it does not read.
    pub(super) fn folder_findings(&self, out: &mut Found) {
        let roots = self.roots();
        let config = &roots.config_dir;
        let wrong = |out: &mut Found, path: &Path, belongs: String| {
            let shown = display_dir(path, roots);
            out.push(
                FindingKind::WrongFolder,
                Level::Info,
                &shown,
                format!("{shown} is in the wrong folder"),
                format!(
                    "cmux does not read it there, so it changes nothing. It belongs in {belongs}."
                ),
                shown.clone(),
                Some(path),
                None,
                vec![Fix::open(true), Fix::remove()],
            );
        };
        // <config>/theme.css, <config>/<not a surface>/theme.css
        for name in dir_names(config) {
            let path = config.join(&name);
            if name == "theme.css" && path.is_file() {
                wrong(
                    out,
                    &path,
                    format!(
                        "{}/<surface>/theme.css (surfaces: {})",
                        display_dir(config, roots),
                        STYLE_SURFACES.join(", ")
                    ),
                );
                continue;
            }
            if path.is_dir()
                && !STYLE_SURFACES.contains(&name.as_str())
                && path.join("theme.css").is_file()
            {
                let near = nearest_surface(&name);
                wrong(
                    out,
                    &path.join("theme.css"),
                    match near {
                        Some(surface) => {
                            format!("{}/{surface}/theme.css", display_dir(config, roots))
                        }
                        None => format!(
                            "one of {}/{{{}}}/theme.css",
                            display_dir(config, roots),
                            STYLE_SURFACES.join(",")
                        ),
                    },
                );
                continue;
            }
            // A theme at the top: a JSON object with `colors` or `ghostty`.
            if path.is_file()
                && name.ends_with(".json")
                && !KNOWN_TOP_FILES.contains(&name.as_str())
                && !secret_name(&name)
                && Some(path.as_path()) != Some(roots.settings_file.as_path())
                && looks_like_theme(&path)
            {
                wrong(
                    out,
                    &path,
                    format!("{}/{name}", display_dir(&theme_file::folder(config), roots)),
                );
            }
        }
        // themes/: only NAME.json at the top is read.
        let themes = theme_file::folder(config);
        for name in dir_names(&themes) {
            let path = themes.join(&name);
            if path.is_dir() {
                for inner in dir_names(&path).into_iter().filter(|inner| inner.ends_with(".json")) {
                    wrong(
                        out,
                        &path.join(&inner),
                        format!("{}/{inner}", display_dir(&themes, roots)),
                    );
                }
            } else if !name.ends_with(".json") && is_customization_text(&name) {
                let shown = display_dir(&path, roots);
                out.push(
                    FindingKind::Ignored,
                    Level::Info,
                    &shown,
                    format!("{shown} is not read"),
                    "The themes folder reads only NAME.json files, so this one never applies; rename it to .json to use it.".to_owned(),
                    shown.clone(),
                    Some(&path),
                    None,
                    vec![Fix::open(true), Fix::remove()],
                );
            }
        }
        // automations/: one folder each, with automation.json in it.
        let automations = config.join("automations");
        for name in dir_names(&automations) {
            let path = automations.join(&name);
            if path.is_file() && name.ends_with(".json") {
                let stem = name.trim_end_matches(".json");
                wrong(
                    out,
                    &path,
                    format!("{}/{stem}/automation.json", display_dir(&automations, roots)),
                );
            }
        }
        // A views app's manifest at the top of the config folder.
        if roots.customize_dir != *config {
            for name in ["cmux-app.json", "cmux-app.v2.json"] {
                let path = config.join(name);
                if path.is_file() {
                    wrong(
                        out,
                        &path,
                        format!("{}/{name}", display_dir(&roots.customize_dir, roots)),
                    );
                }
            }
        }
        // The views folder with files and no manifest: nothing in it loads.
        let customize = &roots.customize_dir;
        let names = dir_names(customize);
        if !names.is_empty()
            && !names.iter().any(|name| name == "cmux-app.json" || name == "cmux-app.v2.json")
            && names.iter().any(|name| name.ends_with(".js") || name.ends_with(".ts"))
        {
            let shown = display_dir(customize, roots);
            out.push(
                FindingKind::Leftover,
                Level::Info,
                &shown,
                format!("{shown} has scripts and no cmux-app.json"),
                "Without its manifest nothing in this folder loads: what a removed views app or recipe left, or a manifest that was deleted.".to_owned(),
                shown.clone(),
                Some(customize),
                None,
                vec![Fix::open(true)],
            );
        }
    }
}

/// Names the general settings file accepts, including its migration inputs.
/// Keep the prefixes too so an unknown sibling still gets its own finding.
#[derive(Default)]
struct SettingNames {
    leaves: BTreeSet<&'static str>,
    prefixes: BTreeSet<&'static str>,
}

impl SettingNames {
    fn get() -> &'static Self {
        use cmux_config::schema::{
            DESKTOP_BRIDGE_ENABLED, DESKTOP_BRIDGE_ENTRYPOINTS, retired_entries,
        };
        static NAMES: std::sync::OnceLock<SettingNames> = std::sync::OnceLock::new();
        NAMES.get_or_init(|| {
            let mut names = SettingNames::default();
            for key in Schema::embedded()
                .rows_in(None)
                .map(|row| row.key.as_str())
                .chain(retired_entries().iter().map(|entry| entry.key.as_str()))
                .chain([DESKTOP_BRIDGE_ENABLED, DESKTOP_BRIDGE_ENTRYPOINTS])
                // Menu sections the doctor checks itself (`menus.rs`).
                .chain(menus::SECTIONS.iter().copied())
            {
                names.leaves.insert(key);
                names.prefixes.extend(key.match_indices('.').map(|(at, _)| &key[..at]));
            }
            names
        })
    }

    fn collect_unknown(
        &self,
        object: &serde_json::Map<String, Value>,
        parent: &str,
        out: &mut Vec<String>,
    ) {
        for (key, value) in object {
            if parent.is_empty() && key.starts_with('$') {
                continue;
            }
            // Both nested objects and dotted names occur in settings documents.
            let path = if parent.is_empty() { key.clone() } else { format!("{parent}.{key}") };
            if self.leaves.contains(path.as_str()) {
                continue;
            }
            if self.prefixes.contains(path.as_str()) {
                if let Value::Object(inner) = value {
                    self.collect_unknown(inner, &path, out);
                }
            } else {
                out.push(path);
            }
        }
    }
}

pub(super) fn unknown_keys(object: &serde_json::Map<String, Value>) -> Vec<String> {
    let mut unknown = Vec::new();
    SettingNames::get().collect_unknown(object, "", &mut unknown);
    unknown
}

/// The 1-based line where a dotted key's last name is written as a key.
pub(super) fn line_of_key(text: &str, dotted: &str) -> Option<u32> {
    let name = dotted.rsplit('.').next().filter(|name| !name.is_empty())?;
    let needle = format!("\"{name}\"");
    text.match_indices(&needle)
        .find(|(at, _)| {
            text.get(at + needle.len()..).is_some_and(|after| after.trim_start().starts_with(':'))
        })
        .map(|(at, _)| text.get(..at).unwrap_or_default().matches('\n').count() as u32 + 1)
}

pub(super) fn looks_like_theme(path: &Path) -> bool {
    // Size first: a large file is no theme, and is never read whole.
    if std::fs::metadata(path).map_or(true, |meta| meta.len() > theme_file::MAXIMUM_BYTES as u64) {
        return false;
    }
    let Ok(text) = std::fs::read_to_string(path) else { return false };
    if text.len() > theme_file::MAXIMUM_BYTES {
        return false;
    }
    matches!(jsonc::parse(&text), Ok(Value::Object(object))
        if object.contains_key("colors") || object.contains_key("ghostty"))
}

pub(super) fn is_customization_text(name: &str) -> bool {
    !name.starts_with('.')
        && !name.ends_with('~')
        && [".jsonc", ".json5", ".json.bak", ".json.txt", ".theme", ".txt"]
            .iter()
            .any(|ending| name.to_lowercase().ends_with(ending))
}

/// The surface a misspelled folder means: `agentpane`, `Agent_Pane` -> `agent-pane`.
pub(super) fn nearest_surface(name: &str) -> Option<&'static str> {
    let squash = |text: &str| {
        text.chars()
            .filter(char::is_ascii_alphanumeric)
            .map(|c| c.to_ascii_lowercase())
            .collect::<String>()
    };
    let want = squash(name);
    STYLE_SURFACES.iter().copied().find(|surface| squash(surface) == want)
}

pub(super) fn dir_names(dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| !name.starts_with('.'))
        .collect();
    names.sort();
    names
}

/// The bytes under `dir`, reading at most `limit` entries.
pub(super) fn dir_bytes(dir: &Path, limit: usize) -> u64 {
    let mut total = 0;
    let mut seen = 0;
    let mut pending = vec![dir.to_path_buf()];
    while let Some(folder) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        for entry in entries.flatten() {
            seen += 1;
            if seen > limit {
                return total;
            }
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => pending.push(entry.path()),
                Ok(kind) if kind.is_file() => {
                    total += entry.metadata().map(|meta| meta.len()).unwrap_or_default();
                }
                _ => {}
            }
        }
    }
    total
}

pub(super) fn size_words(bytes: u64) -> String {
    match bytes {
        0..1_000_000 => format!("{} KB", bytes.div_ceil(1000)),
        _ => format!("{:.1} MB", bytes as f64 / 1_000_000.0),
    }
}

pub(super) fn file_name(path: &Path) -> String {
    path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
}

/// A logical path as a person finds it: the settings file by its name.
pub(super) fn display_path(logical: &str, roots: &crate::Roots) -> String {
    if logical == SETTINGS { file_name(&roots.settings_file) } else { logical.to_owned() }
}

/// `~/.config/cmux/themes`, or the path when it is not under home.
pub(super) fn display_dir(path: &Path, roots: &crate::Roots) -> String {
    if let Ok(rest) = path.strip_prefix(&roots.config_dir)
        && !rest.as_os_str().is_empty()
    {
        return rest.display().to_string();
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from)
        && let Ok(rest) = path.strip_prefix(&home)
    {
        return format!("~/{}", rest.display());
    }
    path.display().to_string()
}

/// `malformed JSON` -> `Malformed JSON`.
pub(super) fn sentence(text: &str) -> String {
    let text = text.trim().trim_end_matches('.');
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}
