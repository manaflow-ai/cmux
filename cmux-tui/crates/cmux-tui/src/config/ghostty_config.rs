//! Ghostty application defaults: parses the user's Ghostty config files, includes and themes into terminal colors, cursor and scrollback defaults.

use super::*;

pub(super) struct GhosttyApplicationDefaults {
    pub(super) colors: DefaultColors,
    pub(super) scrollback_limit_bytes: Option<usize>,
}

impl Default for GhosttyApplicationDefaults {
    fn default() -> Self {
        Self {
            colors: resolve_ghostty_application_defaults(DefaultColors::default()),
            scrollback_limit_bytes: None,
        }
    }
}

pub(super) fn ghostty_application_defaults() -> GhosttyApplicationDefaults {
    let config_paths = platform::ghostty_config_paths();
    let theme_dirs = platform::ghostty_theme_dirs();
    #[cfg(not(test))]
    let helper_defaults = ghostty_defaults_from_helper();
    #[cfg(test)]
    let helper_defaults = GhosttyHelperDefaults::Unavailable;
    match helper_defaults {
        GhosttyHelperDefaults::Resolved(defaults) => *defaults,
        GhosttyHelperDefaults::Unavailable => {
            parse_ghostty_application_defaults_from_paths(config_paths, theme_dirs)
                .unwrap_or_default()
        }
        GhosttyHelperDefaults::TimedOut => GhosttyApplicationDefaults::default(),
    }
}

pub(super) enum GhosttyHelperDefaults {
    Resolved(Box<GhosttyApplicationDefaults>),
    Unavailable,
    TimedOut,
}

#[cfg(test)]
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ScrollbackConfigOutcome {
    Missing,
    Parsed(Option<Option<usize>>),
    TimedOut,
}

#[cfg(test)]
pub(super) fn parse_scrollback_limit_from_root(
    path: &Path,
    deadline_at: Instant,
) -> ScrollbackConfigOutcome {
    // Ghostty parses the complete parent file first, then loads its
    // config-file entries in declaration order. Nested entries are appended
    // after the already queued siblings. A FIFO queue preserves that
    // precedence while keeping the traversal bounded below.
    let mut queue = VecDeque::from([PendingGhosttyConfig { path: path.to_path_buf(), depth: 0 }]);
    let mut loaded = HashSet::new();
    let mut files_loaded = 0usize;
    let mut bytes_loaded = 0u64;
    let mut value = None;
    let mut loaded_root = false;

    while let Some(pending) = queue.pop_front() {
        if Instant::now() >= deadline_at {
            return ScrollbackConfigOutcome::TimedOut;
        }
        if pending.depth > GHOSTTY_CONFIG_MAX_DEPTH || files_loaded >= GHOSTTY_CONFIG_MAX_FILES {
            return ScrollbackConfigOutcome::TimedOut;
        }
        let identity = pending.path.canonicalize().unwrap_or_else(|_| pending.path.clone());
        if !loaded.insert(identity.clone()) {
            continue;
        }
        let remaining_bytes = GHOSTTY_CONFIG_MAX_BYTES.saturating_sub(bytes_loaded);
        if ghostty_regular_file_exceeds_limit(&pending.path, remaining_bytes) {
            return ScrollbackConfigOutcome::TimedOut;
        }
        let Some(text) = read_ghostty_regular_file(&pending.path, remaining_bytes) else {
            if pending.depth == 0 && files_loaded == 0 {
                return ScrollbackConfigOutcome::Missing;
            }
            continue;
        };
        bytes_loaded = bytes_loaded.saturating_add(text.len() as u64);
        files_loaded += 1;
        loaded_root |= pending.depth == 0;
        if let Some(parsed) = parse_scrollback_limit_bytes(&text) {
            value = Some(parsed);
        }

        let base_dir = pending.path.parent().unwrap_or_else(|| Path::new("."));
        let mut theme_candidates = Vec::new();
        let parsed = parse_ghostty_config_text(&text, Some(base_dir), &mut theme_candidates);
        for include in
            parsed.config_files.into_iter().filter_map(|include| include.resolve(base_dir))
        {
            queue.push_back(PendingGhosttyConfig { path: include, depth: pending.depth + 1 });
        }
        if Instant::now() >= deadline_at {
            return ScrollbackConfigOutcome::TimedOut;
        }
    }

    if loaded_root {
        ScrollbackConfigOutcome::Parsed(value)
    } else {
        ScrollbackConfigOutcome::Missing
    }
}

/// Return the last scrollback setting in a file. The outer `Option` says
/// whether a setting was present; the inner `Option` represents an explicit
/// empty reset to the shared default.
pub(super) fn parse_scrollback_limit_bytes(text: &str) -> Option<Option<usize>> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.trim().split_once('=')?;
            if !matches!(key.trim(), "scrollback-limit" | "scrollback-limit-bytes") {
                return None;
            }
            // Ghostty treats comments as whole lines. Do not truncate a
            // numeric value at '#', because that would accept malformed input
            // that Ghostty rejects.
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .unwrap_or(value)
                .trim();
            if value.is_empty() {
                return Some(None);
            }
            value.replace('_', "").parse::<usize>().ok().map(Some)
        })
        .next_back()
}

pub(super) fn resolve_ghostty_application_defaults(mut defaults: DefaultColors) -> DefaultColors {
    defaults.cursor_style.get_or_insert(CursorShape::Block);
    // `cursor-style-blink = null` is semantically different from `true` in
    // Ghostty: both start blinking, but only the unset form lets DEC mode 12
    // control the live cursor. Keep that absence intact for the terminal
    // application boundary to resolve without losing its provenance.
    defaults
}

pub(super) fn parse_ghostty_application_defaults_from_paths(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
) -> Option<GhosttyApplicationDefaults> {
    match parse_ghostty_application_defaults_from_paths_result(config_paths, theme_dirs) {
        GhosttyApplicationDefaultsParseOutcome::Parsed(defaults) => Some(defaults),
        GhosttyApplicationDefaultsParseOutcome::Partial(defaults) => Some(defaults),
        GhosttyApplicationDefaultsParseOutcome::Missing
        | GhosttyApplicationDefaultsParseOutcome::TimedOut => None,
    }
}

pub(super) enum GhosttyApplicationDefaultsParseOutcome {
    Parsed(GhosttyApplicationDefaults),
    Partial(GhosttyApplicationDefaults),
    Missing,
    TimedOut,
}

pub(super) fn parse_ghostty_application_defaults_from_paths_result(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
) -> GhosttyApplicationDefaultsParseOutcome {
    let deadline_at = ghostty_config_deadline_from_now(GHOSTTY_CONFIG_PARSE_DEADLINE);
    let mut resolved = None;
    let mut scrollback_limit_bytes = None;
    let mut incomplete = false;
    for path in config_paths {
        if ghostty_config_deadline_expired(Some(deadline_at)) {
            return GhosttyApplicationDefaultsParseOutcome::TimedOut;
        }
        let mut path_scrollback = None;
        match parse_ghostty_defaults_from_path_result_until_with_scrollback(
            &path,
            &theme_dirs,
            Some(deadline_at),
            Some(&mut path_scrollback),
        ) {
            GhosttyConfigParseOutcome::Missing => {}
            GhosttyConfigParseOutcome::TimedOut => {
                return GhosttyApplicationDefaultsParseOutcome::TimedOut;
            }
            GhosttyConfigParseOutcome::Parsed(defaults) => {
                let merged = resolved.get_or_insert_with(DefaultColors::default);
                overlay_ghostty_defaults(merged, *defaults);
                if let Some(value) = path_scrollback {
                    scrollback_limit_bytes = value;
                }
            }
            GhosttyConfigParseOutcome::Partial(defaults) => {
                let merged = resolved.get_or_insert_with(DefaultColors::default);
                overlay_ghostty_defaults(merged, *defaults);
                incomplete = true;
            }
        }
    }
    match resolved {
        Some(colors) => {
            let defaults = GhosttyApplicationDefaults {
                colors: resolve_ghostty_application_defaults(colors),
                scrollback_limit_bytes: if incomplete { None } else { scrollback_limit_bytes },
            };
            if incomplete {
                GhosttyApplicationDefaultsParseOutcome::Partial(defaults)
            } else {
                GhosttyApplicationDefaultsParseOutcome::Parsed(defaults)
            }
        }
        None => GhosttyApplicationDefaultsParseOutcome::Missing,
    }
}

pub(super) enum GhosttyConfigParseOutcome {
    Parsed(Box<DefaultColors>),
    Partial(Box<DefaultColors>),
    Missing,
    TimedOut,
}

pub(super) fn parse_ghostty_defaults_from_path_result_until_with_scrollback(
    path: &Path,
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
    scrollback_limit_bytes: Option<&mut Option<Option<usize>>>,
) -> GhosttyConfigParseOutcome {
    let mut theme_candidates = Vec::new();
    let overrides = match parse_ghostty_config_file_until_with_scrollback(
        path,
        &mut theme_candidates,
        deadline_at,
        scrollback_limit_bytes,
    ) {
        GhosttyConfigParseOutcome::Parsed(overrides) => *overrides,
        outcome => return outcome,
    };
    GhosttyConfigParseOutcome::Parsed(Box::new(resolve_parsed_ghostty_defaults(
        theme_candidates,
        theme_dirs,
        overrides,
        deadline_at,
    )))
}

pub(super) const GHOSTTY_CONFIG_MAX_FILES: usize = 64;

pub(super) const GHOSTTY_CONFIG_MAX_DEPTH: usize = 16;

pub(super) const GHOSTTY_CONFIG_MAX_BYTES: u64 = 1024 * 1024;

pub(super) const GHOSTTY_HELPER_OUTPUT_MAX_BYTES: u64 = 64 * 1024;

#[cfg(unix)]
pub(super) const GHOSTTY_PROCESS_SCAN_OUTPUT_MAX_BYTES: u64 = 1024 * 1024;

pub(super) const GHOSTTY_CONFIG_PARSE_DEADLINE: Duration = Duration::from_millis(250);

#[cfg(unix)]
pub(super) const GHOSTTY_PROCESS_SCAN_DEADLINE: Duration = Duration::from_millis(150);

#[cfg(not(target_os = "macos"))]
pub(super) const GHOSTTY_HELPER_REAP_DEADLINE: Duration = Duration::from_millis(150);

// The child owns a 250 ms parse deadline. The parent starts timing before
// spawn/exec and still needs room for setup, stdout drain, and normal exit.
pub(super) const GHOSTTY_CONFIG_HELPER_PARENT_DEADLINE: Duration = Duration::from_millis(500);

#[cfg(not(target_os = "macos"))]
pub(super) const GHOSTTY_DESKTOP_APPEARANCE_DEADLINE: Duration = Duration::from_millis(75);

pub(super) struct PendingGhosttyConfig {
    path: PathBuf,
    depth: usize,
}

pub(super) fn parse_ghostty_config_file_until_with_scrollback(
    path: &Path,
    theme_candidates: &mut Vec<GhosttyThemeCandidate>,
    deadline_at: Option<Instant>,
    scrollback_limit_bytes: Option<&mut Option<Option<usize>>>,
) -> GhosttyConfigParseOutcome {
    let mut stack = vec![PendingGhosttyConfig { path: path.to_path_buf(), depth: 0 }];
    let mut loaded = HashSet::new();
    let mut snapshot = Vec::new();
    let mut files_loaded = 0usize;
    let mut bytes_loaded = 0u64;
    let mut loaded_root = false;
    let mut overrides = DefaultColors::default();
    let collect_scrollback = scrollback_limit_bytes.is_some();
    let root_identity = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());

    // Preserve cmux's existing depth-first precedence for colors and themes.
    // Scrollback is replayed from this snapshot in Ghostty's declaration-order
    // breadth-first traversal, so changing color precedence is out of scope.

    while let Some(pending) = stack.pop() {
        if files_loaded > 0 && ghostty_config_deadline_expired(deadline_at) {
            return if collect_scrollback {
                GhosttyConfigParseOutcome::Partial(Box::new(overrides))
            } else {
                GhosttyConfigParseOutcome::TimedOut
            };
        }
        if pending.depth > GHOSTTY_CONFIG_MAX_DEPTH || files_loaded >= GHOSTTY_CONFIG_MAX_FILES {
            if collect_scrollback {
                return GhosttyConfigParseOutcome::Partial(Box::new(overrides));
            }
            continue;
        }
        let identity = pending.path.canonicalize().unwrap_or_else(|_| pending.path.clone());
        if !loaded.insert(identity.clone()) {
            continue;
        }
        let remaining_bytes = GHOSTTY_CONFIG_MAX_BYTES.saturating_sub(bytes_loaded);
        if collect_scrollback && ghostty_regular_file_exceeds_limit(&pending.path, remaining_bytes)
        {
            return GhosttyConfigParseOutcome::Partial(Box::new(overrides));
        }
        let text = match read_ghostty_regular_file(&pending.path, remaining_bytes) {
            Some(text) => text,
            None if pending.depth == 0 && files_loaded == 0 => {
                return GhosttyConfigParseOutcome::Missing;
            }
            None => continue,
        };
        bytes_loaded = bytes_loaded.saturating_add(text.len() as u64);
        files_loaded += 1;
        loaded_root |= pending.depth == 0;
        let base_dir = pending.path.parent().unwrap_or_else(|| Path::new("."));
        let parsed = parse_ghostty_config_text(&text, Some(base_dir), theme_candidates);
        overlay_ghostty_defaults(&mut overrides, parsed.overrides);

        let includes: Vec<PathBuf> = parsed
            .config_files
            .into_iter()
            .filter_map(|include| include.resolve(base_dir))
            .collect();
        if collect_scrollback {
            snapshot.push((identity, includes.clone(), parse_scrollback_limit_bytes(&text)));
        }
        for include in includes.into_iter().rev() {
            stack.push(PendingGhosttyConfig { path: include, depth: pending.depth + 1 });
        }
        if ghostty_config_deadline_expired(deadline_at) {
            return if collect_scrollback {
                GhosttyConfigParseOutcome::Partial(Box::new(overrides))
            } else {
                GhosttyConfigParseOutcome::TimedOut
            };
        }
    }

    if loaded_root {
        if let Some(scrollback_limit_bytes) = scrollback_limit_bytes {
            let mut snapshot_by_identity = HashMap::new();
            for (index, (identity, _, _)) in snapshot.iter().enumerate() {
                snapshot_by_identity.insert(identity, index);
            }
            let mut queue = VecDeque::from([(root_identity, 0usize)]);
            let mut seen = HashSet::new();
            let mut resolved = None;
            while let Some((identity, depth)) = queue.pop_front() {
                if depth > GHOSTTY_CONFIG_MAX_DEPTH || !seen.insert(identity.clone()) {
                    continue;
                }
                let Some(&index) = snapshot_by_identity.get(&identity) else {
                    continue;
                };
                let (_, includes, value) = &snapshot[index];
                if let Some(value) = value {
                    resolved = Some(*value);
                }
                for include in includes {
                    let identity = include.canonicalize().unwrap_or_else(|_| include.clone());
                    queue.push_back((identity, depth + 1));
                }
            }
            *scrollback_limit_bytes = resolved;
        }
        GhosttyConfigParseOutcome::Parsed(Box::new(overrides))
    } else {
        GhosttyConfigParseOutcome::Missing
    }
}

pub(super) fn ghostty_config_deadline_from_now(deadline: Duration) -> Instant {
    Instant::now().checked_add(deadline).unwrap_or_else(Instant::now)
}

pub(super) fn ghostty_config_deadline_expired(deadline_at: Option<Instant>) -> bool {
    deadline_at.is_some_and(|deadline_at| Instant::now() >= deadline_at)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn ghostty_config_deadline_remaining(deadline_at: Option<Instant>) -> Option<Duration> {
    deadline_at.map_or(Some(Duration::MAX), |deadline_at| Some(ghostty_duration_until(deadline_at)))
}

#[cfg(not(target_os = "macos"))]
pub(super) fn ghostty_duration_until(deadline_at: Instant) -> Duration {
    deadline_at.checked_duration_since(Instant::now()).unwrap_or(Duration::ZERO)
}

#[cfg(all(unix, not(target_os = "macos")))]
pub(super) fn kill_ghostty_process_group(group: libc::pid_t) {
    if group <= 0 {
        return;
    }
    unsafe {
        // SAFETY: callers pass process-group IDs that were either created by
        // cmux-tui for short-lived helpers or discovered under those helpers.
        libc::killpg(group, libc::SIGKILL);
    }
}

pub(super) struct ParsedGhosttyConfig {
    overrides: DefaultColors,
    config_files: Vec<GhosttyConfigFile>,
}

pub(super) struct GhosttyThemeCandidate {
    pub(super) value: String,
    pub(super) base_dir: Option<PathBuf>,
}

pub(super) struct GhosttyConfigFile {
    path: String,
}

impl GhosttyConfigFile {
    fn parse(value: &str) -> Option<Self> {
        let value = value.trim();
        let value = value.strip_prefix('?').unwrap_or(value);
        let value =
            value.strip_prefix('"').and_then(|value| value.strip_suffix('"')).unwrap_or(value);
        if value.is_empty() { None } else { Some(Self { path: value.to_owned() }) }
    }

    fn resolve(self, base_dir: &Path) -> Option<PathBuf> {
        if let Some(path) = expand_home_relative_path(&self.path) {
            return Some(path);
        }
        let path = Path::new(&self.path);
        if path.is_absolute() { Some(path.to_path_buf()) } else { Some(base_dir.join(path)) }
    }
}

pub(super) fn parse_ghostty_config_text(
    text: &str,
    base_dir: Option<&Path>,
    theme_candidates: &mut Vec<GhosttyThemeCandidate>,
) -> ParsedGhosttyConfig {
    let mut overrides = DefaultColors::default();
    let mut config_files = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        match key.trim() {
            "theme" => {
                theme_candidates.push(GhosttyThemeCandidate {
                    value: value.trim().to_owned(),
                    base_dir: base_dir.map(Path::to_path_buf),
                });
            }
            "window-theme" => {}
            "config-file" => {
                if let Some(include) = GhosttyConfigFile::parse(value) {
                    config_files.push(include);
                }
            }
            key => apply_ghostty_default(&mut overrides, key, value.trim()),
        }
    }

    ParsedGhosttyConfig { overrides, config_files }
}

pub(super) fn resolve_ghostty_theme_defaults(
    theme_candidates: &[GhosttyThemeCandidate],
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
) -> DefaultColors {
    if theme_candidates.is_empty() {
        return DefaultColors::default();
    }
    if ghostty_config_deadline_expired(deadline_at) {
        return DefaultColors::default();
    }
    let mut theme_mode = None;
    for candidate in theme_candidates {
        if ghostty_config_deadline_expired(deadline_at) {
            return DefaultColors::default();
        }
        if let Some(defaults) =
            load_ghostty_theme(candidate, theme_dirs, deadline_at, &mut theme_mode)
        {
            return defaults;
        }
    }
    DefaultColors::default()
}

pub(super) fn resolve_parsed_ghostty_defaults(
    theme_candidates: Vec<GhosttyThemeCandidate>,
    theme_dirs: &[PathBuf],
    overrides: DefaultColors,
    deadline_at: Option<Instant>,
) -> DefaultColors {
    let mut defaults = resolve_ghostty_theme_defaults(&theme_candidates, theme_dirs, deadline_at);
    overlay_ghostty_defaults(&mut defaults, overrides);
    defaults
}

/// Parse the fully resolved `ghostty +show-config` output. Theme lines are
/// intentionally ignored because the output already contains their resolved
/// color and cursor settings.
pub(super) fn parse_resolved_ghostty_defaults(text: &str) -> DefaultColors {
    let mut defaults = DefaultColors::default();
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        apply_ghostty_default(&mut defaults, key.trim(), value.trim());
    }
    defaults
}

pub(super) fn serialize_ghostty_defaults(defaults: DefaultColors) -> String {
    let mut out = String::new();
    if let Some(color) = defaults.fg {
        out.push_str(&format!("foreground = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.bg {
        out.push_str(&format!("background = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.cursor {
        out.push_str(&format!("cursor-color = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.selection_bg {
        out.push_str(&format!("selection-background = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.selection_fg {
        out.push_str(&format!("selection-foreground = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(style) = defaults.cursor_style {
        let style = match style {
            CursorShape::Block => Some("block"),
            CursorShape::Underline => Some("underline"),
            CursorShape::Bar => Some("bar"),
            CursorShape::BlockHollow => Some("block_hollow"),
        };
        if let Some(style) = style {
            out.push_str(&format!("cursor-style = {style}\n"));
        }
    }
    if let Some(blink) = defaults.cursor_blink {
        out.push_str(&format!("cursor-style-blink = {blink}\n"));
    }
    for (index, color) in defaults.palette.into_iter().enumerate() {
        if let Some(color) = color {
            out.push_str(&format!("palette = {index}={}\n", format_ghostty_rgb(color)));
        }
    }
    out
}

pub(super) fn serialize_ghostty_application_defaults(
    defaults: &GhosttyApplicationDefaults,
) -> String {
    let mut out = serialize_ghostty_defaults(defaults.colors);
    if let Some(limit) = defaults.scrollback_limit_bytes {
        out.push_str(&format!("scrollback-limit-bytes = {limit}\n"));
    }
    out
}

pub(super) fn format_ghostty_rgb(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

pub(super) fn apply_ghostty_default(defaults: &mut DefaultColors, key: &str, value: &str) {
    let value = value.strip_prefix('"').and_then(|value| value.strip_suffix('"')).unwrap_or(value);
    match key {
        "foreground" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.fg = Some(color);
            }
        }
        "background" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.bg = Some(color);
            }
        }
        "cursor-color" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.cursor = Some(color);
            }
        }
        "selection-background" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.selection_bg = Some(color);
            }
        }
        "selection-foreground" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.selection_fg = Some(color);
            }
        }
        "cursor-style" => {
            let style = match value {
                "block" => Some(CursorShape::Block),
                "underline" => Some(CursorShape::Underline),
                "bar" => Some(CursorShape::Bar),
                "block_hollow" => Some(CursorShape::BlockHollow),
                _ => None,
            };
            if style.is_some() {
                defaults.cursor_style = style;
            }
        }
        "cursor-style-blink" => {
            if let Ok(blink) = value.parse::<bool>() {
                defaults.cursor_blink = Some(blink);
            }
        }
        "palette" => {
            if let Some((index, color)) = ghostty_vt::parse_palette_entry(value) {
                defaults.palette[index as usize] = Some(color);
            }
        }
        _ => {}
    }
}

pub(super) fn load_ghostty_theme(
    candidate: &GhosttyThemeCandidate,
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
    theme_mode: &mut Option<GhosttyThemeMode>,
) -> Option<DefaultColors> {
    if ghostty_config_deadline_expired(deadline_at) {
        return None;
    }
    let value = candidate.value.trim_matches('"');
    let theme = selected_ghostty_theme(value, deadline_at, theme_mode);
    if ghostty_config_deadline_expired(deadline_at) {
        return None;
    }
    let path = resolve_ghostty_theme_path(theme, candidate.base_dir.as_deref(), theme_dirs)?;
    let text = read_ghostty_regular_file(&path, GHOSTTY_CONFIG_MAX_BYTES)?;
    Some(parse_resolved_ghostty_defaults(&text))
}

pub(super) fn read_ghostty_regular_file(path: &Path, max_bytes: u64) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file() || metadata.len() > max_bytes {
        return None;
    }
    read_ghostty_limited_string(file, max_bytes)
}

pub(super) fn ghostty_regular_file_exceeds_limit(path: &Path, max_bytes: u64) -> bool {
    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_file() && metadata.len() > max_bytes)
}

pub(super) fn read_ghostty_limited_string(reader: impl Read, max_bytes: u64) -> Option<String> {
    let mut text = String::new();
    reader.take(max_bytes.saturating_add(1)).read_to_string(&mut text).ok()?;
    if text.len() as u64 > max_bytes {
        return None;
    }
    Some(text)
}

pub(super) fn resolve_ghostty_theme_path(
    theme: &str,
    base_dir: Option<&Path>,
    theme_dirs: &[PathBuf],
) -> Option<PathBuf> {
    if let Some(path) = expand_home_relative_path(theme) {
        return Some(path);
    }
    let path = Path::new(theme);
    if path.is_absolute() {
        return Some(path.to_path_buf());
    }
    if path.file_name().is_some_and(|name| name == theme) {
        return theme_dirs.iter().map(|dir| dir.join(theme)).find(|path| path.is_file());
    }
    base_dir.map(|base_dir| base_dir.join(path))
}

pub(super) fn expand_home_relative_path(value: &str) -> Option<PathBuf> {
    let home = platform::home_dir()?;
    match value {
        "~" => Some(home),
        value => value.strip_prefix("~/").map(|rest| home.join(rest)),
    }
}

pub(super) fn selected_ghostty_theme<'a>(
    value: &'a str,
    deadline_at: Option<Instant>,
    theme_mode: &mut Option<GhosttyThemeMode>,
) -> &'a str {
    let Some((light, dark)) = conditional_ghostty_themes(value) else {
        return value;
    };
    let mode = *theme_mode.get_or_insert_with(|| system_ghostty_theme_mode(deadline_at));
    match mode {
        GhosttyThemeMode::Light => light,
        GhosttyThemeMode::Dark => dark,
    }
}

pub(super) fn conditional_ghostty_themes(value: &str) -> Option<(&str, &str)> {
    let mut light = None;
    let mut dark = None;
    for part in value.split(',') {
        let (key, theme) = part.split_once(':').or_else(|| part.split_once('='))?;
        let theme = theme.trim();
        match key.trim() {
            "light" if !theme.is_empty() => light = Some(theme),
            "dark" if !theme.is_empty() => dark = Some(theme),
            _ => return None,
        }
    }
    Some((light?, dark?))
}

pub(super) fn overlay_ghostty_defaults(defaults: &mut DefaultColors, overrides: DefaultColors) {
    if overrides.fg.is_some() {
        defaults.fg = overrides.fg;
    }
    if overrides.bg.is_some() {
        defaults.bg = overrides.bg;
    }
    if overrides.cursor.is_some() {
        defaults.cursor = overrides.cursor;
    }
    if overrides.selection_bg.is_some() {
        defaults.selection_bg = overrides.selection_bg;
    }
    if overrides.selection_fg.is_some() {
        defaults.selection_fg = overrides.selection_fg;
    }
    if overrides.cursor_style.is_some() {
        defaults.cursor_style = overrides.cursor_style;
    }
    if overrides.cursor_blink.is_some() {
        defaults.cursor_blink = overrides.cursor_blink;
    }
    for (default, override_) in defaults.palette.iter_mut().zip(overrides.palette) {
        if override_.is_some() {
            *default = override_;
        }
    }
}
