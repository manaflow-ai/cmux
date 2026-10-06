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
    refuse_page_spawn_fields(mux, client, &cwd, &env, &shell_args)?;
    let spec = crate::ScreenSpec { name: screen_name, color, icon, pinned, index, group };
    let frontend = frontend_shell(mux, client);
    let spawn = placement_spawn_options(cwd, env.as_ref(), terminal_id, shell_args, frontend)?;
    let size = optional_surface_size(cols, rows);
    let (surface, screen) = mux.new_screen_with_spec(workspace, spawn, size, spec)?;
    let terminal_id = mux.resource_terminal_host_identity(&surface).map(|id| id.terminal_id);
    Ok(json!({ "surface": surface.id, "screen": screen, "terminal_id": terminal_id }))
}

/// R5 (plans/cmux-next/workspace-create-extension.md): a page never chooses
/// what a terminal runs, where, or with which environment. A page relay
/// connection (derived origin `page`) that sends `cwd`, `env` or
/// `shell_args` gets `origin.forbidden` before anything is created.
fn refuse_page_spawn_fields(
    mux: &Mux,
    client: u64,
    cwd: &Option<String>,
    env: &Option<BTreeMap<String, String>>,
    shell_args: &Option<Vec<String>>,
) -> anyhow::Result<()> {
    let present: Vec<&'static str> =
        [("cwd", cwd.is_some()), ("env", env.is_some()), ("shell_args", shell_args.is_some())]
            .into_iter()
            .filter_map(|(name, present)| present.then_some(name))
            .collect();
    if present.is_empty() {
        return Ok(());
    }
    let page = {
        let state =
            mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clients.get(&client).is_some_and(|record| {
            record.origin.derive() == crate::request_origin::RequestOrigin::Page
        })
    };
    if page {
        return Err(PageSpawnFieldsForbidden { fields: present }.into());
    }
    Ok(())
}

/// `origin.forbidden` on `new-screen`; the message names the fields, never
/// their values.
#[derive(Debug)]
struct PageSpawnFieldsForbidden {
    fields: Vec<&'static str>,
}

impl PageSpawnFieldsForbidden {
    const CODE: &'static str = "origin.forbidden";
}

impl std::fmt::Display for PageSpawnFieldsForbidden {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "{}: a page origin cannot send {} on new-screen",
            Self::CODE,
            self.fields.join(", ")
        )
    }
}

impl std::error::Error for PageSpawnFieldsForbidden {}

/// The `error_code` of a `new-screen` refusal.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<PageSpawnFieldsForbidden>().map(|_| PageSpawnFieldsForbidden::CODE.into())
}

#[cfg(all(test, unix))]
#[path = "new_screen_tests.rs"]
mod tests;
