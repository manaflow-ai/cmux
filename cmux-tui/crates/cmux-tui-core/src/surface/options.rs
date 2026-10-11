//! Surface spawn options, default colors and terminal colors, and the TERM
//! value that children get.

use super::*;

/// How to spawn surface children.
#[derive(Debug, Clone)]
pub struct SurfaceOptions {
    /// Command argv; defaults to the platform shell.
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    /// TERM value for children: the outer terminal's xterm-ghostty when it
    /// advertised that (see [`default_child_term`]), else the compatible
    /// xterm-256color. CMUX_TUI_TERM/CMUX_MUX_TERM override.
    pub term: String,
    pub cols: u16,
    pub rows: u16,
    /// Maximum retained scrollback storage in bytes, matching Ghostty's
    /// `max_scrollback` API. This is not a line count.
    pub scrollback: usize,
    /// Extra environment for children (e.g. CMUX_TUI_SOCKET).
    pub extra_env: Vec<(String, String)>,
    /// The `claude` shim directory, kept first on every child's PATH.
    pub claude_shim_dir: Option<String>,
    /// The app's bundled CLI (`CMUX_BUNDLED_CLI_PATH` in the daemon's own
    /// environment): its dir stays first on every child's PATH after the
    /// shim, also over a caller PATH, and the value wins over a caller's.
    pub bundled_cli: Option<String>,
    /// Optional existing Chrome CDP endpoint, as ws://... or http://host:port.
    pub cdp_url: Option<String>,
    /// Maximum browser capture size before downscaling, in megapixels.
    pub browser_max_capture_megapixels: f64,
    /// Optional maximum browser capture scale, further reduced to honor the megapixel cap.
    pub browser_capture_scale: Option<f64>,
    /// Durable per-terminal host records. When set, PTYs are created in a
    /// dedicated process and this surface becomes an adoptable mirror.
    pub terminal_host_root: Option<PathBuf>,
    /// Adopt a live terminal host found under `terminal_host_root` into a
    /// fresh registry (one with no workspaces) instead of terminating it.
    ///
    /// Cloud VM snapshots keep the first terminal's host process, and its
    /// already-initialized shell, running while the daemon is parked and
    /// every per-machine file (machine id, receipt pepper, session registry,
    /// remote identity) is wiped. A clone's daemon then creates all of those
    /// fresh and imports the warm host as its first terminal, so no identity
    /// is shared between clones while the shell survives the snapshot.
    pub adopt_template_terminal: bool,
    /// Where to publish the adopted template terminal's new session and
    /// terminal ids (`KEY=value` lines) once adoption commits.
    pub template_bound_file: Option<PathBuf>,
    /// Name of the workspace created for the adopted template terminal. The
    /// template's own registry was wiped with the snapshot, so its name is
    /// not recoverable from the host record. `None` uses the default name.
    pub template_workspace_name: Option<String>,
}

/// Default TERM for child shells.
///
/// `xterm-ghostty` when the OUTER terminal advertised it (this process's
/// own TERM), else the compatible `xterm-256color`. No terminfo probing:
/// a Ghostty session that sets TERM=xterm-ghostty also exports TERMINFO
/// pointing at its bundled database, and children inherit that variable
/// through cmux-tui untouched, so the entry resolves for them exactly as
/// it does for programs in the raw Ghostty pane. Children — local and
/// remote (ssh forwards TERM, not terminfo) — therefore see precisely the
/// TERM they would have seen without the multiplexer, never a less
/// compatible one, and TERM-name-sniffing prompts (oh-my-zsh themes
/// matching `*256color`) take the same branch inside cmux-tui as in raw
/// Ghostty, so colors match. Only xterm-ghostty passes through: the inner
/// terminal IS ghostty-vt, so that name is truthful regardless of which
/// client later attaches; any other outer TERM would misdescribe it.
/// Servers started outside a Ghostty session (launchd, ssh, cron) keep
/// xterm-256color. CMUX_TUI_TERM, CMUX_MUX_TERM, and --term override.
pub fn default_child_term() -> String {
    child_term_for(std::env::var("TERM").ok().as_deref()).into()
}

/// Pure selection rule for [`default_child_term`].
pub(super) fn child_term_for(outer_term: Option<&str>) -> &'static str {
    if outer_term == Some("xterm-ghostty") { "xterm-ghostty" } else { "xterm-256color" }
}

impl Default for SurfaceOptions {
    fn default() -> Self {
        SurfaceOptions {
            command: None,
            cwd: None,
            term: std::env::var("CMUX_TUI_TERM")
                .or_else(|_| std::env::var("CMUX_MUX_TERM"))
                .unwrap_or_else(|_| default_child_term()),
            cols: 80,
            rows: 24,
            scrollback: DEFAULT_SCROLLBACK_LIMIT_BYTES,
            extra_env: Vec::new(),
            claude_shim_dir: None,
            bundled_cli: None,
            cdp_url: None,
            browser_max_capture_megapixels: crate::browser::TRANSPORT_SAFE_CAPTURE_MEGAPIXELS,
            browser_capture_scale: None,
            terminal_host_root: None,
            adopt_template_terminal: false,
            template_bound_file: None,
            template_workspace_name: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DefaultColors {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub cursor: Option<Rgb>,
    pub selection_bg: Option<Rgb>,
    pub selection_fg: Option<Rgb>,
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
    pub palette: [Option<Rgb>; 256],
}

impl Default for DefaultColors {
    fn default() -> Self {
        Self {
            fg: None,
            bg: None,
            cursor: None,
            selection_bg: None,
            selection_fg: None,
            cursor_style: None,
            cursor_blink: None,
            palette: [None; 256],
        }
    }
}

/// Install Ghostty configuration cursor defaults without collapsing the
/// nullable blink setting in [`DefaultColors`]. Ghostty starts an unspecified
/// cursor blinking, while still allowing DEC mode 12 to change the live mode;
/// the low-level VT engine needs that initial visual supplied explicitly.
/// Explicit `true` and `false` values pass through unchanged.
pub(crate) fn replace_ghostty_cursor_defaults(term: &mut Terminal, colors: DefaultColors) {
    term.replace_default_cursor(colors.cursor_style, Some(colors.cursor_blink.unwrap_or(true)));
}

/// Effective colors exposed to attached terminal clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalColors {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub cursor: Option<Rgb>,
    /// Application-authored special colors, separate from shared embedder
    /// defaults so byte viewers can retain their own configured themes.
    pub fg_override: Option<Rgb>,
    pub bg_override: Option<Rgb>,
    pub cursor_override: Option<Rgb>,
    pub selection_bg: Option<Rgb>,
    pub selection_fg: Option<Rgb>,
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
    /// Palette entries actively authored by the PTY with OSC 4. Unauthored
    /// entries stay `None` so an attached renderer can preserve its own
    /// configured theme.
    pub palette: [Option<Rgb>; 256],
}

impl Default for TerminalColors {
    fn default() -> Self {
        Self {
            fg: None,
            bg: None,
            cursor: None,
            fg_override: None,
            bg_override: None,
            cursor_override: None,
            selection_bg: None,
            selection_fg: None,
            cursor_style: None,
            cursor_blink: None,
            palette: [None; 256],
        }
    }
}

impl TerminalColors {
    pub(super) fn from_terminal(term: &Terminal, defaults: DefaultColors) -> Self {
        let (fg, bg, cursor) = term.effective_colors();
        let overrides = term.color_overrides();
        let cursor_visual = overrides.cursor_visual;
        TerminalColors {
            fg,
            bg,
            cursor,
            fg_override: overrides.foreground,
            bg_override: overrides.background,
            cursor_override: overrides.cursor,
            selection_bg: defaults.selection_bg,
            selection_fg: defaults.selection_fg,
            palette: overrides.palette,
            cursor_style: cursor_visual.map(|(style, _)| style).or(defaults.cursor_style),
            cursor_blink: cursor_visual.map(|(_, blink)| blink).or(defaults.cursor_blink),
        }
    }

    /// Snapshot a live palette update without touching the shared renderer.
    /// Palette OSC commands leave cursor state authoritative in the attached
    /// frontend's existing xterm state.
    pub(super) fn from_pty_output(term: &Terminal, defaults: DefaultColors) -> Self {
        let mut colors = Self::from_terminal(term, defaults);
        colors.cursor_style = None;
        colors.cursor_blink = None;
        colors
    }
}

pub(super) fn configure_agent_browser_session(options: &mut SurfaceOptions, terminal_id: &str) {
    let enabled = options
        .extra_env
        .iter()
        .any(|(key, value)| key == "CMUX_TUI_AGENT_BROWSER_PROVIDER" && value == "1");
    if enabled {
        // agent-browser daemons are keyed by session. A distinct caller
        // session prevents a command from another workspace from silently
        // reusing the first workspace's page-scoped CDP connection.
        set_env(&mut options.extra_env, "AGENT_BROWSER_SESSION", &format!("cmux-{terminal_id}"));
    }
}
