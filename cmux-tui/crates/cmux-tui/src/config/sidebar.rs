//! Sidebar config: profiles, views, columns, resource levels, actions, plus buttons and the machine sidebar.

use super::*;

/// Sidebar behavior.
#[derive(Debug, Clone)]
pub struct Sidebar {
    /// Built-in view used when `plugin` is unset. The default is the file browser.
    pub view: SidebarView,
    pub width: u16,
    pub compact_width: u16,
    pub max_width: u16,
    /// Ordered native columns. The legacy width fields remain the defaults for
    /// machine/workspace columns when this list is omitted from the config.
    pub columns: Vec<SidebarColumn>,
    pub columns_explicit: bool,
    /// Ordered native projections. A one-level projection uses the existing
    /// list behavior; multiple levels render as one native tree column.
    pub views: Vec<SidebarViewSpec>,
    pub views_explicit: bool,
    /// Named native layouts. `views` is always the currently selected
    /// profile's resolved rail list so older consumers remain compatible.
    pub profiles: Vec<SidebarProfileSpec>,
    pub active_profile: String,
    pub plugin: Option<SidebarPluginOptions>,
    /// Rows per rail entry: 2 keeps the subtitle line, 1 is name-only.
    pub row_height: u16,
    /// Blank rows between rail entries.
    pub row_gap: u16,
    /// Accent glyph on active rail rows; empty removes it.
    pub rail_glyph: String,
    /// Workspace row label template with `{index}` and `{name}`.
    pub workspace_label: String,
}

/// Background agent integrations. The process is optional and runs outside
/// the core detector. Its events enter through the journal producer API.
#[derive(Debug, Clone, Default)]
pub struct Agents {
    pub plugin: Option<cmux_tui_core::JournalPluginOptions>,
}

impl Default for Sidebar {
    fn default() -> Self {
        let views = vec![
            SidebarViewSpec::legacy(SidebarColumnKind::Machines, 22, 0),
            SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 22, 0),
        ];
        Sidebar {
            view: SidebarView::Workspaces,
            width: 22,
            compact_width: 10,
            max_width: 0,
            columns: vec![
                SidebarColumn { kind: SidebarColumnKind::Machines, width: 22, max_width: 0 },
                SidebarColumn { kind: SidebarColumnKind::Workspaces, width: 22, max_width: 0 },
            ],
            columns_explicit: false,
            views: views.clone(),
            views_explicit: false,
            profiles: vec![SidebarProfileSpec {
                id: "default".to_string(),
                name: "Default".to_string(),
                views,
            }],
            active_profile: "default".to_string(),
            plugin: None,
            row_height: 2,
            row_gap: 1,
            rail_glyph: "\u{258e}".to_string(),
            workspace_label: "{name}".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarProfileSpec {
    pub id: String,
    pub name: String,
    pub views: Vec<SidebarViewSpec>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SidebarColumnKind {
    Machines,
    Workspaces,
    Tabs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SidebarColumn {
    pub kind: SidebarColumnKind,
    pub width: u16,
    pub max_width: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SidebarResourceKind {
    Machines,
    Workspaces,
    Panes,
    Tabs,
    Agents,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarViewSpec {
    pub id: String,
    pub levels: Vec<SidebarResourceKind>,
    /// Canonical native commands pinned to this view, with optional
    /// user-facing button labels.
    pub actions: Vec<SidebarActionSpec>,
    /// Whether the pinned actions render above or below the resource rows.
    pub actions_position: ActionsPosition,
    pub width: u16,
    pub max_width: u16,
    /// Lower values collapse first when pane space becomes constrained.
    pub collapse_priority: u16,
}

/// One pinned sidebar action and its optional label override.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarActionSpec {
    pub action: Action,
    pub label: Option<String>,
}

impl SidebarActionSpec {
    pub fn plain(action: Action) -> Self {
        Self { action, label: None }
    }
}

/// A configurable `+` button: its rendered label, an optional left-click
/// action override, and an optional right-click menu of actions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlusButton {
    pub label: String,
    pub action: Option<Action>,
    pub menu: Vec<SidebarActionSpec>,
}

impl Default for PlusButton {
    fn default() -> Self {
        Self { label: " + ".to_string(), action: None, menu: Vec::new() }
    }
}

pub(super) fn resolve_plus_button(
    raw: RawPlusButton,
    command_ids: &[String],
    owner: &str,
) -> PlusButton {
    let mut plus = PlusButton::default();
    if let Some(label) = raw.label {
        // Keep at least one visible cell so the button stays clickable.
        if !label.trim().is_empty() {
            plus.label = label;
        }
    }
    if let Some(action) = raw.action.as_deref() {
        match parse_sidebar_action(action.trim(), command_ids) {
            Ok(action) => plus.action = Some(action),
            Err(warning) => {
                crate::client_log::stderr_log!("config", "{warning} in {owner} plus button");
            }
        }
    }
    if let Some(menu) = raw.menu {
        let mut seen = HashSet::new();
        for raw_action in &menu {
            match parse_sidebar_action(raw_action.action().trim(), command_ids) {
                Ok(action) if seen.insert(action) => plus.menu.push(SidebarActionSpec {
                    action,
                    label: raw_action
                        .label()
                        .map(str::trim)
                        .filter(|label| !label.is_empty())
                        .map(str::to_string),
                }),
                Ok(_) => crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring duplicate {owner} plus menu action {:?}",
                    raw_action.action().trim()
                ),
                Err(warning) => {
                    crate::client_log::stderr_log!("config", "{warning} in {owner} plus menu");
                }
            }
        }
    }
    plus
}

impl SidebarViewSpec {
    pub fn legacy(kind: SidebarColumnKind, width: u16, max_width: u16) -> Self {
        let (id, level, collapse_priority) = match kind {
            SidebarColumnKind::Machines => ("machines", SidebarResourceKind::Machines, 10),
            SidebarColumnKind::Workspaces => ("workspaces", SidebarResourceKind::Workspaces, 30),
            SidebarColumnKind::Tabs => ("tabs", SidebarResourceKind::Tabs, 20),
        };
        let levels = vec![level];
        let actions = default_sidebar_actions(&levels);
        Self {
            id: id.to_string(),
            levels,
            actions,
            actions_position: ActionsPosition::Bottom,
            width,
            max_width,
            collapse_priority,
        }
    }

    pub fn legacy_kind(&self) -> Option<SidebarColumnKind> {
        match self.levels.as_slice() {
            [SidebarResourceKind::Machines] => Some(SidebarColumnKind::Machines),
            [SidebarResourceKind::Workspaces] => Some(SidebarColumnKind::Workspaces),
            [SidebarResourceKind::Tabs] if self.actions.is_empty() => Some(SidebarColumnKind::Tabs),
            _ => None,
        }
    }

    pub fn includes(&self, kind: SidebarResourceKind) -> bool {
        self.levels.contains(&kind)
    }
}

/// Optional client-local rail listing connection targets. It is disabled for
/// ordinary local cmux sessions and enabled by a machine provider or config.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineSidebar {
    pub enabled: bool,
    pub width: u16,
    pub max_width: u16,
    /// Session-local prototype sources. They exercise the native provider
    /// picker without starting containers or consuming cloud resources.
    pub create_sources: Vec<MachineCreationSourceConfig>,
}

impl Default for MachineSidebar {
    fn default() -> Self {
        Self { enabled: false, width: 22, max_width: 0, create_sources: Vec::new() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SidebarView {
    #[default]
    Files,
    Workspaces,
}

impl SidebarView {
    pub fn toggled(self) -> Self {
        match self {
            Self::Files => Self::Workspaces,
            Self::Workspaces => Self::Files,
        }
    }
}

pub(super) fn parse_sidebar_view(value: &str) -> Result<SidebarView, String> {
    match value {
        "files" => Ok(SidebarView::Files),
        "workspaces" => Ok(SidebarView::Workspaces),
        _ => Err(format!(
            "{BIN}: ignoring unknown sidebar.view {value:?}; expected \"files\" or \"workspaces\""
        )),
    }
}

pub(super) fn parse_sidebar_column_kind(value: &str) -> Result<SidebarColumnKind, String> {
    match value {
        "machines" => Ok(SidebarColumnKind::Machines),
        "workspaces" => Ok(SidebarColumnKind::Workspaces),
        "tabs" => Ok(SidebarColumnKind::Tabs),
        _ => Err(format!(
            "{BIN}: ignoring unknown sidebar column {value:?}; expected \"machines\", \"workspaces\", or \"tabs\""
        )),
    }
}

pub(super) fn parse_sidebar_resource_kind(value: &str) -> Result<SidebarResourceKind, String> {
    match value {
        "machines" => Ok(SidebarResourceKind::Machines),
        "workspaces" => Ok(SidebarResourceKind::Workspaces),
        "panes" => Ok(SidebarResourceKind::Panes),
        "tabs" => Ok(SidebarResourceKind::Tabs),
        "agents" => Ok(SidebarResourceKind::Agents),
        _ => Err(format!(
            "{BIN}: ignoring unknown sidebar resource {value:?}; expected \"machines\", \"workspaces\", \"panes\", \"tabs\", or \"agents\""
        )),
    }
}

pub(super) fn validate_sidebar_levels(levels: &[SidebarResourceKind]) -> Result<(), &'static str> {
    if levels.is_empty() {
        return Err("levels cannot be empty");
    }
    if levels.len() > 3 {
        return Err("at most three resource levels are supported");
    }
    let mut seen = HashSet::new();
    if levels.iter().any(|level| !seen.insert(*level)) {
        return Err("resource levels cannot repeat");
    }
    if levels.contains(&SidebarResourceKind::Machines) {
        return (levels == [SidebarResourceKind::Machines])
            .then_some(())
            .ok_or("machines must be a one-level view");
    }
    if let Some(index) = levels.iter().position(|level| *level == SidebarResourceKind::Workspaces)
        && index != 0
    {
        return Err("workspaces must be the first level");
    }
    if let Some(index) = levels.iter().position(|level| *level == SidebarResourceKind::Panes)
        && index > 1
    {
        return Err("panes must be first or directly below workspaces");
    }
    for leaf in [SidebarResourceKind::Tabs, SidebarResourceKind::Agents] {
        if let Some(index) = levels.iter().position(|level| *level == leaf)
            && index + 1 != levels.len()
        {
            return Err("tabs and agents must be the final level");
        }
    }
    Ok(())
}

pub(super) fn default_sidebar_collapse_priority(levels: &[SidebarResourceKind]) -> u16 {
    match levels {
        [SidebarResourceKind::Machines] => 10,
        [SidebarResourceKind::Workspaces] => 30,
        _ => 20,
    }
}

pub(super) fn default_sidebar_actions(levels: &[SidebarResourceKind]) -> Vec<SidebarActionSpec> {
    if levels.first() == Some(&SidebarResourceKind::Workspaces) {
        vec![SidebarActionSpec::plain(Action::NewWorkspace)]
    } else {
        Vec::new()
    }
}

/// Parse one pinned action name: an action catalog key, or `command:<id>`
/// referencing a user command from the top-level `commands` section.
pub(super) fn parse_sidebar_action(value: &str, command_ids: &[String]) -> Result<Action, String> {
    if let Some(command_id) = value.strip_prefix("command:") {
        return command_ids
            .iter()
            .position(|id| id == command_id)
            .and_then(Action::user_command)
            .ok_or_else(|| {
                format!("{BIN}: ignoring sidebar action for unknown command {command_id:?}")
            });
    }
    action_definitions()
        .iter()
        .find(|definition| definition.config_key == value)
        .map(|definition| definition.action)
        .ok_or_else(|| format!("{BIN}: ignoring unknown sidebar action {value:?}"))
}

pub(super) fn resolve_sidebar_view_specs(
    views: &[RawSidebarView],
    machine_width: u16,
    machine_max_width: u16,
    workspace_width: u16,
    workspace_max_width: u16,
    owner: &str,
    command_ids: &[String],
) -> Vec<SidebarViewSpec> {
    let mut ids = HashSet::new();
    let mut legacy_kinds = HashSet::new();
    let mut resolved = Vec::new();
    for view in views {
        let id = view.id.trim();
        if id.is_empty() || ids.contains(id) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring {owner} view with an empty or duplicate id"
            );
            continue;
        }
        let mut levels = Vec::with_capacity(view.levels.len());
        let mut valid = true;
        for level in &view.levels {
            match parse_sidebar_resource_kind(level.trim()) {
                Ok(level) => levels.push(level),
                Err(warning) => {
                    crate::client_log::stderr_log!("config", "{warning}");
                    valid = false;
                    break;
                }
            }
        }
        if !valid {
            continue;
        }
        if let Err(reason) = validate_sidebar_levels(&levels) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring {owner} view {id:?}: {reason}"
            );
            continue;
        }
        let legacy_kind = SidebarViewSpec {
            id: id.to_string(),
            levels: levels.clone(),
            actions: Vec::new(),
            actions_position: ActionsPosition::Bottom,
            width: 0,
            max_width: 0,
            collapse_priority: 0,
        }
        .legacy_kind();
        if legacy_kind.is_some_and(|kind| !legacy_kinds.insert(kind)) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring {owner} view {id:?}: a one-level view for that resource already exists"
            );
            continue;
        }
        ids.insert(id.to_string());
        let (default_width, default_max_width) = match legacy_kind {
            Some(SidebarColumnKind::Machines) => (machine_width, machine_max_width),
            Some(SidebarColumnKind::Workspaces) => (workspace_width, workspace_max_width),
            Some(SidebarColumnKind::Tabs) | None => (22, 0),
        };
        let actions = if levels == [SidebarResourceKind::Machines]
            && view.actions.as_ref().is_some_and(|actions| !actions.is_empty())
        {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring sidebar actions in {owner} machine view {id:?}; machine actions come from provider capabilities"
            );
            Vec::new()
        } else if let Some(raw_actions) = view.actions.as_ref() {
            let mut seen = HashSet::new();
            raw_actions
                .iter()
                .filter_map(|raw_action| {
                    match parse_sidebar_action(raw_action.action().trim(), command_ids) {
                        Ok(action) if seen.insert(action) => Some(SidebarActionSpec {
                            action,
                            label: raw_action
                                .label()
                                .map(str::trim)
                                .filter(|label| !label.is_empty())
                                .map(str::to_string),
                        }),
                        Ok(_) => {
                            crate::client_log::stderr_log!("config",
                                "{BIN}: ignoring duplicate sidebar action {:?} in {owner} view {id:?}",
                                raw_action.action().trim()
                            );
                            None
                        }
                        Err(warning) => {
                            crate::client_log::stderr_log!("config", "{warning} in {owner} view {id:?}");
                            None
                        }
                    }
                })
                .collect()
        } else {
            default_sidebar_actions(&levels)
        };
        resolved.push(SidebarViewSpec {
            id: id.to_string(),
            collapse_priority: view
                .collapse_priority
                .unwrap_or_else(|| default_sidebar_collapse_priority(&levels)),
            levels,
            actions,
            actions_position: view.actions_position.unwrap_or_default(),
            width: view.width.unwrap_or(default_width).clamp(10, 60),
            max_width: view.max_width.unwrap_or(default_max_width),
        });
    }
    resolved
}
