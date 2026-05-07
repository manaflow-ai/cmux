//! User settings for cmux-cli.
//!
//! Settings live at `~/.config/cmux-cli/settings.json`. The schema
//! intentionally overlaps with the macOS cmux app's settings (same key
//! names, same value shapes where meaningful) so muscle memory and docs
//! transfer between the two surfaces.
//!
//! For v1 we accept strict JSON. JSONC / trailing commas can come later.

use std::collections::HashMap;
use std::path::Path;

use cmux_cli_protocol::Command;
use serde::{Deserialize, Serialize};

/// Top-level settings document.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub shortcuts: Shortcuts,
    pub terminal: Terminal,
    pub app: App,
    pub notifications: Notifications,
}

/// Notification hooks. Fired whenever a tab's bell count increments
/// via `cmx notify` (explicit) or, in future revisions, PTY bell
/// output (`0x07`). The hook command is the user's chance to wire
/// cmx into their OS (macOS `osascript`, Linux `notify-send`, a
/// webhook, whatever).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Notifications {
    /// Shell command run on every notification. Runs via `/bin/sh -c`
    /// with these env vars exported:
    ///  - `CMX_BELL_WORKSPACE_ID`, `CMX_BELL_TAB_ID`, `CMX_BELL_TAB_TITLE`
    ///  - `CMX_BELL_COUNT` (the tab's running bell total after this event)
    ///  - `CMX_BELL_MESSAGE` (the `--message` passed to `cmx notify`,
    ///    empty string if none)
    ///  - Example (macOS): `osascript -e 'display notification "$CMX_BELL_MESSAGE" with title "cmx: $CMX_BELL_TAB_TITLE"'`.
    pub command: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Shortcuts {
    /// Prefix key, e.g. "C-b" (tmux), "C-a" (screen), "C-Space".
    /// Only used to expand bare single-key bindings — a binding whose
    /// chord string contains spaces (e.g. `"C-b c"`) is already a full
    /// chord and the prefix isn't applied.
    pub prefix: String,

    /// Shortcut preset controlling the default bindings. One of:
    /// - `"tmux"` — classic tmux chords (Ctrl-b + single-key)
    /// - `"zellij"` — zellij-style chords without a global prefix,
    ///   including pane-mode splits (`Ctrl-p r` / `Ctrl-p d`)
    /// - `"both"` (default) — tmux plus non-conflicting zellij chords
    ///   active at once; users press whichever muscle memory they have.
    ///
    /// User `bindings` entries always win over preset defaults for the same
    /// action.
    pub preset: String,

    /// Action-name → chord. Each chord is:
    /// - a single key ("c", "&", "5") — implicitly prepended with `prefix`
    ///   to form a two-byte tmux chord.
    /// - a `"C-x"` form — a single Ctrl-modified byte.
    /// - a space-separated sequence ("C-b c", "C-t n") — multi-key chord,
    ///   taken literally with no prefix expansion.
    ///
    /// Values may also be a JSON array of chord strings so one action can
    /// have multiple bindings at once (e.g. `["C-b c", "C-t n"]`).
    pub bindings: HashMap<String, ChordSet>,
}

impl Default for Shortcuts {
    fn default() -> Self {
        Self {
            prefix: "C-b".into(),
            preset: "both".into(),
            bindings: HashMap::new(),
        }
    }
}

/// One or more chord strings.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ChordSet {
    One(String),
    Many(Vec<String>),
}

impl ChordSet {
    fn iter(&self) -> Box<dyn Iterator<Item = &str> + '_> {
        match self {
            ChordSet::One(s) => Box::new(std::iter::once(s.as_str())),
            ChordSet::Many(v) => Box::new(v.iter().map(String::as_str)),
        }
    }
}

/// tmux-style default bindings (prefix = C-b by default).
fn tmux_preset_bindings() -> Vec<(&'static str, &'static str)> {
    vec![
        // Spaces are the tmux-window-equivalent top-level layout switcher.
        ("newSpace", "c"),
        ("nextSpace", "n"),
        ("prevSpace", "p"),
        ("closeSpace", "&"),
        ("focusSpaceStrip", "s"),
        // Workspace = sidebar-level container.
        ("newWorkspace", "W"),
        ("focusSidebar", "w"),
        // Keep the older sidebar chord alive for compatibility.
        ("focusSidebar", "b"),
        // tmux-compatibility aliases for switching between workspaces
        // (tmux calls this prev/next session, chord `(` / `)`).
        ("nextWorkspace", ")"),
        ("prevWorkspace", "("),
        ("closeWorkspace", "X"),
        // Terminals are pane-local and cmux-specific. Keep them first-class,
        // but on their own shortcut family so `c/n/p/0..9` remain spaces.
        ("newTerminal", "t"),
        ("nextTerminal", "]"),
        ("prevTerminal", "["),
        ("closeTerminal", "x"),
        ("detach", "d"),
        // Splits. tmux uses `%` for side-by-side panes and `"` for stacked
        // panes.
        ("splitHorizontal", "%"),
        ("splitVertical", "\""),
        ("unsplit", "="),
        // Directional focus (matches tmux `C-b Left/Right/Up/Down`).
        // Arrows are 3-byte CSI sequences — the chord engine
        // buffers the prefix + ESC [ X cleanly.
        ("focusLeft", "C-b Left"),
        ("focusRight", "C-b Right"),
        ("focusUp", "C-b Up"),
        ("focusDown", "C-b Down"),
        // Zoom: make the active leaf fill the pane, or restore the
        // split layout. Matches tmux `C-b z`.
        ("toggleZoom", "z"),
    ]
}

/// Zellij-style default bindings that are safe to keep active in the
/// default "both" preset. Ctrl-t = space, Ctrl-s = workspace, Ctrl-q =
/// detach. Pane-mode `Ctrl-p` chords stay in the explicit zellij preset so
/// default mixed mode does not steal common shell/editor control keys.
fn zellij_preset_bindings() -> Vec<(&'static str, &'static str)> {
    vec![
        ("newSpace", "C-t n"),
        ("nextSpace", "C-t j"),
        ("prevSpace", "C-t k"),
        ("closeSpace", "C-t x"),
        ("newWorkspace", "C-s n"),
        ("nextWorkspace", "C-s j"),
        ("prevWorkspace", "C-s k"),
        ("focusSidebar", "C-s w"),
        ("closeWorkspace", "C-s x"),
        ("detach", "C-q d"),
        ("focusLeft", "Alt-h"),
        ("focusLeft", "Alt-Left"),
        ("focusRight", "Alt-l"),
        ("focusRight", "Alt-Right"),
        ("focusUp", "Alt-k"),
        ("focusUp", "Alt-Up"),
        ("focusDown", "Alt-j"),
        ("focusDown", "Alt-Down"),
    ]
}

/// Extra zellij-style pane-management chords that remain opt-in. `Ctrl-p`
/// conflicts with common shell/editor shortcuts, so default mixed mode
/// leaves these bytes for the foreground program.
fn zellij_explicit_preset_bindings() -> Vec<(&'static str, &'static str)> {
    vec![("splitHorizontal", "C-p r"), ("splitVertical", "C-p d")]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Terminal {
    /// `scrollback-limit` per Ghostty's config key (bytes, per surface).
    #[serde(rename = "scrollback-limit")]
    pub scrollback_limit: usize,
    /// When true, selection is immediately copied to the system clipboard.
    #[serde(rename = "copyOnSelect")]
    pub copy_on_select: bool,
    /// `"opt-in"` (default), `"always"`, or `"never"`.
    pub mouse: String,
}

impl Default for Terminal {
    fn default() -> Self {
        Self {
            scrollback_limit: 10_000_000,
            copy_on_select: false,
            mouse: "opt-in".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct App {
    /// `"dies-when-empty"` (default) or `"persistent"`.
    #[serde(rename = "workspaceLifecycle")]
    pub workspace_lifecycle: String,
}

impl Default for App {
    fn default() -> Self {
        Self {
            workspace_lifecycle: "dies-when-empty".into(),
        }
    }
}

/// Load settings from disk. Returns the default settings if the file is
/// missing or unreadable; returns an error only if parsing fails (we want
/// that visible to the user so they can fix their syntax).
pub fn load(path: &Path) -> anyhow::Result<Settings> {
    let Ok(bytes) = std::fs::read(path) else {
        return Ok(Settings::default());
    };
    let settings: Settings = serde_json::from_slice(&bytes)
        .map_err(|e| anyhow::anyhow!("parse {}: {e}", path.display()))?;
    Ok(settings)
}

/// Write settings to disk. Used by `cmx source` when a client overrides
/// the live config via RPC (not in v1) and by tests.
pub fn save(path: &Path, settings: &Settings) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_vec_pretty(settings)?;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("settings.json");
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let tmp = parent.join(format!(".{file_name}.tmp-{}-{unique}", std::process::id()));
    std::fs::write(&tmp, json)?;
    if let Err(err) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(err.into());
    }
    Ok(())
}

// ---------------------------- Keybind compile -----------------------------

/// A compiled keybind table.
#[derive(Debug, Clone, Default)]
pub struct KeybindTable {
    /// Ordered list of (chord bytes, command). Longest chord wins when two
    /// share a prefix — callers enumerate via an InputHandler state machine.
    pub bindings: Vec<(Vec<u8>, Command)>,
}

impl KeybindTable {
    /// Does any chord start with this byte sequence?
    fn is_prefix(&self, buf: &[u8]) -> bool {
        self.bindings
            .iter()
            .any(|(chord, _)| chord.len() > buf.len() && chord.starts_with(buf))
    }

    /// Exact match against the full buffered bytes.
    fn exact(&self, buf: &[u8]) -> Option<Command> {
        self.bindings
            .iter()
            .find(|(chord, _)| chord.as_slice() == buf)
            .map(|(_, cmd)| cmd.clone())
    }
}

/// Compile `Settings` into a `KeybindTable`. Preset defaults are applied
/// first (tmux / zellij / both), then user overrides in `bindings` replace
/// the chord(s) for that action.
#[must_use]
pub fn compile(settings: &Settings) -> KeybindTable {
    let prefix = parse_single_key(&settings.shortcuts.prefix).unwrap_or(0x02);

    // Seed with preset defaults.
    let preset = settings.shortcuts.preset.as_str();
    let mut sources: Vec<(String, String)> = Vec::new();
    if preset == "tmux" || preset == "both" {
        for (a, c) in tmux_preset_bindings() {
            sources.push((a.into(), c.into()));
        }
        for i in 0..=9u8 {
            sources.push((format!("selectSpace{i}"), i.to_string()));
            sources.push((format!("selectTerminal{i}"), format!("C-b t {i}")));
            // Numeric workspace jump: `C-b g <N>` goes to workspace N.
            // `g` = "go to" mnemonic; distinct from bare `<N>` which
            // selects spaces. Two-byte chord after the prefix so the
            // `C-b g` state buffers and waits for the digit.
            sources.push((format!("selectWorkspace{i}"), format!("C-b g {i}")));
        }
    }
    if preset == "zellij" || preset == "both" {
        for (a, c) in zellij_preset_bindings() {
            sources.push((a.into(), c.into()));
        }
        for i in 0..=9u8 {
            sources.push((format!("selectTerminal{i}"), format!("C-t {i}")));
        }
    }
    if preset == "zellij" {
        for (a, c) in zellij_explicit_preset_bindings() {
            sources.push((a.into(), c.into()));
        }
    }

    // User bindings replace preset bindings for the same action — remove
    // any preset entries for actions the user explicitly configured.
    let overridden: std::collections::HashSet<&str> = settings
        .shortcuts
        .bindings
        .keys()
        .map(|s| s.as_str())
        .collect();
    sources.retain(|(action, _)| !overridden.contains(action.as_str()));

    // Then append user chords.
    for (action, chords) in &settings.shortcuts.bindings {
        for chord in chords.iter() {
            sources.push((action.clone(), chord.into()));
        }
    }

    let mut bindings: Vec<(Vec<u8>, Command)> = Vec::with_capacity(sources.len());
    for (action, chord_str) in sources {
        let Some(cmd) = action_to_command(&action) else {
            continue;
        };
        let Some(chord) = parse_chord(&chord_str, prefix) else {
            continue;
        };
        bindings.push((chord, cmd));
    }

    // Sort by length descending so the longest-prefix match wins when two
    // chords happen to match the same buffer (shouldn't happen after
    // dedup, but be safe).
    bindings.sort_by_key(|(chord, _)| std::cmp::Reverse(chord.len()));

    KeybindTable { bindings }
}

/// Parse a chord string into raw bytes.
///
/// - Bare single-char ("c" or "&") is implicitly prefixed with `prefix`.
/// - "C-x" is a single ctrl byte, no prefix expansion.
/// - Space-separated tokens are each parsed as a key, concatenated.
/// - "Alt-x" / "M-x" token → ESC followed by the key bytes.
/// - "Space" / "SPC" token → ASCII space (0x20).
/// - "Tab" / "TAB" token → 0x09.
/// - "Enter" / "RET" token → 0x0D.
/// - "Left" / "Right" / "Up" / "Down" → 3-byte CSI sequence
///   (`ESC [ D` etc.) — same bytes a real terminal emits, so
///   chords that follow arrows work against both real keyboard
///   input and synthesized input from `cmx send-key`.
#[must_use]
pub fn parse_chord(s: &str, prefix: u8) -> Option<Vec<u8>> {
    let tokens: Vec<&str> = s.split_whitespace().collect();
    if tokens.is_empty() {
        return None;
    }
    if tokens.len() == 1 {
        let tok = tokens[0];
        // A bare single ASCII char is prefix-expanded so configs can keep
        // using "newTab": "c" and mean `C-b c`.
        if tok.chars().count() == 1
            && let Some(ch) = tok.chars().next()
            && ch.is_ascii()
            && !tok.starts_with("C-")
        {
            return Some(vec![prefix, ch as u8]);
        }
        parse_key_bytes(tok)
    } else {
        let mut out = Vec::new();
        for tok in tokens {
            let mut b = parse_key_bytes(tok)?;
            out.append(&mut b);
        }
        Some(out)
    }
}

/// Parse a single token into its raw byte sequence. Single-byte keys
/// come from `parse_single_key`; multi-byte tokens (arrows, for now)
/// have their own mapping so the chord engine can bind them.
fn parse_key_bytes(tok: &str) -> Option<Vec<u8>> {
    if let Some(rest) = strip_modifier_prefix(tok, &["M-", "Alt-", "Alt+", "Meta-", "Meta+"]) {
        let mut out = vec![0x1b];
        out.extend_from_slice(&parse_key_bytes(rest)?);
        return Some(out);
    }
    match tok.to_ascii_uppercase().as_str() {
        "LEFT" => return Some(b"\x1b[D".to_vec()),
        "RIGHT" => return Some(b"\x1b[C".to_vec()),
        "UP" => return Some(b"\x1b[A".to_vec()),
        "DOWN" => return Some(b"\x1b[B".to_vec()),
        _ => {}
    }
    parse_single_key(tok).map(|b| vec![b])
}

fn strip_modifier_prefix<'a>(tok: &'a str, prefixes: &[&str]) -> Option<&'a str> {
    prefixes.iter().find_map(|prefix| {
        let head = tok.get(..prefix.len())?;
        if head.eq_ignore_ascii_case(prefix) {
            tok.get(prefix.len()..)
        } else {
            None
        }
    })
}

/// Back-compat alias for the old single-key parser (prefix key etc.).
#[must_use]
pub fn parse_key(s: &str) -> Option<u8> {
    parse_single_key(s)
}

fn parse_single_key(s: &str) -> Option<u8> {
    let trimmed = s.trim();
    // Named keys.
    match trimmed.to_ascii_uppercase().as_str() {
        "SPACE" | "SPC" => return Some(0x20),
        "TAB" => return Some(0x09),
        "ENTER" | "RET" | "RETURN" => return Some(0x0D),
        "ESC" | "ESCAPE" => return Some(0x1b),
        _ => {}
    }
    if let Some(rest) = trimmed.strip_prefix("C-")
        && let Some(ch) = rest.chars().next()
        && rest.chars().count() == 1
    {
        let upper = ch.to_ascii_uppercase();
        if upper.is_ascii_uppercase() {
            return Some((upper as u8) - b'A' + 1);
        }
    }
    if let Some(rest) = trimmed.strip_prefix("C-")
        && rest.eq_ignore_ascii_case("space")
    {
        return Some(0x00);
    }
    let mut chars = trimmed.chars();
    let first = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    if first.is_ascii() {
        Some(first as u8)
    } else {
        None
    }
}

fn action_to_command(name: &str) -> Option<Command> {
    match name {
        "newSpace" => Some(Command::NewSpace { title: None }),
        "nextSpace" => Some(Command::NextSpace),
        "prevSpace" => Some(Command::PrevSpace),
        "closeSpace" => Some(Command::CloseSpace),
        "focusSpaceStrip" => Some(Command::FocusSpaceStrip),
        "newTerminal" | "newTab" => Some(Command::NewTab),
        "nextTerminal" | "nextTab" => Some(Command::NextTab),
        "prevTerminal" | "prevTab" => Some(Command::PrevTab),
        "closeTerminal" | "closeTab" => Some(Command::CloseTab),
        "newWorkspace" => Some(Command::NewWorkspace {
            title: None,
            cwd: None,
        }),
        "nextWorkspace" => Some(Command::NextWorkspace),
        "prevWorkspace" => Some(Command::PrevWorkspace),
        "closeWorkspace" => Some(Command::CloseWorkspace),
        "detach" => Some(Command::Detach),
        "splitHorizontal" => Some(Command::SplitHorizontal),
        "splitVertical" => Some(Command::SplitVertical),
        "unsplit" => Some(Command::Unsplit),
        "focusLeft" => Some(Command::FocusLeft),
        "focusRight" => Some(Command::FocusRight),
        "focusUp" => Some(Command::FocusUp),
        "focusDown" => Some(Command::FocusDown),
        "focusSidebar" => Some(Command::FocusSidebar),
        "toggleZoom" => Some(Command::ToggleZoom),
        _ => {
            if let Some(digits) = name.strip_prefix("selectSpace")
                && let Ok(idx) = digits.parse::<usize>()
            {
                return Some(Command::SelectSpace { index: idx });
            }
            if let Some(digits) = name.strip_prefix("selectTerminal")
                && let Ok(idx) = digits.parse::<usize>()
            {
                return Some(Command::SelectTab { index: idx });
            }
            if let Some(digits) = name.strip_prefix("selectTab")
                && let Ok(idx) = digits.parse::<usize>()
            {
                return Some(Command::SelectTab { index: idx });
            }
            if let Some(digits) = name.strip_prefix("selectWorkspace")
                && let Ok(idx) = digits.parse::<usize>()
            {
                return Some(Command::SelectWorkspace { index: idx });
            }
            None
        }
    }
}

// ----------------------------- Input handler ------------------------------

/// State machine that matches multi-byte chords against the input stream.
///
/// On each byte: extend the buffer, check for an exact chord match (fire
/// command + reset), check for prefix match of a longer chord (hold), else
/// flush the buffer to the PTY and continue.
#[derive(Debug)]
pub struct InputHandler {
    table: KeybindTable,
    buf: Vec<u8>,
}

impl InputHandler {
    #[must_use]
    pub fn new(table: KeybindTable) -> Self {
        Self {
            table,
            buf: Vec::with_capacity(8),
        }
    }

    pub fn set_table(&mut self, table: KeybindTable) -> Vec<u8> {
        let pending = std::mem::take(&mut self.buf);
        self.table = table;
        pending
    }

    pub fn process(&mut self, bytes: &[u8]) -> (Vec<u8>, Vec<Command>) {
        let mut pass = Vec::with_capacity(bytes.len());
        let mut commands = Vec::new();
        for &b in bytes {
            self.buf.push(b);

            if let Some(cmd) = self.table.exact(&self.buf) {
                commands.push(cmd);
                self.buf.clear();
                continue;
            }
            if self.table.is_prefix(&self.buf) {
                // Wait for more bytes.
                continue;
            }
            // No chord matched — flush everything.
            pass.extend_from_slice(&self.buf);
            self.buf.clear();
        }
        (pass, commands)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bound(t: &KeybindTable, chord: &[u8]) -> Option<Command> {
        t.bindings
            .iter()
            .find(|(c, _)| c == chord)
            .map(|(_, cmd)| cmd.clone())
    }

    #[test]
    fn tmux_preset_binds_numeric_workspace_jumps_via_g_prefix() {
        let mut s = Settings::default();
        s.shortcuts.preset = "tmux".into();
        let t = compile(&s);
        // `C-b g 0` = [0x02, 0x67, 0x30] → SelectWorkspace { 0 }.
        assert!(matches!(
            bound(&t, b"\x02g0"),
            Some(Command::SelectWorkspace { index: 0 })
        ));
        assert!(matches!(
            bound(&t, b"\x02g5"),
            Some(Command::SelectWorkspace { index: 5 })
        ));
        assert!(matches!(
            bound(&t, b"\x02g9"),
            Some(Command::SelectWorkspace { index: 9 })
        ));
    }

    #[test]
    fn select_workspace_action_parses_from_name() {
        // Round-trip proof: the action-name → Command mapping must
        // recognise the digit suffix just like selectTab does.
        let cmd = action_to_command("selectWorkspace3");
        assert!(matches!(cmd, Some(Command::SelectWorkspace { index: 3 })));
    }

    #[test]
    fn tmux_preset_has_workspace_switch_bindings() {
        let mut s = Settings::default();
        s.shortcuts.preset = "tmux".into();
        let t = compile(&s);
        // tmux default: C-b w focuses the workspace sidebar, C-b W creates a
        // workspace, and C-b ) / ( cycle workspaces.
        assert!(matches!(bound(&t, b"\x02w"), Some(Command::FocusSidebar)));
        assert!(matches!(
            bound(&t, b"\x02W"),
            Some(Command::NewWorkspace { .. })
        ));
        assert!(matches!(bound(&t, b"\x02b"), Some(Command::FocusSidebar)));
        // tmux-compat aliases: C-b ) for next session, C-b ( for prev.
        assert!(matches!(bound(&t, b"\x02)"), Some(Command::NextWorkspace)));
        assert!(matches!(bound(&t, b"\x02("), Some(Command::PrevWorkspace)));
    }

    #[test]
    fn tmux_preset_uses_tmux_split_bindings() {
        let mut s = Settings::default();
        s.shortcuts.preset = "tmux".into();
        let t = compile(&s);
        assert!(matches!(
            bound(&t, b"\x02%"),
            Some(Command::SplitHorizontal)
        ));
        assert!(matches!(bound(&t, b"\x02\""), Some(Command::SplitVertical)));
        assert!(bound(&t, b"\x02|").is_none(), "old split chord leaked");
        assert!(bound(&t, b"\x02-").is_none(), "old split chord leaked");
    }

    #[test]
    fn default_settings_compile_has_both_presets() {
        let s = Settings::default();
        let t = compile(&s);
        // tmux: Ctrl-b c = new space.
        assert!(matches!(
            bound(&t, b"\x02c"),
            Some(Command::NewSpace { .. })
        ));
        // zellij: Ctrl-t n = new space.
        assert!(matches!(
            bound(&t, b"\x14n"),
            Some(Command::NewSpace { .. })
        ));
        // Ctrl-b t = new terminal in the focused pane.
        assert!(matches!(bound(&t, b"\x02t"), Some(Command::NewTab)));
        // Numeric space-switch (tmux preset).
        assert!(matches!(
            bound(&t, b"\x020"),
            Some(Command::SelectSpace { index: 0 })
        ));
        // Top-level Ctrl-t digit switches terminals in the focused pane.
        assert!(matches!(
            bound(&t, b"\x140"),
            Some(Command::SelectTab { index: 0 })
        ));
        assert!(matches!(
            bound(&t, b"\x149"),
            Some(Command::SelectTab { index: 9 })
        ));
    }

    #[test]
    fn tmux_only_preset_excludes_zellij_chords() {
        let mut s = Settings::default();
        s.shortcuts.preset = "tmux".into();
        let t = compile(&s);
        assert!(bound(&t, b"\x02c").is_some(), "tmux chord missing");
        assert!(bound(&t, b"\x14n").is_none(), "zellij chord leaked");
    }

    #[test]
    fn zellij_only_preset_excludes_tmux_chords() {
        let mut s = Settings::default();
        s.shortcuts.preset = "zellij".into();
        let t = compile(&s);
        assert!(bound(&t, b"\x02c").is_none(), "tmux chord leaked");
        assert!(bound(&t, b"\x14n").is_some(), "zellij chord missing");
    }

    #[test]
    fn zellij_only_preset_binds_alt_pane_navigation() {
        let mut s = Settings::default();
        s.shortcuts.preset = "zellij".into();
        let t = compile(&s);

        assert!(matches!(bound(&t, b"\x1bh"), Some(Command::FocusLeft)));
        assert!(matches!(bound(&t, b"\x1b\x1b[D"), Some(Command::FocusLeft)));
        assert!(matches!(bound(&t, b"\x1bl"), Some(Command::FocusRight)));
        assert!(matches!(
            bound(&t, b"\x1b\x1b[C"),
            Some(Command::FocusRight)
        ));
        assert!(matches!(bound(&t, b"\x1bk"), Some(Command::FocusUp)));
        assert!(matches!(bound(&t, b"\x1b\x1b[A"), Some(Command::FocusUp)));
        assert!(matches!(bound(&t, b"\x1bj"), Some(Command::FocusDown)));
        assert!(matches!(bound(&t, b"\x1b\x1b[B"), Some(Command::FocusDown)));
    }

    #[test]
    fn default_both_preset_binds_alt_pane_navigation() {
        let t = compile(&Settings::default());
        assert!(
            matches!(bound(&t, b"\x1bh"), Some(Command::FocusLeft)),
            "Alt-h should focus the left pane by default"
        );
        assert!(
            matches!(bound(&t, b"\x1b\x1b[D"), Some(Command::FocusLeft)),
            "Alt-Left should focus the left pane by default"
        );
        assert!(
            matches!(bound(&t, b"\x02b"), Some(Command::FocusSidebar)),
            "Ctrl-b b should focus the workspace sidebar by default"
        );
        assert!(
            matches!(bound(&t, b"\x13w"), Some(Command::FocusSidebar)),
            "Ctrl-s w should focus the workspace sidebar by default"
        );
    }

    #[test]
    fn zellij_only_preset_binds_ctrl_p_split_chords() {
        let mut s = Settings::default();
        s.shortcuts.preset = "zellij".into();
        let t = compile(&s);
        assert!(matches!(
            bound(&t, b"\x10r"),
            Some(Command::SplitHorizontal)
        ));
        assert!(matches!(bound(&t, b"\x10d"), Some(Command::SplitVertical)));
    }

    #[test]
    fn default_both_preset_leaves_ctrl_p_split_chords_unbound() {
        let t = compile(&Settings::default());
        assert!(
            bound(&t, b"\x10r").is_none(),
            "Ctrl-p r should pass through"
        );
        assert!(
            bound(&t, b"\x10d").is_none(),
            "Ctrl-p d should pass through"
        );
    }

    #[test]
    fn parse_alt_key_tokens() {
        assert_eq!(parse_chord("Alt-h", 0x02), Some(b"\x1bh".to_vec()));
        assert_eq!(parse_chord("M-l", 0x02), Some(b"\x1bl".to_vec()));
        assert_eq!(parse_chord("Alt-Left", 0x02), Some(b"\x1b\x1b[D".to_vec()));
        assert_eq!(parse_chord("Alt+Down", 0x02), Some(b"\x1b\x1b[B".to_vec()));
    }

    #[test]
    fn user_override_replaces_preset_chord_for_action() {
        let mut s = Settings::default();
        s.shortcuts.preset = "tmux".into();
        s.shortcuts
            .bindings
            .insert("newSpace".into(), ChordSet::One("C-space n".into()));
        let t = compile(&s);
        // Preset tmux chord for NewSpace must be gone.
        assert!(bound(&t, b"\x02c").is_none(), "preset chord not overridden");
        // User-supplied chord is present: Ctrl-Space = 0x00, n.
        assert!(matches!(
            bound(&t, b"\x00n"),
            Some(Command::NewSpace { .. })
        ));
    }

    #[test]
    fn user_can_bind_multiple_chords_to_one_action() {
        let mut s = Settings::default();
        s.shortcuts.preset = "tmux".into();
        s.shortcuts.bindings.insert(
            "newSpace".into(),
            ChordSet::Many(vec!["c".into(), "C-x n".into()]),
        );
        let t = compile(&s);
        // Bare "c" is prefix-expanded to `C-b c`.
        assert!(matches!(
            bound(&t, b"\x02c"),
            Some(Command::NewSpace { .. })
        ));
        // Multi-key chord is taken literally.
        assert!(matches!(
            bound(&t, b"\x18n"),
            Some(Command::NewSpace { .. })
        ));
    }

    #[test]
    fn parse_ctrl_letters() {
        assert_eq!(parse_key("C-a"), Some(0x01));
        assert_eq!(parse_key("C-b"), Some(0x02));
        assert_eq!(parse_key("C-x"), Some(0x18));
        assert_eq!(parse_key("C-Z"), Some(0x1a));
    }

    #[test]
    fn parse_single_char() {
        assert_eq!(parse_key("c"), Some(b'c'));
        assert_eq!(parse_key("&"), Some(b'&'));
        assert_eq!(parse_key("5"), Some(b'5'));
    }

    #[test]
    fn input_handler_passes_through_normal_bytes() {
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        let (pass, cmds) = h.process(b"hello\n");
        assert_eq!(pass, b"hello\n");
        assert!(cmds.is_empty());
    }

    #[test]
    fn input_handler_catches_prefix_command() {
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        // Ctrl-B + c → NewSpace.
        let (pass, cmds) = h.process(b"\x02c");
        assert!(pass.is_empty());
        assert_eq!(cmds.len(), 1);
        assert!(matches!(cmds[0], Command::NewSpace { .. }));
    }

    #[test]
    fn input_handler_forwards_unrecognised_prefix_combo() {
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        // Ctrl-B + `~` → not bound in any preset; forward both bytes.
        let (pass, cmds) = h.process(b"\x02~");
        assert_eq!(pass, b"\x02~");
        assert!(cmds.is_empty());
    }

    #[test]
    fn input_handler_preserves_state_across_batches() {
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        let (pass, cmds) = h.process(b"\x02");
        assert!(pass.is_empty());
        assert!(cmds.is_empty());
        let (pass, cmds) = h.process(b"c");
        assert!(pass.is_empty());
        assert_eq!(cmds.len(), 1);
        assert!(matches!(cmds[0], Command::NewSpace { .. }));
    }

    #[test]
    fn input_handler_returns_pending_prefix_on_table_reload() {
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        let (pass, cmds) = h.process(b"\x02");
        assert!(pass.is_empty());
        assert!(cmds.is_empty());

        let pending = h.set_table(KeybindTable { bindings: vec![] });
        let (pass, cmds) = h.process(b"x");

        assert_eq!(pending, b"\x02");
        assert_eq!(pass, b"x");
        assert!(cmds.is_empty());
    }

    #[test]
    fn input_handler_matches_zellij_chord_without_prefix() {
        // With default preset = "both", `C-t n` is a bound chord on its
        // own — no global prefix needed.
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        let (pass, cmds) = h.process(b"\x14n");
        assert!(pass.is_empty());
        assert_eq!(cmds.len(), 1);
        assert!(matches!(cmds[0], Command::NewSpace { .. }));
    }

    #[test]
    fn input_handler_holds_on_partial_chord_across_calls() {
        let t = compile(&Settings::default());
        let mut h = InputHandler::new(t);
        // First byte (C-t) is a prefix of `C-t n` — MUST be buffered.
        let (pass, cmds) = h.process(b"\x14");
        assert!(pass.is_empty(), "prefix byte leaked to PTY");
        assert!(cmds.is_empty());
        // Typing "z" after C-t: not bound under any preset → flush both.
        let (pass, cmds) = h.process(b"z");
        assert_eq!(pass, b"\x14z");
        assert!(cmds.is_empty());
    }

    #[test]
    fn settings_roundtrip_to_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = Settings::default();
        s.shortcuts.prefix = "C-a".into();
        save(&path, &s).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(loaded.shortcuts.prefix, "C-a");
    }
}
