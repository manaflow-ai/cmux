//! `new-screen`: a new screen in a workspace (default: the active one),
//! with `screen-metadata-v1` metadata applied in the creating commit and,
//! with `screen-terminal-env-v1`, the placement spawn fields of its first
//! terminal (`env`, `terminal_id`, `shell_args`, as on `new-pane`).

use super::*;

#[derive(Deserialize)]
pub(super) struct NewScreenParams {
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default)]
    cwd: Option<String>,
    /// The new screen's name (`name` would name its terminal).
    #[serde(default)]
    screen_name: Option<String>,
    #[serde(default)]
    color: Option<String>,
    #[serde(default)]
    icon: Option<String>,
    #[serde(default)]
    pinned: Option<bool>,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    group: Option<String>,
    #[serde(default)]
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    terminal_id: Option<String>,
    #[serde(default)]
    shell_args: Option<Vec<String>>,
}

pub(super) fn new_screen(
    mux: &Arc<Mux>,
    client: u64,
    params: NewScreenParams,
) -> anyhow::Result<Value> {
    let NewScreenParams {
        workspace,
        cols,
        rows,
        cwd,
        screen_name,
        color,
        icon,
        pinned,
        index,
        group,
        env,
        terminal_id,
        shell_args,
    } = params;
    let spec = crate::ScreenSpec { name: screen_name, color, icon, pinned, index, group };
    let frontend = frontend_shell(mux, client);
    let spawn = placement_spawn_options(cwd, env.as_ref(), terminal_id, shell_args, frontend)?;
    let size = optional_surface_size(cols, rows);
    let (surface, screen) = mux.new_screen_with_spec(workspace, spawn, size, spec)?;
    let terminal_id = mux.resource_terminal_host_identity(&surface).map(|id| id.terminal_id);
    Ok(json!({ "surface": surface.id, "screen": screen, "terminal_id": terminal_id }))
}

#[cfg(all(test, unix))]
#[path = "new_screen_tests.rs"]
mod tests;
