//! Terminal output and exit snapshots read from state: plain output rendering, output read results, run placements, and exit snapshots.

use super::*;

/// Render raw terminal output bytes to plain text by replaying them through
/// a fresh terminal emulator sized to the recorded geometry, then formatting
/// the full page list without escapes ([`ghostty_vt::Terminal::plain_text`]).
/// The scrollback budget is the window's own byte count, so no row of the
/// bounded window is evicted before formatting.
pub(super) fn render_terminal_output_plain<'a>(
    chunks: impl Iterator<Item = &'a [u8]> + Clone,
    cols: u16,
    rows: u16,
) -> anyhow::Result<String> {
    let scrollback: usize = chunks.clone().map(<[u8]>::len).sum();
    let mut terminal = ghostty_vt::Terminal::new(
        cols.max(1),
        rows.max(1),
        scrollback,
        ghostty_vt::Callbacks::default(),
    )?;
    for chunk in chunks {
        terminal.vt_write(chunk);
    }
    Ok(terminal.plain_text()?)
}

pub(super) fn terminal_output_read_result(
    text: String,
    start_offset: u64,
    next_offset: u64,
    complete: bool,
) -> Value {
    serde_json::json!({
        "text": text,
        "start_offset": start_offset.to_string(),
        "next_offset": next_offset.to_string(),
        "complete": complete,
    })
}

pub(super) fn run_placement_for_surface(state: &State, surface: SurfaceId) -> Option<RunPlacement> {
    let pane = state.pane_of(surface)?;
    let (workspace_index, screen_index) = state.screen_of(pane)?;
    Some(RunPlacement {
        surface,
        pane,
        screen: state.workspaces[workspace_index].screens[screen_index].id,
        workspace: state.workspaces[workspace_index].id,
    })
}

pub(super) fn terminal_exit_snapshot_in_state(
    registry: &WorkspaceRegistry,
    state: &State,
    terminal_id: &str,
) -> anyhow::Result<Value> {
    let public_id = registry
        .terminal_resource_id(terminal_id)?
        .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} has no public resource id"))?;
    let content_id = ContentPublicId::Terminal(public_id.clone());
    let topology = registry.resource_topology_snapshot()?;
    let tab_ids = topology
        .tabs
        .iter()
        .filter(|tab| tab.content_id == content_id)
        .map(|tab| tab.public_id.clone())
        .collect::<Vec<_>>();
    let surface = state.surface_by_content_public_id(&content_id);
    let (cols, rows) = surface.map(|surface| surface.size()).unwrap_or((80, 24));
    let mut snapshot = serde_json::json!({
        "id": public_id,
        "tab_id": tab_ids.first(),
        "tab_ids": tab_ids,
        "title": surface.map(|surface| surface.title()).unwrap_or_default(),
        "cols": cols.max(1),
        "rows": rows.max(1),
        "running": false,
    });
    if let Some(cwd) = surface.and_then(|surface| surface.published_directory()) {
        snapshot["cwd"] = serde_json::json!(cwd);
    }
    Ok(snapshot)
}
