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
    /// `split-client-keys-v1`: caller-minted id of the new pane.
    #[serde(default)]
    pane_id: Option<String>,
    /// `split-client-keys-v1`: caller-minted id of the new pane's tab.
    #[serde(default)]
    tab_id: Option<String>,
}

/// `split`, `new-pane` and `new-pane-right` take client-minted `pane_id` and
/// `tab_id` and replay a keyed retry (plans/cmux-next/remote-state-ownership.md S1).
pub(super) const SPLIT_CLIENT_KEYS_CAPABILITY: &str = "split-client-keys-v1";

/// `split-client-keys-v1`: the caller-minted public ids of the new pane and
/// of its tab. A request that names one is keyed by it (a retry returns the
/// first result); the daemon refuses an id that exists or ever existed.
pub(super) struct PaneClientIds {
    pub pane_id: Option<String>,
    pub tab_id: Option<String>,
}

impl PaneClientIds {
    /// Puts the validated ids into `spawn`; a malformed id is a bad request
    /// before anything is created.
    pub(super) fn apply(self, spawn: &mut crate::TerminalSpawnOptions) -> anyhow::Result<()> {
        if let Some(pane_id) = &self.pane_id {
            crate::resource::PanePublicId::parse(pane_id.clone()).map_err(|_| {
                anyhow::anyhow!("bad request: pane_id {pane_id:?} is not a pane id")
            })?;
        }
        if let Some(tab_id) = &self.tab_id {
            TabPublicId::parse(tab_id.clone())
                .map_err(|_| anyhow::anyhow!("bad request: tab_id {tab_id:?} is not a tab id"))?;
        }
        spawn.pane_id = self.pane_id;
        spawn.tab_id = self.tab_id;
        Ok(())
    }
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
            pane_id: self.pane_id.is_some(),
            tab_id: self.tab_id.is_some(),
        };
        browser_pane_url(command, self.kind.take(), self.url.take(), &terminal)
    }

    fn spawn(self, mux: &Mux, client: u64) -> anyhow::Result<crate::TerminalSpawnOptions> {
        let mut spawn = placement_spawn_options(
            self.cwd,
            self.env.as_ref(),
            self.terminal_id,
            self.shell_args,
            frontend_shell(mux, client),
        )?;
        PaneClientIds { pane_id: self.pane_id, tab_id: self.tab_id }.apply(&mut spawn)?;
        Ok(spawn)
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
        let surface = mux.split_browser_pane_as(
            &origin_gate::connection_actor(mux, client),
            params.pane,
            SplitDir::Right,
            Some(width),
            url,
            size,
        )?;
        return Ok(json!({ "surface": surface.id }));
    }
    let keep = params.content.keep;
    let spawn = params.content.spawn(mux, client)?;
    let created = mux.new_pane_right_with_options_as(
        &origin_gate::connection_actor(mux, client),
        params.pane,
        width,
        spawn,
        size,
    )?;
    placed_pane_result(mux, &created, keep)
}

pub(super) fn split(mux: &Arc<Mux>, client: u64, mut params: SplitParams) -> anyhow::Result<Value> {
    let dir = parse_split_dir(&params.dir)?;
    let size = optional_surface_size(params.cols, params.rows);
    if let Some(url) = params.content.browser_url("split")? {
        let surface = mux.split_browser_pane_as(
            &origin_gate::connection_actor(mux, client),
            params.pane,
            dir,
            None,
            url,
            size,
        )?;
        return Ok(json!({ "surface": surface.id }));
    }
    let keep = params.content.keep;
    let spawn = params.content.spawn(mux, client)?;
    let created = mux.split_with_options_as(
        &origin_gate::connection_actor(mux, client),
        params.pane,
        dir,
        spawn,
        size,
    )?;
    placed_pane_result(mux, &created, keep)
}

/// [`placed_terminal_result`] plus the new pane's and tab's public ids
/// (`pane_id`, `tab_id`) and `replayed` when a keyed retry returned the
/// first result (`split-client-keys-v1`).
pub(super) fn placed_pane_result(
    mux: &Mux,
    created: &crate::mux::PaneSurfaceCreation,
    keep: bool,
) -> anyhow::Result<Value> {
    let mut result = placed_terminal_result(mux, &created.surface, keep)?;
    let surface = created.surface.id;
    if let Some(pane_id) = mux.with_state(|state| {
        state
            .pane_of(surface)
            .and_then(|pane| state.panes.get(&pane))
            .map(|pane| pane.public_id.to_string())
    }) {
        result["pane_id"] = Value::String(pane_id);
    }
    if let Some(identity) = created.surface.resource_identity() {
        result["tab_id"] = Value::String(identity.tab_id.to_string());
    }
    if created.replayed {
        result["replayed"] = Value::Bool(true);
    }
    Ok(result)
}

/// What the spare host of a terminal pane creation needs (R81): the pane,
/// the caller's terminal id, cwd, env, shell args and the new pane's size.
/// `None` for a browser pane, and without `cols`/`rows`: the spare would
/// start at the whole pane's size instead of the new pane's.
pub(super) struct PanePrelaunch<'a> {
    pub pane: PaneId,
    pub terminal_id: Option<&'a String>,
    pub cwd: Option<&'a String>,
    pub env: Option<&'a BTreeMap<String, String>>,
    pub shell_args: Option<&'a Vec<String>>,
    pub size: (u16, u16),
}

impl PaneContentParams {
    fn prelaunch(
        &self,
        pane: PaneId,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Option<PanePrelaunch<'_>> {
        if self.kind.as_deref() == Some("browser") {
            return None;
        }
        Some(PanePrelaunch {
            pane,
            terminal_id: self.terminal_id.as_ref(),
            cwd: self.cwd.as_ref(),
            env: self.env.as_ref(),
            shell_args: self.shell_args.as_ref(),
            size: optional_surface_size(cols, rows)?,
        })
    }
}

impl SplitParams {
    pub(super) fn prelaunch(&self) -> Option<PanePrelaunch<'_>> {
        self.content.prelaunch(self.pane, self.cols, self.rows)
    }

    /// The prelaunched host's id, so the create adopts it.
    pub(super) fn set_terminal_id(&mut self, terminal_hex: String) {
        self.content.terminal_id = Some(terminal_hex);
    }
}

impl NewPaneRightParams {
    pub(super) fn prelaunch(&self) -> Option<PanePrelaunch<'_>> {
        self.content.prelaunch(self.pane, self.cols, self.rows)
    }

    pub(super) fn set_terminal_id(&mut self, terminal_hex: String) {
        self.content.terminal_id = Some(terminal_hex);
    }
}

/// The terminal-only fields a request carried, for refusal messages.
struct TerminalFields {
    pub cwd: bool,
    pub env: bool,
    pub keep: bool,
    pub terminal_id: bool,
    pub shell_args: bool,
    pub pane_id: bool,
    pub tab_id: bool,
}

impl TerminalFields {
    fn first_present(&self) -> Option<&'static str> {
        [
            (self.cwd, "cwd"),
            (self.env, "env"),
            (self.keep, "keep"),
            (self.terminal_id, "terminal_id"),
            (self.shell_args, "shell_args"),
            (self.pane_id, "pane_id"),
            (self.tab_id, "tab_id"),
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

#[cfg(test)]
#[path = "split_client_ids_tests.rs"]
mod split_client_ids_tests;
