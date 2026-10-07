//! Where a new terminal starts (NEW-TERMINAL-INHERITS-CWD): one resolver for
//! every entry point that creates a terminal without an explicit folder (new
//! tab, split, new pane, Cmd-T, the palette, the CLI without `--cwd`, MCP).
//!
//! Order, first hit wins:
//! 1. the caller's explicit folder;
//! 2. the source terminal's current folder: its shell's OSC 7 report (for
//!    this host), else the cwd of its foreground process, else its launch
//!    folder. The source is the target pane's selected tab, or for a
//!    workspace-level create the workspace's active pane;
//! 3. the workspace folder the user chose (`workspace.agent_folder.set`);
//! 4. the current folder of the most recently focused other terminal of the
//!    workspace;
//! 5. none: the host's default (the user's home folder).
//!
//! `inherit = false` (Ghostty `window-/tab-/split-inherit-working-directory`
//! = false, sent by the creating client as `inherit_cwd`) skips steps 2 and
//! 4; the workspace folder stays, as it is the workspace's own setting.
//!
//! The resolver runs on the host that runs the terminal, so a remote or
//! Cloud host resolves its own folders: a path never crosses hosts.

use std::path::Path;

use super::*;

/// The request field that turns inheritance off (absent = inherit).
pub(crate) const INHERIT_CWD_FIELD: &str = "inherit_cwd";

/// What a new terminal is created from.
#[derive(Clone, Copy, Debug)]
pub(crate) enum NewTerminalSource {
    /// A new tab, split or pane next to this pane.
    Pane(PaneId),
    /// A terminal created at workspace level (its active pane is the source).
    Workspace(WorkspaceId),
}

/// The `inherit_cwd` field of a creation request; absent or invalid = true
/// (the schema validates the type before the effect runs).
pub(crate) fn inherit_cwd_field(fields: &Map<String, Value>) -> bool {
    fields.get(INHERIT_CWD_FIELD).and_then(Value::as_bool).unwrap_or(true)
}

/// `inherit_cwd` of a stored topology intent.
pub(crate) fn intent_inherits_cwd(intent: &Value) -> bool {
    intent["fields"].as_object().is_none_or(inherit_cwd_field)
}

impl Mux {
    /// The folder a new terminal starts in; `None` = the host's default.
    pub(crate) fn resolve_new_terminal_cwd(
        &self,
        explicit: Option<String>,
        source: NewTerminalSource,
        inherit: bool,
    ) -> Option<String> {
        if explicit.is_some() {
            return explicit;
        }
        let candidates = self.with_state(|state| new_terminal_candidates(state, source))?;
        if inherit && let Some(cwd) = candidates.source.as_deref().and_then(terminal_current_folder)
        {
            return Some(cwd);
        }
        if let Some(folder) = self.workspace_folder(&candidates.workspace_public_id) {
            return Some(folder);
        }
        if inherit {
            return candidates.recent.iter().find_map(|surface| terminal_current_folder(surface));
        }
        None
    }

    /// The folder of a terminal a stored topology intent creates beside `target`.
    pub(crate) fn effect_pane_cwd(
        &self,
        explicit: Option<String>,
        target: PaneId,
        intent: &Value,
    ) -> Option<String> {
        let inherit = intent_inherits_cwd(intent);
        self.resolve_new_terminal_cwd(explicit, NewTerminalSource::Pane(target), inherit)
    }

    /// The folder of a workspace-level create. An inheriting create resolves
    /// later, under the workspace lifecycle lock (so a concurrent create into
    /// an empty workspace sees the first terminal); `inherit_cwd = false`
    /// resolves now and names the host default, so nothing inherits later.
    pub(crate) fn effect_workspace_cwd(
        &self,
        explicit: Option<String>,
        workspace: WorkspaceId,
        intent: &Value,
    ) -> Option<String> {
        if intent_inherits_cwd(intent) {
            return explicit;
        }
        self.resolve_new_terminal_cwd(explicit, NewTerminalSource::Workspace(workspace), false)
            .or_else(crate::platform::default_terminal_cwd)
    }

    /// The folder the user chose for the workspace, when it still exists.
    fn workspace_folder(&self, workspace_public_id: &Option<String>) -> Option<String> {
        let id = workspace_public_id.as_deref()?;
        let folder = self
            .workspace_registry
            .lock()
            .unwrap()
            .read_state(|connection| crate::state::agent_folder::agent_folder(connection, id))
            .ok()
            .flatten()?;
        Path::new(&folder).is_dir().then_some(folder)
    }
}

struct NewTerminalCandidates {
    workspace_public_id: Option<String>,
    /// The source pane's selected surface.
    source: Option<Arc<Surface>>,
    /// The workspace's other panes' selected surfaces, most recently focused first.
    recent: Vec<Arc<Surface>>,
}

fn new_terminal_candidates(
    state: &State,
    source: NewTerminalSource,
) -> Option<NewTerminalCandidates> {
    let (workspace, source_pane) = match source {
        NewTerminalSource::Pane(pane) => {
            let (workspace, _) = state.screen_of(pane)?;
            (&state.workspaces[workspace], Some(pane))
        }
        NewTerminalSource::Workspace(id) => {
            let workspace = state.workspace_by_id(id)?;
            (workspace, workspace.active_screen_ref().map(|screen| screen.active_pane))
        }
    };
    let selected = |pane: PaneId| {
        let pane = state.panes.get(&pane)?;
        state.surfaces.get(&pane.active_surface()?).cloned().map(|surface| (pane, surface))
    };
    let mut others = workspace
        .screens
        .iter()
        .flat_map(|screen| screen.root.pane_ids_vec())
        .filter(|pane| Some(*pane) != source_pane)
        .filter_map(selected)
        .collect::<Vec<_>>();
    others.sort_by_key(|(pane, _)| std::cmp::Reverse((pane.focused_at, pane.active_at)));
    Some(NewTerminalCandidates {
        workspace_public_id: state
            .resource_indexes
            .workspace_ids
            .get(&workspace.id)
            .map(ToString::to_string),
        source: source_pane.and_then(selected).map(|(_, surface)| surface),
        recent: others.into_iter().map(|(_, surface)| surface).collect(),
    })
}

/// A terminal's current folder on this host: its OSC 7 report, else its
/// foreground process's cwd, else its launch folder. Only an existing folder.
fn terminal_current_folder(surface: &Surface) -> Option<String> {
    if !matches!(surface, Surface::Pty(_)) {
        return None;
    }
    let foreground = surface.process_id().and_then(crate::platform::foreground_cwd);
    pick_terminal_folder(
        surface.reported_local_cwd(),
        foreground,
        surface.launch_local_cwd(),
        |path| Path::new(path).is_dir(),
        |path| std::fs::canonicalize(path).ok().map(|path| path.to_string_lossy().into_owned()),
    )
}

/// The first existing folder of `reported`, `foreground` and `launch`. The
/// kernel reports the foreground cwd as a physical path; when it names the
/// launch folder, the launch folder's spelling (a symlinked path) is kept.
fn pick_terminal_folder(
    reported: Option<String>,
    foreground: Option<String>,
    launch: Option<String>,
    is_dir: impl Fn(&str) -> bool,
    canonical: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    let foreground = foreground.map(|cwd| match &launch {
        Some(launch) if canonical(launch).as_deref() == Some(cwd.as_str()) => launch.clone(),
        _ => cwd,
    });
    [reported, foreground, launch].into_iter().flatten().find(|folder| is_dir(folder))
}

#[cfg(test)]
mod tests {
    use super::pick_terminal_folder;

    fn pick(
        reported: Option<&str>,
        foreground: Option<&str>,
        launch: Option<&str>,
    ) -> Option<String> {
        let existing = ["/work/app", "/work/lib", "/private/tmp", "/tmp"];
        pick_terminal_folder(
            reported.map(Into::into),
            foreground.map(Into::into),
            launch.map(Into::into),
            |path| existing.contains(&path),
            |path| Some(if path == "/tmp" { "/private/tmp".into() } else { path.into() }),
        )
    }

    #[test]
    fn the_osc7_report_comes_first() {
        assert_eq!(
            pick(Some("/work/app"), Some("/work/lib"), Some("/tmp")).as_deref(),
            Some("/work/app")
        );
    }

    #[test]
    fn without_a_report_the_foreground_process_folder_beats_the_launch_folder() {
        // A shell without shell integration that ran `cd /work/lib`.
        assert_eq!(pick(None, Some("/work/lib"), Some("/tmp")).as_deref(), Some("/work/lib"));
    }

    #[test]
    fn a_foreground_folder_equal_to_the_launch_folder_keeps_the_launch_spelling() {
        assert_eq!(pick(None, Some("/private/tmp"), Some("/tmp")).as_deref(), Some("/tmp"));
    }

    #[test]
    fn a_vanished_folder_is_skipped() {
        assert_eq!(pick(Some("/gone"), None, Some("/work/app")).as_deref(), Some("/work/app"));
        assert_eq!(pick(None, None, Some("/gone")), None);
    }
}
