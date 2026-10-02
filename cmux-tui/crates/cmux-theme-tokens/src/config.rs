//! Reads the Ghostty config the way libghostty does, for the colors only:
//! default files per platform, `config-file` includes, `theme = ` (with
//! `light:`/`dark:` pairs) looked up in Ghostty's theme directories, and the
//! user's explicit colors on top of the theme.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use crate::{Rgb, ThemeInput, colors::parse_color};

/// Which variant of a `light:X,dark:Y` theme pair applies.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Appearance {
    Light,
    #[default]
    Dark,
}

/// The environment values the lookup depends on, so tests pass fixed ones.
#[derive(Clone, Debug, Default)]
pub struct Env {
    pub home: Option<PathBuf>,
    pub xdg_config_home: Option<PathBuf>,
    /// Windows: `%LOCALAPPDATA%` (Ghostty's config home there).
    pub local_app_data: Option<PathBuf>,
    pub ghostty_resources_dir: Option<PathBuf>,
    pub xdg_data_dirs: Option<String>,
    /// The running executable's directory (finds an app bundle's themes).
    pub exe_dir: Option<PathBuf>,
    /// `CMUX2_TEST_GHOSTTY_CONFIG`: load exactly this file instead of the
    /// default files (the terminal honors the same variable).
    pub only_file: Option<PathBuf>,
    /// A `theme` spec in effect before the user's files, like cmux-next's
    /// `GhosttyRuntime.loadThemeDefault` (the user's own `theme`, even an
    /// empty one, replaces it). The app sets it from
    /// [`Env::default_theme_spec`] and loads the same line into the terminal.
    pub default_theme: Option<String>,
}

/// cmux-next's default terminal theme (`GhosttyRuntime+DefaultTheme.swift`):
/// Ghostty's bundled "Apple System Colors" in dark mode and "Apple System
/// Colors Light" in light mode, instead of Ghostty's own default.
pub const DEFAULT_DARK_THEME: &str = "Apple System Colors";
pub const DEFAULT_LIGHT_THEME: &str = "Apple System Colors Light";

fn non_empty_path(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from)
}

impl Env {
    /// The process environment.
    pub fn current() -> Self {
        Env {
            home: non_empty_path("HOME").or_else(|| non_empty_path("USERPROFILE")),
            xdg_config_home: non_empty_path("XDG_CONFIG_HOME"),
            local_app_data: non_empty_path("LOCALAPPDATA"),
            ghostty_resources_dir: non_empty_path("GHOSTTY_RESOURCES_DIR"),
            xdg_data_dirs: std::env::var("XDG_DATA_DIRS").ok().filter(|v| !v.is_empty()),
            exe_dir: std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)),
            only_file: non_empty_path("CMUX2_TEST_GHOSTTY_CONFIG"),
            default_theme: None,
        }
    }

    /// cmux-next's default theme as a Ghostty `theme` value with absolute
    /// paths (the first theme directory that has the file), so the terminal
    /// and the chrome read the same file: `light:<Light>,dark:<Dark>`, or
    /// only the dark file when `follows_appearance` is false (a terminal
    /// that cannot switch its color scheme). None when a file is missing:
    /// then both fall back to Ghostty's default.
    pub fn default_theme_spec(&self, follows_appearance: bool) -> Option<String> {
        let find =
            |name: &str| self.theme_dirs().into_iter().map(|d| d.join(name)).find(|p| p.is_file());
        let dark = find(DEFAULT_DARK_THEME)?;
        if !follows_appearance {
            return Some(dark.to_string_lossy().into_owned());
        }
        let light = find(DEFAULT_LIGHT_THEME)?;
        Some(format!("light:{},dark:{}", light.to_string_lossy(), dark.to_string_lossy()))
    }

    /// Ghostty's config home: `$XDG_CONFIG_HOME`, else `%LOCALAPPDATA%` on
    /// Windows, else `~/.config`.
    fn config_home(&self) -> Option<PathBuf> {
        if let Some(dir) = &self.xdg_config_home {
            return Some(dir.clone());
        }
        if cfg!(windows)
            && let Some(dir) = &self.local_app_data
        {
            return Some(dir.clone());
        }
        self.home.as_ref().map(|h| h.join(".config"))
    }

    fn mac_app_support(&self) -> Option<PathBuf> {
        if !cfg!(target_os = "macos") {
            return None;
        }
        self.home.as_ref().map(|h| h.join("Library/Application Support/com.mitchellh.ghostty"))
    }

    /// The files libghostty's `ghostty_config_load_default_files` reads, in
    /// order (later files win): `<config home>/ghostty/config` and
    /// `config.ghostty`, then on macOS the same two in
    /// `~/Library/Application Support/com.mitchellh.ghostty`. With
    /// `only_file`, just that file.
    pub fn config_files(&self) -> Vec<PathBuf> {
        if let Some(only) = &self.only_file {
            return vec![only.clone()];
        }
        let mut files = Vec::new();
        for dir in [self.config_home().map(|d| d.join("ghostty")), self.mac_app_support()]
            .into_iter()
            .flatten()
        {
            files.push(dir.join("config"));
            files.push(dir.join("config.ghostty"));
        }
        files
    }

    /// Directories searched for a theme name, most preferred first. Starts
    /// like libghostty (user themes, then `GHOSTTY_RESOURCES_DIR`), then the
    /// app bundle's own copy and Ghostty's install locations, so the chrome
    /// finds the theme even before the app sets `GHOSTTY_RESOURCES_DIR`.
    pub fn theme_dirs(&self) -> Vec<PathBuf> {
        let mut dirs = Vec::new();
        if let Some(home) = self.config_home() {
            dirs.push(home.join("ghostty/themes"));
        }
        if let Some(dir) = self.mac_app_support() {
            dirs.push(dir.join("themes"));
        }
        if let Some(res) = &self.ghostty_resources_dir {
            dirs.push(res.join("themes"));
        }
        if let Some(exe) = &self.exe_dir {
            // macOS bundle (Contents/MacOS -> Contents/Resources) and a
            // portable layout (share/ghostty beside the binary).
            dirs.push(exe.join("../Resources/ghostty/themes"));
            dirs.push(exe.join("share/ghostty/themes"));
        }
        if cfg!(target_os = "macos") {
            dirs.push(PathBuf::from("/Applications/Ghostty.app/Contents/Resources/ghostty/themes"));
        }
        if !cfg!(windows) {
            let data =
                self.xdg_data_dirs.clone().unwrap_or_else(|| "/usr/local/share:/usr/share".into());
            for d in data.split(':').filter(|d| !d.is_empty()) {
                dirs.push(Path::new(d).join("ghostty/themes"));
            }
        }
        dirs
    }

    fn expand(&self, raw: &str, base: Option<&Path>) -> PathBuf {
        if let Some(rest) = raw.strip_prefix("~/")
            && let Some(home) = &self.home
        {
            return home.join(rest);
        }
        let p = PathBuf::from(raw);
        match base {
            Some(base) if p.is_relative() => base.join(p),
            _ => p,
        }
    }
}

/// What was read, and the colors it gives.
#[derive(Clone, Debug)]
pub struct Loaded {
    pub input: ThemeInput,
    /// The theme name in effect for the appearance, if any.
    pub theme: Option<String>,
    /// The theme file that was applied.
    pub theme_file: Option<PathBuf>,
    /// Every config file that was read, in order.
    pub files: Vec<PathBuf>,
    /// Files whose creation, change or removal changes the result (see
    /// [`Loaded::watch_paths`]).
    watch: Vec<PathBuf>,
    /// Problems worth logging (missing theme, bad color, missing include).
    pub diagnostics: Vec<String>,
}

impl Loaded {
    /// The files to watch for live reload: every default config file
    /// (present or not, so creating one is noticed), every include, the
    /// theme file (or, for an unresolved name, each place it could appear),
    /// plus symlink targets. Watch their parent directories (editors save by
    /// rename) and reload when an event names one of these paths.
    pub fn watch_paths(&self) -> &[PathBuf] {
        &self.watch
    }
}

struct Entry {
    key: String,
    value: String,
    file: PathBuf,
    line: usize,
}

fn parse_file(path: &Path) -> Option<Vec<Entry>> {
    let text = std::fs::read_to_string(path).ok()?;
    Some(parse_text(&text, path))
}

fn parse_text(text: &str, path: &Path) -> Vec<Entry> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = match line.split_once('=') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => (line, ""),
        };
        let value = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
        out.push(Entry {
            key: key.to_owned(),
            value: value.to_owned(),
            file: path.to_path_buf(),
            line: i + 1,
        });
    }
    out
}

/// The theme name for `appearance` from a `theme` value: `Name`, or
/// `light:A,dark:B` (either order; a missing side uses the other).
pub fn theme_for(value: &str, appearance: Appearance) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let (mut light, mut dark, mut plain) = (None, None, None);
    for part in value.split(',') {
        let part = part.trim();
        if let Some(n) = part.strip_prefix("light:") {
            light = Some(n.trim().to_owned());
        } else if let Some(n) = part.strip_prefix("dark:") {
            dark = Some(n.trim().to_owned());
        } else if !part.is_empty() {
            plain = Some(part.to_owned());
        }
    }
    if light.is_none() && dark.is_none() {
        // A plain name may contain a comma-free name only; keep it whole.
        return plain.or_else(|| Some(value.to_owned()));
    }
    match appearance {
        Appearance::Light => light.or(dark),
        Appearance::Dark => dark.or(light),
    }
}

/// Loads the colors for `appearance` from the config `env` points at.
pub fn load(env: &Env, appearance: Appearance) -> Loaded {
    let mut diagnostics = Vec::new();
    let mut watch = Vec::new();
    let mut files = Vec::new();
    let mut entries: Vec<Entry> = Vec::new();
    let mut seen = HashSet::new();
    // config-file includes load after every default file, in the order they
    // appear; an include's own includes go to the back of the queue.
    let mut pending: Vec<(PathBuf, bool)> = Vec::new();

    let mut read = |path: &Path,
                    optional: bool,
                    entries: &mut Vec<Entry>,
                    pending: &mut Vec<(PathBuf, bool)>,
                    diagnostics: &mut Vec<String>| {
        let key = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if !seen.insert(key) {
            return;
        }
        let Some(parsed) = parse_file(path) else {
            if !optional {
                diagnostics.push(format!("config-file {} not found", path.display()));
            }
            return;
        };
        files.push(path.to_path_buf());
        let base = path.parent().map(Path::to_path_buf);
        for e in parsed {
            if e.key == "config-file" {
                if e.value.is_empty() {
                    continue;
                }
                let (raw, opt) = match e.value.strip_prefix('?') {
                    Some(r) => (r.trim(), true),
                    None => (e.value.as_str(), false),
                };
                let raw = raw.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(raw);
                pending.push((env.expand(raw, base.as_deref()), opt));
            } else {
                entries.push(e);
            }
        }
    };

    for path in env.config_files() {
        watch.push(path.clone());
        read(&path, true, &mut entries, &mut pending, &mut diagnostics);
    }
    let mut next = 0;
    while next < pending.len() {
        let (path, optional) = pending[next].clone();
        next += 1;
        watch.push(path.clone());
        read(&path, optional, &mut entries, &mut pending, &mut diagnostics);
    }

    // The theme: last `theme` wins; an empty value resets it. Without one,
    // the app's default (cmux-next: Apple System Colors) applies.
    let theme_value = entries
        .iter()
        .rev()
        .find(|e| e.key == "theme")
        .map(|e| e.value.clone())
        .or_else(|| env.default_theme.clone())
        .unwrap_or_default();
    let theme = theme_for(&theme_value, appearance);
    let mut input = ThemeInput::GHOSTTY_DEFAULT;
    let mut theme_file = None;
    if let Some(name) = &theme {
        let candidates: Vec<PathBuf> = if Path::new(name).is_absolute() {
            vec![PathBuf::from(name)]
        } else if name.contains('/') || name.contains('\\') {
            diagnostics.push(format!("theme {name:?}: a theme path must be absolute"));
            Vec::new()
        } else {
            env.theme_dirs().into_iter().map(|d| d.join(name)).collect()
        };
        match candidates.iter().find(|p| p.is_file()) {
            Some(path) => {
                watch.push(path.clone());
                theme_file = Some(path.clone());
                for e in parse_file(path).unwrap_or_default() {
                    if e.key != "theme" && e.key != "config-file" {
                        apply(&mut input, &e, &mut diagnostics);
                    }
                }
            }
            None => {
                watch.extend(candidates);
                diagnostics.push(format!("theme {name:?} not found"));
            }
        }
    }
    // The user's own colors win over the theme's, wherever they appear.
    for e in &entries {
        if e.key != "theme" {
            apply(&mut input, e, &mut diagnostics);
        }
    }

    // Symlinked configs (dotfile repos): watch the target too.
    let targets: Vec<PathBuf> =
        watch.iter().filter_map(|p| std::fs::canonicalize(p).ok().filter(|c| c != p)).collect();
    watch.extend(targets);
    let mut unique = HashSet::new();
    watch.retain(|p| unique.insert(p.clone()));

    Loaded { input, theme, theme_file, files, watch, diagnostics }
}

fn apply(input: &mut ThemeInput, e: &Entry, diagnostics: &mut Vec<String>) {
    let default = ThemeInput::GHOSTTY_DEFAULT;
    let bad = |diagnostics: &mut Vec<String>| {
        diagnostics.push(format!(
            "{}:{}: invalid {} {:?}",
            e.file.display(),
            e.line,
            e.key,
            e.value
        ));
    };
    let color = |diagnostics: &mut Vec<String>| -> Option<Rgb> {
        let c = parse_color(&e.value);
        if c.is_none() {
            bad(diagnostics);
        }
        c
    };
    match e.key.as_str() {
        "background" if e.value.is_empty() => input.background = default.background,
        "background" => input.background = color(diagnostics).unwrap_or(input.background),
        "foreground" if e.value.is_empty() => input.foreground = default.foreground,
        "foreground" => input.foreground = color(diagnostics).unwrap_or(input.foreground),
        "palette" if e.value.is_empty() => input.palette = default.palette,
        "palette" => {
            let Some((index, value)) = e.value.split_once('=') else { return bad(diagnostics) };
            let (Ok(index), Some(c)) = (index.trim().parse::<usize>(), parse_color(value)) else {
                return bad(diagnostics);
            };
            if let Some(slot) = input.palette.get_mut(index) {
                *slot = c;
            }
        }
        "selection-background" | "selection-foreground" => {
            // `cell-foreground` / `cell-background` follow the cell: no fixed color.
            let c = if e.value.is_empty() || e.value.starts_with("cell-") {
                None
            } else {
                color(diagnostics)
            };
            if e.key == "selection-background" {
                input.selection_background = c;
            } else {
                input.selection_foreground = c;
            }
        }
        "background-opacity" if e.value.is_empty() => input.background_opacity = 1.0,
        "background-opacity" => match e.value.parse::<f64>() {
            Ok(v) => input.background_opacity = v.clamp(0.0, 1.0),
            Err(_) => bad(diagnostics),
        },
        "background-blur" | "background-blur-radius" => {
            input.background_blur = match e.value.as_str() {
                "" | "false" => 0,
                "true" => 20,
                "macos-glass-regular" => -1,
                "macos-glass-clear" => -2,
                v => match v.parse::<i32>() {
                    Ok(n) => n.max(0),
                    Err(_) => return bad(diagnostics),
                },
            }
        }
        _ => {}
    }
}
