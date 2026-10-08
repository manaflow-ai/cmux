//! `pane-browser-kind-v1`: the optional `kind` and `url` fields of raw
//! `split` and `new-pane-right`. `kind: "browser"` with a `url` makes the new
//! pane hold a browser; `kind: "pty"` or no kind keeps the terminal pane.

use super::split_respawn::{frontend_shell, placement_spawn_options};
use super::*;

/// `new-pane-right`: a viewport column after `pane`'s column.
#[derive(Deserialize)]
pub(super) struct NewPaneRightParams {
    pane: PaneId,
    #[serde(default)]
    width: Option<f32>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(flatten)]
    content: PaneContentParams,
}

/// `split`: a new pane after `pane` in its split tree.
#[derive(Deserialize)]
pub(super) struct SplitParams {
    pane: PaneId,
    /// "right" or "down"
    dir: String,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(flatten)]
    content: PaneContentParams,
}

/// What the new pane holds: a terminal (fields of `terminal-env-v1`,
/// `terminal-placement-env-v1`, `terminal-reap-v1`, `terminal-shell-args-v1`)
/// or, with `pane-browser-kind-v1`, a browser at `url`.
#[derive(Deserialize)]
struct PaneContentParams {
    #[serde(default)]
    cwd: Option<String>,
    /// Extra environment for the new terminal's child only.
    #[serde(default)]
    env: Option<BTreeMap<String, String>>,
    /// Mark the new terminal `keep` so it survives with no tab.
    #[serde(default)]
    keep: bool,
    /// Caller-chosen terminal host id (`terminal-placement-env-v1`).
    #[serde(default)]
    terminal_id: Option<String>,
    /// `terminal-shell-args-v1`: arguments for the terminal's shell (its
    /// `SHELL` in `env`, else the daemon's default shell).
    #[serde(default)]
    shell_args: Option<Vec<String>>,
    /// `pane-browser-kind-v1`: `pty` (default) or `browser` with `url`.
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    url: Option<String>,
}

impl PaneContentParams {
    /// The browser URL, or `None` for a terminal pane (see
    /// [`browser_pane_url`]).
    fn browser_url(&mut self, command: &str) -> anyhow::Result<Option<String>> {
        let terminal = TerminalFields {
            cwd: self.cwd.is_some(),
            env: self.env.is_some(),
            keep: self.keep,
            terminal_id: self.terminal_id.is_some(),
            shell_args: self.shell_args.is_some(),
        };
        browser_pane_url(command, self.kind.take(), self.url.take(), &terminal)
    }

    fn spawn(self, mux: &Mux, client: u64) -> anyhow::Result<crate::TerminalSpawnOptions> {
        placement_spawn_options(
            self.cwd,
            self.env.as_ref(),
            self.terminal_id,
            self.shell_args,
            frontend_shell(mux, client),
        )
    }
}

pub(super) fn new_pane_right(
    mux: &Arc<Mux>,
    client: u64,
    mut params: NewPaneRightParams,
) -> anyhow::Result<Value> {
    let width = params.width.unwrap_or(crate::DEFAULT_VIEWPORT_PANE_WIDTH);
    let size = optional_surface_size(params.cols, params.rows);
    if let Some(url) = params.content.browser_url("new-pane-right")? {
        let surface =
            mux.split_browser_pane_as(&origin_gate::connection_actor(mux, client), params.pane, SplitDir::Right, Some(width), url, size)?;
        return Ok(json!({ "surface": surface.id }));
    }
    let keep = params.content.keep;
    let spawn = params.content.spawn(mux, client)?;
    let surface = mux.new_pane_right_with_options_as(&origin_gate::connection_actor(mux, client), params.pane, width, spawn, size)?;
    placed_terminal_result(mux, &surface, keep)
}

pub(super) fn split(mux: &Arc<Mux>, client: u64, mut params: SplitParams) -> anyhow::Result<Value> {
    let dir = parse_split_dir(&params.dir)?;
    let size = optional_surface_size(params.cols, params.rows);
    if let Some(url) = params.content.browser_url("split")? {
        let surface = mux.split_browser_pane_as(&origin_gate::connection_actor(mux, client), params.pane, dir, None, url, size)?;
        return Ok(json!({ "surface": surface.id }));
    }
    let keep = params.content.keep;
    let spawn = params.content.spawn(mux, client)?;
    let surface = mux.split_with_options_as(&origin_gate::connection_actor(mux, client), params.pane, dir, spawn, size)?;
    placed_terminal_result(mux, &surface, keep)
}

/// The terminal-only fields a request carried, for refusal messages.
struct TerminalFields {
    pub cwd: bool,
    pub env: bool,
    pub keep: bool,
    pub terminal_id: bool,
    pub shell_args: bool,
}

impl TerminalFields {
    fn first_present(&self) -> Option<&'static str> {
        [
            (self.cwd, "cwd"),
            (self.env, "env"),
            (self.keep, "keep"),
            (self.terminal_id, "terminal_id"),
            (self.shell_args, "shell_args"),
        ]
        .into_iter()
        .find_map(|(present, name)| present.then_some(name))
    }
}

/// The browser URL for a new pane, or `None` for a terminal pane. Unknown
/// kinds, a browser without a URL, a URL on a terminal and terminal fields on
/// a browser are refused before anything is created.
fn browser_pane_url(
    command: &str,
    kind: Option<String>,
    url: Option<String>,
    terminal: &TerminalFields,
) -> anyhow::Result<Option<String>> {
    match kind.as_deref() {
        None | Some("pty") => {
            anyhow::ensure!(url.is_none(), "bad request: {command} url requires kind \"browser\"");
            Ok(None)
        }
        Some("browser") => {
            let url = url.filter(|url| !url.is_empty()).with_context(|| {
                format!("bad request: {command} kind \"browser\" requires a url")
            })?;
            if let Some(field) = terminal.first_present() {
                anyhow::bail!("bad request: {command} {field} applies only to kind \"pty\"");
            }
            Ok(Some(url))
        }
        Some(other) => {
            anyhow::bail!("bad request: {command} kind {other:?} (want \"pty\" or \"browser\")")
        }
    }
}
