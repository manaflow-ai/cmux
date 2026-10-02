//! `move-tab-to-split` `respawn` (`tab-split-respawn-v1`): a pane's only
//! tab dropped on its own pane's edge splits that pane and leaves a fresh tab
//! of the given kind, plus the spawn fields every terminal placement shares.

use super::*;

/// `move-tab-to-split` `respawn`: a pane's only tab dropped on its own
/// pane's edge splits the pane and leaves a fresh tab of the given kind.
pub const TAB_SPLIT_RESPAWN_CAPABILITY: &str = "tab-split-respawn-v1";

/// `move-tab-to-split`, with `respawn` when the request carries one.
pub(super) fn split_tab(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    pane: PaneId,
    edge: crate::TabDropEdge,
    ratio: Option<f32>,
    respawn: Option<SplitRespawnRequest>,
    transaction: Option<String>,
) -> anyhow::Result<crate::TabDragOutcome> {
    match respawn {
        None => mux.move_tab_to_split(surface, pane, edge, ratio, transaction),
        Some(respawn) => {
            let respawn = respawn.into_respawn()?;
            mux.move_tab_to_split_respawning(surface, pane, edge, ratio, respawn, transaction)
        }
    }
}

/// `move-tab-to-split` `respawn` (`tab-split-respawn-v1`): the fresh tab a
/// split of a pane's only tab leaves in that pane. A terminal takes the
/// `new-tab` spawn fields; a browser tab takes a frontend browser record.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SplitRespawnRequest {
    kind: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    terminal_id: Option<String>,
    #[serde(default)]
    shell_args: Option<Vec<String>>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    engine: Option<String>,
    #[serde(default)]
    profile_id: Option<String>,
}

impl SplitRespawnRequest {
    fn into_respawn(self) -> anyhow::Result<crate::mux::SplitRespawn> {
        match self.kind.as_str() {
            "terminal" => Ok(crate::mux::SplitRespawn::Terminal(placement_spawn_options(
                self.cwd,
                self.env.as_ref(),
                self.terminal_id,
                self.shell_args,
            )?)),
            "browser" => {
                let record = crate::workspace_registry::FrontendBrowserRecord {
                    engine: self
                        .engine
                        .context("bad request: respawn kind browser requires engine")?,
                    url: self.url.context("bad request: respawn kind browser requires url")?,
                    title: None,
                    favicon_url: None,
                    profile_id: self.profile_id,
                };
                record.validate()?;
                Ok(crate::mux::SplitRespawn::Browser(record))
            }
            other => anyhow::bail!(
                "bad request: respawn kind must be \"terminal\" or \"browser\", not {other:?}"
            ),
        }
    }
}

pub(super) fn placement_spawn_options(
    cwd: Option<String>,
    env: Option<&BTreeMap<String, String>>,
    terminal_id: Option<String>,
    shell_args: Option<Vec<String>>,
) -> anyhow::Result<crate::TerminalSpawnOptions> {
    let env = env.map(crate::mux::validate_terminal_env).transpose()?.unwrap_or_default();
    let argv = shell_argv(&env, shell_args);
    Ok(crate::TerminalSpawnOptions { cwd, env, terminal_id, argv })
}

/// `terminal-shell-args-v1`: the shell the terminal would run with no
/// arguments, given `shell_args`, so a frontend can pass the argv Ghostty's
/// shell integration needs (bash `--posix` with `ENV`, nushell `--execute`).
/// The shell is the terminal's own `SHELL` from its `env` (the frontend
/// chose the arguments for it), else the daemon's default shell. None or an
/// empty list keeps the plain default shell.
pub(super) fn shell_argv(
    env: &[(String, String)],
    shell_args: Option<Vec<String>>,
) -> Option<Vec<String>> {
    let shell_args = shell_args.filter(|arguments| !arguments.is_empty())?;
    let shell = env
        .iter()
        .find(|(key, value)| key == "SHELL" && !value.is_empty())
        .map(|(_, value)| value.clone())
        .unwrap_or_else(platform::default_shell);
    Some(std::iter::once(shell).chain(shell_args).collect())
}

#[cfg(test)]
#[path = "split_respawn_tests.rs"]
mod tests;
