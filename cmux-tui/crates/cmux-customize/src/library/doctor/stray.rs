//! Files outside the usual settings that still change cmux, and files cmux
//! never reads (Leo, 2026-11-19: "as in like random json that is affecthing
//! things outside of typically expected settings too").
//!
//! ```text
//! cmux-tui.json, mux.json      the terminal daemon's own config: what it sets
//! cmux.json agents.harnesses   classic's file: acpmux still adds its harnesses
//! harnesses/*.toml             agent harness profiles that replace the found ones
//! host-budget.json             the host pressure formula
//! agent-pane/layout.json       the chat header's quick actions
//! agent-pane/registry.js       a script every chat pane runs
//! diff/languages/**.json       extra diff grammars
//! the classic Ghostty layer    Application Support/com.cmuxterm.app/config.ghostty, over your Ghostty config
//! managed preferences          an organization's forced settings, over cmux-next.json
//! CMUX_* in the environment    a variable that moves or turns off a customization
//! anything else *.json         at the top of the config folder: cmux does not read it
//! ```
//!
//! Every finding names the file, what it sets and what it overrides. A file
//! that holds credentials (server.json, keys.json, auth.json, ...) is never
//! opened.

use std::path::{Path, PathBuf};

use cmux_config::jsonc;
use serde_json::Value;

use super::{
    FindingKind, Fix, Found, KNOWN_TOP_FILES, Level, dir_names, display_dir, looks_like_theme,
    secret_name,
};
use crate::Customize;

/// Environment variables that move or turn off part of a customization.
const ENV: &[(&str, &str)] = &[
    (
        "CMUX_NEXT_CONFIG_FILE",
        "moves cmux-next.json, keybindings.json, themes and the surface stylesheets to",
    ),
    ("CMUX_CUSTOMIZE_DIR", "moves your views app to"),
    ("CMUX_NO_CUSTOMIZATIONS", "turns web-dev.json off for this run:"),
    ("CMUX_SAFE_MODE", "starts the daemon in safe mode, every extension off:"),
    ("CMUX_TUI_CONFIG", "replaces cmux-tui.json with"),
    ("CMUX_MUX_CONFIG", "replaces cmux-tui.json with"),
    ("CMUX_NEXT_GHOSTTY_CONFIG", "loads only this Ghostty config, none of yours:"),
    ("CMUX_TUI_PAGES_DIR", "serves the app's pages from"),
    ("CMUX_NEXT_PAGES_DEV_URL", "serves the app's pages from"),
    ("CMUX_APPS_DIRS", "loads extensions from"),
];

impl Customize {
    pub(super) fn stray_findings(&self, out: &mut Found) {
        let config = self.roots().config_dir.clone();
        self.daemon_config(&config, out);
        self.classic_harnesses(&config, out);
        harness_profiles(&config.join("harnesses"), self, out);
        self.json_file(
            &config.join("host-budget.json"),
            "host-budget.json changes the host pressure warning",
            "It replaces the default formula for when cmux warns that this computer is busy.",
            out,
        );
        self.json_file(
            &config.join("agent-pane/layout.json"),
            "agent-pane/layout.json changes the chat header",
            "It sets the quick actions every chat pane's header shows, in place of the default ones.",
            out,
        );
        let registry = config.join("agent-pane/registry.js");
        if registry.is_file() {
            out.push(
                FindingKind::Override,
                Level::Info,
                "agent-pane/registry.js",
                "agent-pane/registry.js runs in every chat pane".to_owned(),
                "It is a script cmux loads into each agent chat, so it can change anything there."
                    .to_owned(),
                "agent-pane/registry.js".to_owned(),
                Some(&registry),
                None,
                vec![Fix::open(false), Fix::remove()],
            );
        }
        let languages = config.join("diff/languages");
        let grammars = json_files(&languages, 200);
        if !grammars.is_empty() {
            for grammar in &grammars {
                self.parse_only(grammar, out);
            }
            out.push(
                FindingKind::Override,
                Level::Info,
                "diff/languages",
                format!("diff/languages adds {} syntax grammars", grammars.len()),
                "The diff viewer colors those languages with them, over its own.".to_owned(),
                display_dir(&languages, self.roots()),
                Some(&languages),
                None,
                vec![Fix::open(true)],
            );
        }
        if let Some(home) = home_of(&config) {
            let support = home.join("Library/Application Support/com.cmuxterm.app");
            for name in ["config.ghostty", "config"] {
                let path = support.join(name);
                if path.is_file() {
                    out.push(
                        FindingKind::Override,
                        Level::Info,
                        &format!("ghostty:{name}"),
                        format!("cmux's own Ghostty file {name} changes the terminal"),
                        "It loads after your Ghostty config, so its font, colors and keys win over ~/.config/ghostty.".to_owned(),
                        format!("~/Library/Application Support/com.cmuxterm.app/{name}"),
                        Some(&path),
                        None,
                        vec![Fix::open(false)],
                    );
                }
            }
            for managed in [
                PathBuf::from("/Library/Managed Preferences/com.manaflow.cmux.plist"),
                home.join("Library/Managed Preferences/com.manaflow.cmux.plist"),
                PathBuf::from("/etc/cmux/managed.json"),
            ] {
                if managed.is_file() {
                    out.push(
                        FindingKind::Override,
                        Level::Info,
                        &format!("managed:{}", managed.display()),
                        "Your organization sets some settings".to_owned(),
                        "Managed preferences force values over cmux-next.json; a key they set shows locked in Settings, and your value for it is not used.".to_owned(),
                        managed.display().to_string(),
                        Some(&managed),
                        None,
                        vec![Fix::open(false)],
                    );
                }
            }
        }
        for (name, what) in ENV {
            let Some(value) = std::env::var_os(name).filter(|value| !value.is_empty()) else {
                continue;
            };
            // A URL keeps only its scheme, host and path: a query or a user may be a credential.
            let value = value.to_string_lossy();
            let value = value.split('?').next().unwrap_or_default();
            let value = match value.split_once("://") {
                Some((scheme, rest)) => {
                    format!("{scheme}://{}", rest.rsplit('@').next().unwrap_or_default())
                }
                None => value.to_owned(),
            };
            if matches!(value.as_ref(), "0" | "false" | "no") {
                continue;
            }
            out.push(
                FindingKind::Override,
                Level::Info,
                &format!("env:{name}"),
                format!("{name} is set"),
                format!("It {what} {value}. It holds for every cmux started with it."),
                format!("environment: {name}"),
                None,
                None,
                Vec::new(),
            );
        }
        // Random JSON at the top of the config folder that nothing reads.
        for name in dir_names(&config) {
            let path = config.join(&name);
            let lower = name.to_lowercase();
            let config_like = [".json", ".jsonc", ".json5", ".toml", ".yaml", ".yml"]
                .iter()
                .any(|ending| lower.ends_with(ending));
            if !config_like
                || !path.is_file()
                || KNOWN_TOP_FILES.contains(&name.as_str())
                || secret_name(&name)
                || path == self.roots().settings_file
                || looks_like_theme(&path)
            {
                continue;
            }
            out.push(
                FindingKind::Ignored,
                Level::Info,
                &name,
                format!("{name} is not a cmux file"),
                format!(
                    "Nothing in cmux reads {name}, so it changes nothing. If it was meant as settings, they go in {}.",
                    super::file_name(&self.roots().settings_file)
                ),
                name.clone(),
                Some(&path),
                None,
                vec![Fix::open(false), Fix::remove()],
            );
        }
    }

    /// cmux-tui.json (or mux.json): the daemon's own config, apart from cmux-next.json.
    fn daemon_config(&self, config: &Path, out: &mut Found) {
        for name in ["cmux-tui.json", "mux.json"] {
            let path = config.join(name);
            let Some(object) = self.parse_only(&path, out) else { continue };
            let keys: Vec<&str> = object.keys().map(String::as_str).take(8).collect();
            if keys.is_empty() {
                continue;
            }
            out.push(
                FindingKind::Override,
                Level::Info,
                name,
                format!("{name} sets {}", keys.join(", ")),
                format!(
                    "The terminal daemon reads it apart from {}: what it sets there wins over the daemon's defaults, and Settings does not show it.",
                    super::file_name(&self.roots().settings_file)
                ),
                name.to_owned(),
                Some(&path),
                None,
                vec![Fix::open(false)],
            );
        }
    }

    /// Classic cmux.json's `agents.harnesses`: acpmux adds them on every load.
    fn classic_harnesses(&self, config: &Path, out: &mut Found) {
        let path = config.join("cmux.json");
        if path == self.roots().settings_file {
            return;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { return };
        let Ok(value) = jsonc::parse(&text) else { return };
        let Some(harnesses) = value.pointer("/agents/harnesses").and_then(Value::as_object) else {
            return;
        };
        if harnesses.is_empty() {
            return;
        }
        let names: Vec<&str> = harnesses.keys().map(String::as_str).collect();
        out.push(
            FindingKind::Override,
            Level::Info,
            "cmux.json#agents.harnesses",
            format!("Classic cmux.json adds agent harnesses: {}", names.join(", ")),
            "cmux NEXT still reads agents.harnesses from classic cmux's cmux.json, over the harnesses it finds by itself.".to_owned(),
            "cmux.json".to_owned(),
            Some(&path),
            None,
            vec![Fix::open(false)],
        );
    }

    /// A JSON file that changes one thing: broken when it does not parse, else one override finding.
    fn json_file(&self, path: &Path, title: &str, detail: &str, out: &mut Found) {
        if self.parse_only(path, out).is_none() {
            return;
        }
        let shown = display_dir(path, self.roots());
        out.push(
            FindingKind::Override,
            Level::Info,
            &shown,
            title.to_owned(),
            detail.to_owned(),
            shown.clone(),
            Some(path),
            None,
            vec![Fix::open(false)],
        );
    }

    /// The object in `path`; a file that does not parse is a broken finding.
    fn parse_only(&self, path: &Path, out: &mut Found) -> Option<serde_json::Map<String, Value>> {
        let text = std::fs::read_to_string(path).ok()?;
        let shown = display_dir(path, self.roots());
        match jsonc::parse(&text) {
            Ok(Value::Object(object)) => Some(object),
            Ok(_) | Err(_) => {
                out.push(
                    FindingKind::Broken,
                    Level::Warning,
                    &shown,
                    format!("{shown} does not load"),
                    "It is not a JSON object, so cmux uses its defaults for what it would set."
                        .to_owned(),
                    shown.clone(),
                    Some(path),
                    None,
                    vec![Fix::open(false)],
                );
                None
            }
        }
    }
}

fn harness_profiles(dir: &Path, customize: &Customize, out: &mut Found) {
    let names: Vec<String> =
        dir_names(dir).into_iter().filter(|name| name.ends_with(".toml")).collect();
    if names.is_empty() {
        return;
    }
    let stems: Vec<&str> = names.iter().map(|name| name.trim_end_matches(".toml")).collect();
    out.push(
        FindingKind::Override,
        Level::Info,
        "harnesses",
        format!("harnesses/ sets agent harnesses: {}", stems.join(", ")),
        "Each file adds an agent harness or replaces the one cmux found by itself (its command, models and environment).".to_owned(),
        display_dir(dir, customize.roots()),
        Some(dir),
        None,
        vec![Fix::open(true)],
    );
}

/// The `.json` files under `dir`, at most `limit`.
fn json_files(dir: &Path, limit: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut pending = vec![dir.to_path_buf()];
    while let Some(folder) = pending.pop() {
        for name in dir_names(&folder) {
            let path = folder.join(&name);
            if path.is_dir() {
                pending.push(path);
            } else if name.ends_with(".json") {
                out.push(path);
                if out.len() >= limit {
                    return out;
                }
            }
        }
    }
    out.sort();
    out
}

/// The home folder when the config folder is the one under it, so the classic
/// app's files are read only for the person's own setup, never a test's or an
/// overridden root's. Only read: nothing here writes there.
fn home_of(config: &Path) -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    config.starts_with(&home).then_some(home)
}
