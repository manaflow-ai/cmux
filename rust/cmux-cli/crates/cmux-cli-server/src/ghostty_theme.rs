use std::collections::{HashSet, VecDeque};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;

use cmux_cli_core::probe;
use cmux_cli_protocol::{
    NativeTerminalCursor, NativeTerminalFont, NativeTerminalTheme, NativeTerminalThemeSet,
};

const MAX_CONFIG_INCLUDE_DEPTH: usize = 16;

#[derive(Debug, Clone, Default)]
struct ParsedGhosttyConfig {
    selection: Option<ThemeSelection>,
    overrides: NativeTerminalTheme,
    font: NativeTerminalFont,
    cursor: NativeTerminalCursor,
}

#[derive(Debug, Clone, Default)]
struct ThemeSelection {
    default: Option<String>,
    light: Option<String>,
    dark: Option<String>,
}

pub fn load_terminal_theme() -> Option<NativeTerminalThemeSet> {
    let config = load_ghostty_config();

    // The cmux overlay config is not visible to `ghostty +show-config`, so
    // prefer the explicit files we load when they declare a theme.
    let theme = resolve_terminal_theme_from_config(&config, &theme_dirs());
    if theme.is_some() {
        if probe::color_enabled() {
            if let Some(theme) = &theme {
                probe::log_event(
                    "ghostty_theme",
                    "terminal_theme_resolved",
                    &[
                        ("source", "config".to_string()),
                        (
                            "selection",
                            theme_selection_summary(config.selection.as_ref()),
                        ),
                        ("config_paths", existing_paths_summary(config_paths())),
                        ("theme", terminal_theme_set_summary(theme)),
                    ],
                );
            }
        }
        return theme;
    }

    // Fall back to Ghostty's resolved config only when cmux/Ghostty files do
    // not declare a theme we can load ourselves.
    let theme = choose_resolved_ghostty_theme(None, load_terminal_theme_from_ghostty());
    if let Some(theme_set) = theme {
        if probe::color_enabled() {
            probe::log_event(
                "ghostty_theme",
                "terminal_theme_resolved",
                &[
                    ("source", "ghostty_show_config".to_string()),
                    ("selection", "-".to_string()),
                    ("config_paths", existing_paths_summary(config_paths())),
                    ("theme", terminal_theme_set_summary(&theme_set)),
                ],
            );
        }
        return Some(theme_set);
    }

    None
}

fn choose_resolved_ghostty_theme(
    config_theme: Option<NativeTerminalThemeSet>,
    show_config_theme: Option<NativeTerminalTheme>,
) -> Option<NativeTerminalThemeSet> {
    if config_theme.is_some() {
        return config_theme;
    }
    show_config_theme.map(|theme| {
        let theme_set = NativeTerminalThemeSet {
            default: Some(theme),
            ..NativeTerminalThemeSet::default()
        };
        theme_set
    })
}

fn load_terminal_theme_from_ghostty() -> Option<NativeTerminalTheme> {
    for binary in ghostty_binary_paths() {
        let Ok(output) = ProcessCommand::new(&binary).arg("+show-config").output() else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let Ok(stdout) = String::from_utf8(output.stdout) else {
            continue;
        };
        let theme = parse_theme_from_config_text(&stdout);
        if theme_has_any_color(&theme) {
            return Some(theme);
        }
    }
    None
}

pub fn load_terminal_font() -> NativeTerminalFont {
    let mut config = load_ghostty_config();
    if !font_has_any_setting(&config.font)
        && let Some(font) = load_terminal_font_from_ghostty()
    {
        config.font = font;
    }

    if config.font.families.is_empty()
        && let Some(default_family) = default_font_family()
    {
        config.font.families.push(default_family.to_string());
    }
    config.font
}

pub fn font_has_any_setting(font: &NativeTerminalFont) -> bool {
    !font.families.is_empty() || font.size.is_some()
}

pub fn load_terminal_cursor() -> NativeTerminalCursor {
    let mut config = load_ghostty_config();
    if !cursor_has_any_setting(&config.cursor)
        && let Some(cursor) = load_terminal_cursor_from_ghostty()
    {
        config.cursor = cursor;
    }
    config.cursor
}

pub fn cursor_has_any_setting(cursor: &NativeTerminalCursor) -> bool {
    cursor.style.is_some() || cursor.blink.is_some()
}

fn load_terminal_font_from_ghostty() -> Option<NativeTerminalFont> {
    for binary in ghostty_binary_paths() {
        let Ok(output) = ProcessCommand::new(&binary).arg("+show-config").output() else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let Ok(stdout) = String::from_utf8(output.stdout) else {
            continue;
        };
        let font = parse_font_from_config_text(&stdout);
        if font_has_any_setting(&font) {
            return Some(font);
        }
    }
    None
}

fn load_terminal_cursor_from_ghostty() -> Option<NativeTerminalCursor> {
    for binary in ghostty_binary_paths() {
        let Ok(output) = ProcessCommand::new(&binary).arg("+show-config").output() else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let Ok(stdout) = String::from_utf8(output.stdout) else {
            continue;
        };
        let cursor = parse_cursor_from_config_text(&stdout);
        if cursor_has_any_setting(&cursor) {
            return Some(cursor);
        }
    }
    None
}

fn ghostty_binary_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Ok(bin_dir) = env::var("GHOSTTY_BIN_DIR") {
        paths.push(PathBuf::from(bin_dir).join(ghostty_binary_name()));
    }
    paths.push(PathBuf::from(
        "/Applications/cmux.app/Contents/MacOS/ghostty",
    ));
    paths.push(PathBuf::from(
        "/Applications/Ghostty.app/Contents/MacOS/ghostty",
    ));
    if let Some(path) = find_binary_on_path(ghostty_binary_name()) {
        paths.push(path);
    }
    dedupe_paths(paths)
        .into_iter()
        .filter(|path| path.is_file())
        .collect()
}

fn ghostty_binary_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "ghostty.exe"
    } else {
        "ghostty"
    }
}

fn find_binary_on_path(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for path in paths {
        if seen.insert(path.clone()) {
            out.push(path);
        }
    }
    out
}

fn resolve_terminal_theme_from_config(
    config: &ParsedGhosttyConfig,
    dirs: &[PathBuf],
) -> Option<NativeTerminalThemeSet> {
    let mut set = NativeTerminalThemeSet::default();

    if let Some(selection) = &config.selection {
        if let Some(name) = &selection.default {
            set.default = load_theme_by_name(name, dirs);
            if set.default.is_none() {
                tracing::warn!(theme = name, "Ghostty theme was configured but not found");
            }
        }
        if let Some(name) = &selection.light {
            set.light = load_theme_by_name(name, dirs);
            if set.light.is_none() {
                tracing::warn!(
                    theme = name,
                    "Ghostty light theme was configured but not found"
                );
            }
        }
        if let Some(name) = &selection.dark {
            set.dark = load_theme_by_name(name, dirs);
            if set.dark.is_none() {
                tracing::warn!(
                    theme = name,
                    "Ghostty dark theme was configured but not found"
                );
            }
        }
    }

    if theme_has_any_color(&config.overrides) {
        if set.default.is_none() && set.light.is_none() && set.dark.is_none() {
            set.default = Some(config.overrides.clone());
        } else {
            apply_overrides_to_slot(&mut set.default, &config.overrides);
            apply_overrides_to_slot(&mut set.light, &config.overrides);
            apply_overrides_to_slot(&mut set.dark, &config.overrides);
        }
    }

    if set.default.is_none() && set.light.is_none() && set.dark.is_none() {
        None
    } else {
        Some(set)
    }
}

fn load_ghostty_config() -> ParsedGhosttyConfig {
    load_ghostty_config_from_paths(config_paths())
}

fn load_ghostty_config_from_paths(paths: Vec<PathBuf>) -> ParsedGhosttyConfig {
    let mut config = ParsedGhosttyConfig::default();
    let mut seen = HashSet::new();
    let mut includes = VecDeque::new();

    for path in paths {
        parse_config_file(&path, &mut config, &mut seen, &mut includes, 0);
    }

    while let Some((path, depth)) = includes.pop_front() {
        parse_config_file(&path, &mut config, &mut seen, &mut includes, depth);
    }

    config
}

fn config_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Ok(path) = env::var("GHOSTTY_CONFIG_FILE") {
        paths.push(expand_tilde(&path));
    }
    if let Ok(config_home) = env::var("XDG_CONFIG_HOME") {
        let config_home = PathBuf::from(config_home);
        paths.push(config_home.join("ghostty/config"));
        paths.push(config_home.join("ghostty/config.ghostty"));
    }
    if let Ok(home) = env::var("HOME") {
        let home = PathBuf::from(home);
        paths.push(home.join(".config/ghostty/config"));
        paths.push(home.join(".config/ghostty/config.ghostty"));
        paths.push(home.join("Library/Application Support/com.mitchellh.ghostty/config"));
        paths.push(home.join("Library/Application Support/com.mitchellh.ghostty/config.ghostty"));
        paths.extend(cmux_config_paths(&home));
    }
    dedupe_paths(paths)
}

fn cmux_config_paths(home: &Path) -> Vec<PathBuf> {
    let app_support = home.join("Library/Application Support");
    let mut bundle_ids = Vec::new();
    if let Ok(bundle_id) = env::var("CMUX_BUNDLE_ID") {
        bundle_ids.push(bundle_id);
    }
    if let Ok(bundle_id) = env::var("__CFBundleIdentifier") {
        bundle_ids.push(bundle_id);
    }
    bundle_ids.push("com.cmuxterm.app".to_string());

    dedupe_strings(bundle_ids)
        .into_iter()
        .flat_map(|bundle_id| {
            let dir = app_support.join(bundle_id);
            [dir.join("config"), dir.join("config.ghostty")]
        })
        .collect()
}

fn theme_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(resources) = env::var("GHOSTTY_RESOURCES_DIR") {
        dirs.push(PathBuf::from(resources).join("themes"));
    }
    if let Ok(config_home) = env::var("XDG_CONFIG_HOME") {
        dirs.push(PathBuf::from(config_home).join("ghostty/themes"));
    }
    if let Ok(xdg_data_dirs) = env::var("XDG_DATA_DIRS") {
        dirs.extend(
            env::split_paths(&xdg_data_dirs)
                .map(|dir| dir.join("ghostty/themes"))
                .collect::<Vec<_>>(),
        );
    }
    if let Ok(home) = env::var("HOME") {
        let home = PathBuf::from(home);
        dirs.push(home.join(".config/ghostty/themes"));
        dirs.push(home.join("Library/Application Support/com.mitchellh.ghostty/themes"));
        dirs.push(home.join("Library/Application Support/ghostty/themes"));
    }
    dirs.push(PathBuf::from(
        "/Applications/cmux.app/Contents/Resources/ghostty/themes",
    ));
    dirs.push(PathBuf::from(
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
    ));
    dedupe_paths(dirs)
}

fn dedupe_strings(values: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for value in values {
        if !value.is_empty() && seen.insert(value.clone()) {
            out.push(value);
        }
    }
    out
}

fn theme_selection_summary(selection: Option<&ThemeSelection>) -> String {
    let Some(selection) = selection else {
        return "-".to_string();
    };
    format!(
        "default={} light={} dark={}",
        selection.default.as_deref().unwrap_or("-"),
        selection.light.as_deref().unwrap_or("-"),
        selection.dark.as_deref().unwrap_or("-"),
    )
}

fn existing_paths_summary(paths: Vec<PathBuf>) -> String {
    let paths = paths
        .into_iter()
        .filter(|path| is_nonempty_file(path))
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>();
    if paths.is_empty() {
        "-".to_string()
    } else {
        paths.join(",")
    }
}

fn terminal_theme_set_summary(theme_set: &NativeTerminalThemeSet) -> String {
    format!(
        "default=[{}] light=[{}] dark=[{}]",
        theme_set
            .default
            .as_ref()
            .map(terminal_theme_summary)
            .unwrap_or_else(|| "-".to_string()),
        theme_set
            .light
            .as_ref()
            .map(terminal_theme_summary)
            .unwrap_or_else(|| "-".to_string()),
        theme_set
            .dark
            .as_ref()
            .map(terminal_theme_summary)
            .unwrap_or_else(|| "-".to_string()),
    )
}

fn terminal_theme_summary(theme: &NativeTerminalTheme) -> String {
    let palette = [
        0u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 81, 118, 135, 166,
    ]
    .into_iter()
    .map(|index| {
        let value = theme.palette.get(&index).map(String::as_str).unwrap_or("-");
        format!("{index}={value}")
    })
    .collect::<Vec<_>>()
    .join(",");
    format!(
        "fg={} bg={} cursor={} selection_bg={} palette={}",
        theme.foreground.as_deref().unwrap_or("-"),
        theme.background.as_deref().unwrap_or("-"),
        theme.cursor.as_deref().unwrap_or("-"),
        theme.selection_background.as_deref().unwrap_or("-"),
        palette,
    )
}

fn parse_config_file(
    path: &Path,
    config: &mut ParsedGhosttyConfig,
    seen: &mut HashSet<PathBuf>,
    includes: &mut VecDeque<(PathBuf, usize)>,
    depth: usize,
) {
    if depth > MAX_CONFIG_INCLUDE_DEPTH {
        tracing::warn!(path = %path.display(), "Ghostty config include depth exceeded");
        return;
    }
    if !is_nonempty_file(path) {
        return;
    }

    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if !seen.insert(canonical) {
        return;
    }

    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(err) => {
            tracing::warn!(
                path = %path.display(),
                error = %err,
                "failed to read Ghostty config"
            );
            return;
        }
    };

    for line in contents.lines() {
        let Some((key, value)) = parse_key_value(line) else {
            continue;
        };
        match key {
            "theme" => {
                if let Some(selection) = parse_theme_selection(value) {
                    config.selection = Some(selection);
                }
            }
            "config-file" => match parse_config_file_value(value) {
                ConfigFileValue::Include(include) => {
                    includes.push_back((resolve_config_include(path, &include), depth + 1));
                }
                ConfigFileValue::Clear => includes.clear(),
            },
            "font-family" => parse_font_family_setting(value, &mut config.font),
            "font-size" => parse_font_size_setting(value, &mut config.font),
            "cursor-style" => parse_cursor_style_setting(value, &mut config.cursor),
            "cursor-style-blink" => parse_cursor_blink_setting(value, &mut config.cursor),
            _ => parse_theme_color_setting(key, value, &mut config.overrides),
        }
    }
}

fn is_nonempty_file(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    metadata.is_file() && metadata.len() > 0
}

enum ConfigFileValue {
    Include(PathBuf),
    Clear,
}

fn parse_key_value(line: &str) -> Option<(&str, &str)> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let (key, value) = trimmed.split_once('=')?;
    Some((key.trim(), value.trim()))
}

fn parse_config_file_value(value: &str) -> ConfigFileValue {
    let was_quoted = is_quoted_config_value(value);
    let Some(mut value) = unquote_config_value(value) else {
        return ConfigFileValue::Clear;
    };
    if value.is_empty() {
        return ConfigFileValue::Clear;
    }
    if !was_quoted {
        if let Some(optional) = value.strip_prefix('?') {
            value = optional.to_string();
        }
    }
    ConfigFileValue::Include(expand_tilde(&value))
}

fn is_quoted_config_value(raw: &str) -> bool {
    let trimmed = raw.trim();
    trimmed.starts_with('"') || trimmed.starts_with('\'')
}

fn resolve_config_include(base: &Path, include: &Path) -> PathBuf {
    if include.is_absolute() {
        return include.to_path_buf();
    }
    base.parent()
        .map(|parent| parent.join(include))
        .unwrap_or_else(|| include.to_path_buf())
}

fn parse_theme_selection(value: &str) -> Option<ThemeSelection> {
    let value = unquote_config_value(value)?;
    if value.is_empty() {
        return None;
    }

    let mut selection = ThemeSelection::default();
    let mut saw_variant = false;
    for part in value.split(',') {
        let part = part.trim();
        if let Some(theme) = part.strip_prefix("light:") {
            let theme = theme.trim();
            if !theme.is_empty() {
                selection.light = Some(theme.to_string());
                saw_variant = true;
            }
        } else if let Some(theme) = part.strip_prefix("dark:") {
            let theme = theme.trim();
            if !theme.is_empty() {
                selection.dark = Some(theme.to_string());
                saw_variant = true;
            }
        }
    }

    if !saw_variant {
        selection.default = Some(value);
    }
    Some(selection)
}

fn unquote_config_value(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut chars = trimmed.chars();
    let first = chars.next()?;
    if first == '"' || first == '\'' {
        let mut escaped = false;
        let mut value = String::new();
        for ch in chars {
            if escaped {
                value.push(ch);
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == first {
                return Some(value);
            }
            value.push(ch);
        }
        return Some(value);
    }
    let without_comment = trimmed
        .split_once(" #")
        .map(|(value, _)| value)
        .unwrap_or(trimmed)
        .trim();
    Some(without_comment.to_string())
}

fn load_theme_by_name(name: &str, dirs: &[PathBuf]) -> Option<NativeTerminalTheme> {
    for path in theme_paths_for_name(name, dirs) {
        let contents = match fs::read_to_string(&path) {
            Ok(contents) => contents,
            Err(err) => {
                tracing::warn!(
                    theme = name,
                    path = %path.display(),
                    error = %err,
                    "failed to read Ghostty theme candidate"
                );
                continue;
            }
        };
        let theme = parse_theme_file(&contents);
        if theme_has_any_color(&theme) {
            return Some(theme);
        }
        tracing::warn!(theme = name, path = %path.display(), "Ghostty theme had no parsed colors");
    }
    None
}

fn theme_paths_for_name(name: &str, dirs: &[PathBuf]) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let expanded = expand_tilde(name);
    if expanded.is_file() {
        paths.push(expanded);
    }

    paths.extend(
        dirs.iter()
            .map(|dir| dir.join(name))
            .filter(|path| path.is_file()),
    );
    dedupe_paths(paths)
}

fn parse_theme_file(contents: &str) -> NativeTerminalTheme {
    parse_theme_from_config_text(contents)
}

fn parse_theme_from_config_text(contents: &str) -> NativeTerminalTheme {
    let mut theme = NativeTerminalTheme::default();
    for line in contents.lines() {
        let Some((key, value)) = parse_key_value(line) else {
            continue;
        };
        parse_theme_color_setting(key, value, &mut theme);
    }
    theme
}

fn parse_font_from_config_text(contents: &str) -> NativeTerminalFont {
    let mut font = NativeTerminalFont::default();
    for line in contents.lines() {
        let Some((key, value)) = parse_key_value(line) else {
            continue;
        };
        match key {
            "font-family" => parse_font_family_setting(value, &mut font),
            "font-size" => parse_font_size_setting(value, &mut font),
            _ => {}
        }
    }
    font
}

fn parse_cursor_from_config_text(contents: &str) -> NativeTerminalCursor {
    let mut cursor = NativeTerminalCursor::default();
    for line in contents.lines() {
        let Some((key, value)) = parse_key_value(line) else {
            continue;
        };
        match key {
            "cursor-style" => parse_cursor_style_setting(value, &mut cursor),
            "cursor-style-blink" => parse_cursor_blink_setting(value, &mut cursor),
            _ => {}
        }
    }
    cursor
}

fn parse_theme_color_setting(key: &str, value: &str, theme: &mut NativeTerminalTheme) {
    if key == "palette" {
        parse_palette_setting(value, theme);
        return;
    }

    let color = parse_color_value(value);
    match key {
        "foreground" => theme.foreground = color,
        "background" => theme.background = color,
        "cursor-color" => theme.cursor = color,
        "cursor-text" => theme.cursor_accent = color,
        "selection-background" => theme.selection_background = color,
        "selection-foreground" => theme.selection_foreground = color,
        _ => {}
    }
}

fn parse_font_family_setting(value: &str, font: &mut NativeTerminalFont) {
    let Some(family) = unquote_config_value(value) else {
        return;
    };
    let family = family.trim();
    if family.is_empty() {
        font.families.clear();
        return;
    }
    font.families.push(family.to_string());
}

fn parse_font_size_setting(value: &str, font: &mut NativeTerminalFont) {
    let Some(value) = unquote_config_value(value) else {
        return;
    };
    let Some(token) = value.split_whitespace().next() else {
        return;
    };
    if let Ok(size) = token.parse::<f64>()
        && size.is_finite()
        && size > 0.0
    {
        font.size = Some(size);
    }
}

fn parse_cursor_style_setting(value: &str, cursor: &mut NativeTerminalCursor) {
    let Some(value) = unquote_config_value(value) else {
        return;
    };
    let style = value.trim();
    if matches!(style, "block" | "bar" | "underline") {
        cursor.style = Some(style.to_string());
    }
}

fn parse_cursor_blink_setting(value: &str, cursor: &mut NativeTerminalCursor) {
    let Some(value) = unquote_config_value(value) else {
        return;
    };
    match value.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => cursor.blink = Some(true),
        "false" | "no" | "off" | "0" => cursor.blink = Some(false),
        _ => {}
    }
}

fn default_font_family() -> Option<&'static str> {
    if cfg!(target_os = "macos") {
        Some("Menlo")
    } else if cfg!(target_os = "windows") {
        Some("Consolas")
    } else {
        None
    }
}

fn parse_palette_setting(value: &str, theme: &mut NativeTerminalTheme) {
    let Some((index, color)) = value.split_once('=') else {
        return;
    };
    let Ok(index) = index.trim().parse::<u8>() else {
        return;
    };
    let color = parse_color_value(color);
    if let Some(color) = color.clone() {
        theme.palette.insert(index, color);
    }
    match index {
        0 => theme.black = color,
        1 => theme.red = color,
        2 => theme.green = color,
        3 => theme.yellow = color,
        4 => theme.blue = color,
        5 => theme.magenta = color,
        6 => theme.cyan = color,
        7 => theme.white = color,
        8 => theme.bright_black = color,
        9 => theme.bright_red = color,
        10 => theme.bright_green = color,
        11 => theme.bright_yellow = color,
        12 => theme.bright_blue = color,
        13 => theme.bright_magenta = color,
        14 => theme.bright_cyan = color,
        15 => theme.bright_white = color,
        _ => {}
    }
}

fn parse_color_value(raw: &str) -> Option<String> {
    let value = unquote_config_value(raw)?;
    let token = value.split_whitespace().next()?;
    normalize_hex_color(token)
}

fn normalize_hex_color(value: &str) -> Option<String> {
    let body = value.strip_prefix('#').unwrap_or(value);
    if body.len() != 6 || !body.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("#{}", body.to_ascii_uppercase()))
}

fn expand_tilde(path: &str) -> PathBuf {
    let Some(rest) = path.strip_prefix("~/") else {
        return PathBuf::from(path);
    };
    env::var("HOME")
        .map(|home| PathBuf::from(home).join(rest))
        .unwrap_or_else(|_| PathBuf::from(path))
}

fn apply_overrides_to_slot(
    slot: &mut Option<NativeTerminalTheme>,
    overrides: &NativeTerminalTheme,
) {
    if let Some(theme) = slot {
        apply_overrides(theme, overrides);
    }
}

fn apply_overrides(theme: &mut NativeTerminalTheme, overrides: &NativeTerminalTheme) {
    for (index, color) in &overrides.palette {
        theme.palette.insert(*index, color.clone());
    }
    override_field(&mut theme.foreground, &overrides.foreground);
    override_field(&mut theme.background, &overrides.background);
    override_field(&mut theme.cursor, &overrides.cursor);
    override_field(&mut theme.cursor_accent, &overrides.cursor_accent);
    override_field(
        &mut theme.selection_background,
        &overrides.selection_background,
    );
    override_field(
        &mut theme.selection_foreground,
        &overrides.selection_foreground,
    );
    override_field(&mut theme.black, &overrides.black);
    override_field(&mut theme.red, &overrides.red);
    override_field(&mut theme.green, &overrides.green);
    override_field(&mut theme.yellow, &overrides.yellow);
    override_field(&mut theme.blue, &overrides.blue);
    override_field(&mut theme.magenta, &overrides.magenta);
    override_field(&mut theme.cyan, &overrides.cyan);
    override_field(&mut theme.white, &overrides.white);
    override_field(&mut theme.bright_black, &overrides.bright_black);
    override_field(&mut theme.bright_red, &overrides.bright_red);
    override_field(&mut theme.bright_green, &overrides.bright_green);
    override_field(&mut theme.bright_yellow, &overrides.bright_yellow);
    override_field(&mut theme.bright_blue, &overrides.bright_blue);
    override_field(&mut theme.bright_magenta, &overrides.bright_magenta);
    override_field(&mut theme.bright_cyan, &overrides.bright_cyan);
    override_field(&mut theme.bright_white, &overrides.bright_white);
}

fn override_field(field: &mut Option<String>, override_value: &Option<String>) {
    if let Some(value) = override_value {
        *field = Some(value.clone());
    }
}

fn theme_has_any_color(theme: &NativeTerminalTheme) -> bool {
    !theme.palette.is_empty()
        || theme.foreground.is_some()
        || theme.background.is_some()
        || theme.cursor.is_some()
        || theme.cursor_accent.is_some()
        || theme.selection_background.is_some()
        || theme.selection_foreground.is_some()
        || theme.black.is_some()
        || theme.red.is_some()
        || theme.green.is_some()
        || theme.yellow.is_some()
        || theme.blue.is_some()
        || theme.magenta.is_some()
        || theme.cyan.is_some()
        || theme.white.is_some()
        || theme.bright_black.is_some()
        || theme.bright_red.is_some()
        || theme.bright_green.is_some()
        || theme.bright_yellow.is_some()
        || theme.bright_blue.is_some()
        || theme.bright_magenta.is_some()
        || theme.bright_cyan.is_some()
        || theme.bright_white.is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn parses_light_dark_theme_selection() {
        let selection =
            parse_theme_selection("\"light:iTerm2 Solarized Light,dark:Monokai Classic\"");
        let selection = selection.unwrap();
        assert_eq!(selection.default, None);
        assert_eq!(selection.light.as_deref(), Some("iTerm2 Solarized Light"));
        assert_eq!(selection.dark.as_deref(), Some("Monokai Classic"));
    }

    #[test]
    fn parses_ghostty_theme_palette() {
        let theme = parse_theme_file(
            r#"
palette = 0=#272822
palette = 1=#f92672
palette = 10=#a6e22e
palette = 135=#af5fff
background = #272822
foreground = #fdfff1
cursor-color = #c0c1b5
cursor-text = #8d8e82
selection-background = #57584f
selection-foreground = #fdfff1
"#,
        );

        assert_eq!(theme.black.as_deref(), Some("#272822"));
        assert_eq!(theme.red.as_deref(), Some("#F92672"));
        assert_eq!(theme.bright_green.as_deref(), Some("#A6E22E"));
        assert_eq!(theme.palette.get(&0).map(String::as_str), Some("#272822"));
        assert_eq!(theme.palette.get(&10).map(String::as_str), Some("#A6E22E"));
        assert_eq!(theme.palette.get(&135).map(String::as_str), Some("#AF5FFF"));
        assert_eq!(theme.background.as_deref(), Some("#272822"));
        assert_eq!(theme.foreground.as_deref(), Some("#FDFFF1"));
        assert_eq!(theme.cursor.as_deref(), Some("#C0C1B5"));
        assert_eq!(theme.cursor_accent.as_deref(), Some("#8D8E82"));
        assert_eq!(theme.selection_background.as_deref(), Some("#57584F"));
        assert_eq!(theme.selection_foreground.as_deref(), Some("#FDFFF1"));
    }

    #[test]
    fn resolves_configured_light_dark_themes() {
        let dir = tempdir().unwrap();
        let light = dir.path().join("Light Theme");
        let dark = dir.path().join("Dark Theme");
        fs::write(&light, "background = #ffffff\nforeground = #000000\n").unwrap();
        fs::write(&dark, "background = #101010\nforeground = #eeeeee\n").unwrap();

        let config = ParsedGhosttyConfig {
            selection: parse_theme_selection("\"light:Light Theme,dark:Dark Theme\""),
            overrides: NativeTerminalTheme::default(),
            font: NativeTerminalFont::default(),
            cursor: NativeTerminalCursor::default(),
        };

        let set = resolve_terminal_theme_from_config(&config, &[dir.path().to_path_buf()]);
        let set = set.unwrap();
        assert_eq!(
            set.light.and_then(|theme| theme.background).as_deref(),
            Some("#FFFFFF")
        );
        assert_eq!(
            set.dark.and_then(|theme| theme.background).as_deref(),
            Some("#101010")
        );
    }

    #[test]
    fn configured_theme_wins_over_ghostty_show_config_theme() {
        let config_theme = NativeTerminalThemeSet {
            default: Some(NativeTerminalTheme {
                background: Some("#272822".into()),
                foreground: Some("#FDFFF1".into()),
                ..NativeTerminalTheme::default()
            }),
            ..NativeTerminalThemeSet::default()
        };
        let show_config_theme = NativeTerminalTheme {
            background: Some("#FDF6E3".into()),
            foreground: Some("#657B83".into()),
            ..NativeTerminalTheme::default()
        };

        let selected = choose_resolved_ghostty_theme(Some(config_theme), Some(show_config_theme))
            .expect("selected theme");

        assert_eq!(
            selected
                .default
                .and_then(|theme| theme.background)
                .as_deref(),
            Some("#272822")
        );
    }

    #[test]
    fn parses_repeated_font_families_and_size() {
        let mut config = ParsedGhosttyConfig::default();
        let mut seen = HashSet::new();
        let dir = tempdir().unwrap();
        let path = dir.path().join("config");
        fs::write(
            &path,
            r#"
font-family = ""
font-family = "JetBrains Mono"
font-family = "Symbols Nerd Font"
font-size = 12.5
"#,
        )
        .unwrap();

        let mut includes = VecDeque::new();
        parse_config_file(&path, &mut config, &mut seen, &mut includes, 0);

        assert_eq!(
            config.font.families,
            vec![
                "JetBrains Mono".to_string(),
                "Symbols Nerd Font".to_string()
            ]
        );
        assert_eq!(config.font.size, Some(12.5));
    }

    #[test]
    fn loads_all_default_configs_then_cmux_overlay_then_recursive_files() {
        let dir = tempdir().unwrap();
        let xdg_config = dir.path().join("xdg-config");
        let app_config = dir.path().join("app-config.ghostty");
        let cmux_config = dir.path().join("cmux-config.ghostty");
        let recursive = dir.path().join("recursive.ghostty");

        fs::write(
            &xdg_config,
            format!(
                r#"
theme = light:Solarized Light,dark:Monokai Classic
font-size = 12
config-file = {}
"#,
                recursive.display()
            ),
        )
        .unwrap();
        fs::write(
            &app_config,
            r#"
font-size = 13
cursor-style = bar
"#,
        )
        .unwrap();
        fs::write(
            &cmux_config,
            r#"
theme = light:Cmux Dark,dark:Cmux Dark
foreground = #123456
"#,
        )
        .unwrap();
        fs::write(&recursive, "font-size = 14\ncursor-style-blink = false\n").unwrap();

        let config = load_ghostty_config_from_paths(vec![xdg_config, app_config, cmux_config]);

        let selection = config.selection.unwrap();
        assert_eq!(selection.light.as_deref(), Some("Cmux Dark"));
        assert_eq!(selection.dark.as_deref(), Some("Cmux Dark"));
        assert_eq!(config.overrides.foreground.as_deref(), Some("#123456"));
        assert_eq!(config.font.size, Some(14.0));
        assert_eq!(config.cursor.style.as_deref(), Some("bar"));
        assert_eq!(config.cursor.blink, Some(false));
    }

    #[test]
    fn config_file_include_depth_is_enforced_across_queue() {
        let dir = tempdir().unwrap();
        let root = dir.path().join("config-0");
        for depth in 0..=(MAX_CONFIG_INCLUDE_DEPTH + 1) {
            let current = dir.path().join(format!("config-{depth}"));
            let next = dir.path().join(format!("config-{}", depth + 1));
            fs::write(&current, format!("config-file = {}\n", next.display())).unwrap();
        }
        fs::write(
            dir.path()
                .join(format!("config-{}", MAX_CONFIG_INCLUDE_DEPTH + 2)),
            "font-size = 99\n",
        )
        .unwrap();

        let config = load_ghostty_config_from_paths(vec![root]);

        assert_eq!(config.font.size, None);
    }

    #[test]
    fn quoted_optional_config_file_prefix_is_literal() {
        let value = parse_config_file_value("\"?literal.ghostty\"");

        match value {
            ConfigFileValue::Include(path) => assert_eq!(path, PathBuf::from("?literal.ghostty")),
            ConfigFileValue::Clear => panic!("quoted config-file should remain a literal include"),
        }
    }

    #[test]
    fn theme_loading_continues_after_unreadable_candidate() {
        let bad_dir = tempdir().unwrap();
        let good_dir = tempdir().unwrap();
        fs::write(bad_dir.path().join("Shared"), [0xFF]).unwrap();
        fs::write(good_dir.path().join("Shared"), "background = #101010\n").unwrap();

        let theme = load_theme_by_name(
            "Shared",
            &[bad_dir.path().to_path_buf(), good_dir.path().to_path_buf()],
        )
        .unwrap();

        assert_eq!(theme.background.as_deref(), Some("#101010"));
    }

    #[test]
    fn parses_resolved_show_config_font_output() {
        let font = parse_font_from_config_text(
            r#"
font-family = Menlo
font-family-bold = Menlo
font-family-italic = Menlo
font-size = 12
"#,
        );

        assert_eq!(font.families, vec!["Menlo".to_string()]);
        assert_eq!(font.size, Some(12.0));
    }

    #[test]
    fn parses_resolved_show_config_theme_output() {
        let theme = parse_theme_from_config_text(
            r#"
theme = light:iTerm2 Solarized Light,dark:Monokai Classic
background = #fdf6e3
foreground = #657b83
selection-foreground = #586e75
selection-background = #eee8d5
palette = 0=#073642
palette = 5=#d33682
palette = 135=#af5fff
cursor-color = #657b83
cursor-text = #eee8d5
"#,
        );

        assert_eq!(theme.background.as_deref(), Some("#FDF6E3"));
        assert_eq!(theme.foreground.as_deref(), Some("#657B83"));
        assert_eq!(theme.selection_foreground.as_deref(), Some("#586E75"));
        assert_eq!(theme.selection_background.as_deref(), Some("#EEE8D5"));
        assert_eq!(theme.palette.get(&0).map(String::as_str), Some("#073642"));
        assert_eq!(theme.palette.get(&5).map(String::as_str), Some("#D33682"));
        assert_eq!(theme.palette.get(&135).map(String::as_str), Some("#AF5FFF"));
        assert_eq!(theme.cursor.as_deref(), Some("#657B83"));
        assert_eq!(theme.cursor_accent.as_deref(), Some("#EEE8D5"));
    }

    #[test]
    fn parses_resolved_show_config_cursor_output() {
        let cursor = parse_cursor_from_config_text(
            r#"
cursor-style = bar
cursor-style-blink = false
"#,
        );

        assert_eq!(cursor.style.as_deref(), Some("bar"));
        assert_eq!(cursor.blink, Some(false));
    }

    #[test]
    fn parses_installed_ghostty_theme_files_when_available() {
        let dir = Path::new("/Applications/Ghostty.app/Contents/Resources/ghostty/themes");
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };

        let mut parsed = 0usize;
        for entry in entries {
            let entry = entry.unwrap();
            if !entry.file_type().unwrap().is_file() {
                continue;
            }
            let contents = fs::read_to_string(entry.path()).unwrap();
            let theme = parse_theme_file(&contents);
            assert!(theme_has_any_color(&theme), "{}", entry.path().display());
            parsed += 1;
        }
        assert!(parsed > 100);
    }
}
