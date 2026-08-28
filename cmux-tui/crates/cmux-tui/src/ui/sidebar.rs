//! Left sidebar renderer for the built-in files/workspaces views and the
//! external plugin PTY. Owns its full column including the status-bar row
//! (the status bar starts after the sidebar) and rebuilds the click hit map
//! as it draws.

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};
use std::borrow::Cow;

use super::{
    ScrollbarState, ScrollbarStyle, middle_truncate, rail, truncate, viewport_thumb_geometry,
};
use crate::app::{App, Hit, RailKind, WorkspaceRailSelection};
use crate::config::{SidebarResourceKind, SidebarView};
use crate::localization;
use crate::machine::{MachineRailSelection, MachineStatus};

fn projection_empty_label(resource: SidebarResourceKind) -> &'static str {
    let messages = &localization::catalog().sidebar;
    match resource {
        SidebarResourceKind::Machines => messages.no_machines,
        SidebarResourceKind::Workspaces => messages.no_workspaces,
        SidebarResourceKind::Panes => messages.no_panes,
        SidebarResourceKind::Tabs => messages.no_tabs,
        SidebarResourceKind::Agents => messages.no_agents,
    }
}

fn projection_detail<'a>(row: &'a crate::sidebar_projection::ProjectionRow) -> Cow<'a, str> {
    let Some(state) = row.agent_state.as_deref() else { return Cow::Borrowed(&row.subtitle) };
    let messages = &localization::catalog().sidebar;
    let state = match state {
        "working" => messages.working,
        "blocked" => messages.blocked,
        "idle" => messages.idle,
        "done" => messages.done,
        _ => messages.unknown,
    };
    // Lead with the agent type when the row name is the tab title, so
    // "which agent is this" never depends on the title alone. Skip it when
    // the name already IS the agent type (untitled tab fallback).
    let mut detail = match row.agent_label.as_deref() {
        Some(agent) if row.name != agent => format!("{agent} · {state}"),
        _ => state.to_string(),
    };
    if !row.subtitle.is_empty() {
        detail = format!("{detail} · {}", row.subtitle);
    }
    detail.into()
}

/// The color of a workspace's unread indicator, or `None` when nothing is
/// unread. Mirrors the tab-bar severity cue (`error` > `warning` > `info`)
/// so the sidebar dot carries the same meaning as the per-tab marker.
fn workspace_unread_color(
    theme: &crate::config::Theme,
    ws: &crate::session::WorkspaceView,
) -> Option<Color> {
    ws.screens
        .iter()
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .filter_map(|tab| tab.notification.filter(|notification| notification.unread))
        .map(|notification| match notification.level {
            "error" => (2u8, theme.notification_error),
            "warning" => (1, theme.notification_warning),
            _ => (0, theme.notification_info),
        })
        .max_by_key(|(rank, _)| *rank)
        .map(|(_, color)| color)
}

pub fn draw(app: &mut App, frame: &mut Frame) -> Option<(u16, u16)> {
    app.workspace_sidebar_area(frame.area().height)?;
    if app.config.sidebar.plugin.is_some() {
        draw_plugin(app, frame);
        return None;
    }
    match app.sidebar_view {
        SidebarView::Files => draw_files(app, frame),
        SidebarView::Workspaces => {
            draw_workspaces(app, frame);
            None
        }
    }
}

pub fn draw_machines(app: &mut App, frame: &mut Frame) {
    let Some(area) = app.machine_sidebar_area(frame.area().height) else { return };
    let Some(machine_ui) = app.machine_ui.as_ref() else { return };
    let machines = machine_ui.snapshot.machines.clone();
    let active = app.selected_machine();
    let capabilities = machine_ui.snapshot.capabilities;
    let selection = machine_ui.selection;
    let managed_machines = machine_ui.managed_machines().to_vec();
    let rail_selection = machine_ui.rail_selection;
    let palette = rail::RailPalette::for_app(app, app.machine_sidebar_focused());
    let metrics = rail::RailMetrics::for_app(app);
    let messages = &localization::catalog().sidebar;
    rail::prepare(frame, area, palette);

    let mut body_rows = 0;
    let machine_start = body_rows;
    if machines.is_empty() {
        body_rows += 1;
    } else {
        body_rows += machines.len() * metrics.stride;
    }
    let create_footer = capabilities.create.then_some(0);
    let connect_footer = capabilities.connect.then_some(usize::from(capabilities.create));
    let footer_rows = usize::from(capabilities.create) + usize::from(capabilities.connect);
    let selected_body = if app.machine_sidebar_focused() && app.machine_rail_follow_selection {
        match rail_selection {
            MachineRailSelection::Machine => (!machines.is_empty()).then_some(rail::RowSpan::new(
                machine_start + selection * metrics.stride,
                metrics.height,
            )),
            MachineRailSelection::NewVm | MachineRailSelection::ConnectMachine => None,
        }
    } else {
        None
    };
    let selected_footer = if app.machine_sidebar_focused() && app.machine_rail_follow_selection {
        match rail_selection {
            MachineRailSelection::NewVm => create_footer.map(|row| rail::RowSpan::new(row, 1)),
            MachineRailSelection::ConnectMachine => {
                connect_footer.map(|row| rail::RowSpan::new(row, 1))
            }
            _ => None,
        }
    } else {
        None
    };
    let viewport = rail::viewport(
        area,
        body_rows,
        footer_rows,
        &mut app.machine_rail_scroll,
        &mut app.machine_footer_scroll,
        selected_body,
        selected_footer,
    );

    let mut hits = Vec::new();
    if machines.is_empty()
        && let Some(y) = viewport.body_y(rail::RowSpan::new(machine_start, 1))
    {
        frame.buffer_mut().set_stringn(
            area.x + 1,
            y,
            messages.no_machines,
            area.width.saturating_sub(2) as usize,
            palette.dim,
        );
    }
    for (index, machine) in machines.iter().enumerate() {
        let span = rail::RowSpan::new(machine_start + index * metrics.stride, metrics.height);
        let Some(y) = viewport.body_y(span) else { continue };
        let is_active = Some(machine.key) == active;
        let focused = app.machine_sidebar_focused()
            && rail_selection == MachineRailSelection::Machine
            && selection == index;
        let managed = managed_machines.iter().find(|managed| managed.key == machine.key);
        let recoverable = managed.is_some_and(|managed| {
            managed.status == crate::machine::ManagedMachineStatus::Recoverable
        });
        let connection_phase = machine_ui.connection_phase(machine.key);
        let status = match connection_phase {
            crate::machine::MachineConnectionPhase::Connecting => messages.connecting,
            crate::machine::MachineConnectionPhase::Failed => messages.unavailable,
            crate::machine::MachineConnectionPhase::Disconnected
            | crate::machine::MachineConnectionPhase::Ready => match machine.status {
                MachineStatus::Running => messages.running,
                MachineStatus::Connecting => messages.connecting,
                MachineStatus::Sleeping => messages.sleeping,
                MachineStatus::Stopped => messages.stopped,
                MachineStatus::Unavailable => messages.unavailable,
            },
        };
        let recoverable_subtitle = recoverable.then(|| {
            managed.and_then(|managed| managed.recoverable_until.as_ref()).map_or_else(
                || messages.recoverable_machine.to_string(),
                |until| format!("{} · {until}", messages.recoverable_machine),
            )
        });
        let subtitle = recoverable_subtitle.as_deref().unwrap_or_else(|| {
            if machine.subtitle.is_empty() { status } else { &machine.subtitle }
        });
        let indicator = if recoverable {
            Some(app.config.theme.notification_warning)
        } else {
            match connection_phase {
                crate::machine::MachineConnectionPhase::Connecting => {
                    Some(app.config.theme.notification_warning)
                }
                crate::machine::MachineConnectionPhase::Failed => {
                    Some(app.config.theme.notification_error)
                }
                crate::machine::MachineConnectionPhase::Ready
                | crate::machine::MachineConnectionPhase::Disconnected => match machine.status {
                    MachineStatus::Running => Some(app.config.theme.notification_info),
                    MachineStatus::Connecting | MachineStatus::Sleeping => {
                        Some(app.config.theme.notification_warning)
                    }
                    MachineStatus::Stopped => None,
                    MachineStatus::Unavailable => Some(app.config.theme.notification_error),
                },
            }
        };
        rail::entry(
            frame,
            area,
            y,
            rail::Entry {
                name: &machine.name,
                subtitle,
                highlighted: is_active || focused,
                active: is_active,
                indicator,
                dimmed: recoverable,
            },
            palette,
            metrics,
        );
        hits.push((rail::row(area, y), Hit::Machine { index, key: machine.key }));
        if metrics.height >= 2 {
            hits.push((rail::row(area, y + 1), Hit::Machine { index, key: machine.key }));
        }
    }

    if let Some(y) = create_footer.and_then(|row| viewport.footer_y(rail::RowSpan::new(row, 1))) {
        rail::action(
            frame,
            area,
            y,
            messages.new_machine,
            app.machine_sidebar_focused() && rail_selection == MachineRailSelection::NewVm,
            palette,
        );
        hits.push((rail::row(area, y), Hit::NewVm));
    }
    if let Some(y) = connect_footer.and_then(|row| viewport.footer_y(rail::RowSpan::new(row, 1))) {
        rail::action(
            frame,
            area,
            y,
            messages.connect_machine,
            app.machine_sidebar_focused() && rail_selection == MachineRailSelection::ConnectMachine,
            palette,
        );
        hits.push((rail::row(area, y), Hit::ConnectMachine));
    }
    hits.push((rail::row(area, area.y), Hit::RailPad(RailKind::Machine)));
    hits.push((rail::divider(area), Hit::RailResize(RailKind::Machine)));
    app.hits.extend(hits);
}

/// Native third-level column for tabs in the highlighted workspace.
pub fn draw_tabs(app: &mut App, frame: &mut Frame) {
    let Some(area) = app.tabs_sidebar_area(frame.area().height) else { return };
    let targets = app.sidebar_tab_targets();
    app.tabs_rail_selection = app.tabs_rail_selection.min(targets.len().saturating_sub(1));
    let palette = rail::RailPalette::for_app(app, app.tabs_sidebar_focused());
    let metrics = rail::RailMetrics::for_app(app);
    let messages = &localization::catalog().sidebar;
    rail::prepare(frame, area, palette);

    let body_rows = if targets.is_empty() { 1 } else { targets.len() * metrics.stride };
    let selected = (!targets.is_empty()
        && app.tabs_sidebar_focused()
        && app.tabs_rail_follow_selection)
        .then_some(rail::RowSpan::new(app.tabs_rail_selection * metrics.stride, metrics.height));
    let viewport = rail::viewport(
        area,
        body_rows,
        0,
        &mut app.tabs_rail_scroll,
        &mut app.tabs_footer_scroll,
        selected,
        None,
    );

    if targets.is_empty() {
        if let Some(y) = viewport.body_y(rail::RowSpan::new(0, 1)) {
            rail::button(frame, area, y, messages.no_tabs, false, palette);
        }
    } else {
        for (target_index, target) in targets.iter().enumerate() {
            let span = rail::RowSpan::new(target_index * metrics.stride, metrics.height);
            let Some(y) = viewport.body_y(span) else { continue };
            let selected = app.tabs_sidebar_focused()
                && app.tabs_rail_selection == target_index
                && app.tabs_rail_follow_selection;
            rail::entry(
                frame,
                area,
                y,
                rail::Entry {
                    name: &target.name,
                    subtitle: &target.subtitle,
                    highlighted: target.active || selected,
                    active: target.active,
                    indicator: None,
                    dimmed: false,
                },
                palette,
                metrics,
            );
            let hit = Hit::SidebarTab {
                workspace: target.workspace,
                screen: target.screen,
                pane: target.pane,
                index: target.index,
                surface: target.surface,
            };
            app.hits.push((rail::row(area, y), hit));
            if metrics.height >= 2 {
                app.hits.push((rail::row(area, y + 1), hit));
            }
        }
    }
    app.hits.push((rail::row(area, area.y), Hit::RailPad(RailKind::Tabs)));
    app.hits.push((rail::divider(area), Hit::RailResize(RailKind::Tabs)));
}

/// Render one configurable resource path as a dense native tree column.
pub fn draw_projection(app: &mut App, frame: &mut Frame, view_index: usize) {
    let Some(mut area) = app.projection_sidebar_area(view_index) else { return };
    let Some(spec) = app.config.sidebar.views.get(view_index).cloned() else { return };
    let rows = app.projection_rows(view_index);
    let actions = app.sidebar_action_rows(view_index);
    let focused = app.projection_sidebar_focused(view_index);
    let palette = rail::RailPalette::for_app(app, focused);
    rail::prepare(frame, area, palette);

    // Agents views carry a herdr-style header: the view title left, the
    // fixed sort mode right. It consumes the top line of the rail.
    let messages = &localization::catalog().sidebar;
    if spec.levels == [SidebarResourceKind::Agents] && area.height > 1 {
        rail::view_header(frame, area, area.y, messages.agents, messages.sort_priority, palette);
        area = Rect { y: area.y + 1, height: area.height - 1, ..area };
    }

    // Agent rows can span two terminal lines; every row's span is derived
    // from the same height table so scrolling and hits stay aligned.
    let two_line_agents = spec.row_lines >= 2;
    let row_height = |row: &crate::sidebar_projection::ProjectionRow| -> usize {
        if two_line_agents && row.agent_state.is_some() { 2 } else { 1 }
    };
    let mut row_spans = Vec::with_capacity(rows.len());
    let mut body_rows = 0usize;
    for row in rows.iter() {
        let height = row_height(row);
        row_spans.push(rail::RowSpan::new(body_rows, height));
        body_rows += height;
    }

    let selectable_rows = rows.len().saturating_add(actions.len());
    let (selected, viewport) = {
        let state = app.projection_rail_state_mut(view_index);
        state.selected = state.selected.min(rows.len().saturating_sub(1));
        state.selected_action = state
            .selected_action
            .map(|index| index.min(actions.len().saturating_sub(1)))
            .filter(|_| !actions.is_empty());
        let selected = state
            .selected_action
            .map(|index| rows.len().saturating_add(index))
            .unwrap_or_else(|| state.selected.min(selectable_rows.saturating_sub(1)));
        let selected_body = (focused
            && state.follow_selection
            && state.selected_action.is_none()
            && !rows.is_empty())
        .then(|| row_spans.get(state.selected).copied())
        .flatten();
        let selected_footer = (focused && state.follow_selection)
            .then_some(state.selected_action)
            .flatten()
            .map(|index| rail::RowSpan::new(index, 1));
        let viewport = rail::viewport(
            area,
            body_rows.max(usize::from(rows.is_empty())),
            actions.len(),
            &mut state.scroll,
            &mut state.footer_scroll,
            selected_body,
            selected_footer,
        );
        (selected, viewport)
    };
    if rows.is_empty()
        && let Some(y) = viewport.body_y(rail::RowSpan::new(0, 1))
    {
        let resource = spec.levels.last().copied().unwrap_or(SidebarResourceKind::Workspaces);
        rail::button(frame, area, y, projection_empty_label(resource), false, palette);
    }
    for (row_index, row) in rows.iter().enumerate() {
        let span = row_spans[row_index];
        let Some(y) = viewport.body_y(span) else { continue };
        let highlighted = row.active || (focused && selected == row_index);
        let two_line = span.height == 2;
        // Two-line agent rows read like herdr: the state glyph plus the
        // context line (tab title, else the session/workspace subtitle),
        // then the agent type dim underneath. Single-line rows keep the
        // combined detail text.
        let detail = if two_line {
            String::new()
        } else {
            projection_detail(row).into_owned()
        };
        let title = if two_line && row.agent_label.as_deref() == Some(row.name.as_str()) {
            row.subtitle.as_str()
        } else {
            row.name.as_str()
        };
        // The dim second line is the agent type; an agent the roster cannot
        // name yet (bare socket reports) falls back to its localized state.
        let second_line = row.agent_label.clone().or_else(|| {
            row.agent_state.as_deref().map(|state| {
                match state {
                    "working" => messages.working,
                    "blocked" => messages.blocked,
                    "idle" => messages.idle,
                    "done" => messages.done,
                    _ => messages.unknown,
                }
                .to_string()
            })
        });
        let indicator = row.agent_state.as_deref().and_then(|state| match state {
            "blocked" => Some(rail::TreeRowIndicator::Dot(app.config.theme.notification_error)),
            "working" => Some(rail::TreeRowIndicator::Dot(app.config.theme.notification_info)),
            "idle" => Some(rail::TreeRowIndicator::Circle),
            _ => None,
        });
        let disclosure = rail::tree_row(
            frame,
            area,
            y,
            rail::TreeRow {
                depth: row.depth,
                name: title,
                detail: &detail,
                second_line: two_line.then_some(second_line.as_deref().unwrap_or("")),
                branch: row.branch.map(|_| row.expanded),
                indicator,
                highlighted,
                active: row.active,
            },
            palette,
        );
        if let (Some(rect), Some(branch)) = (disclosure, row.branch) {
            app.hits.push((rect, Hit::ProjectionToggle { view: view_index, branch }));
        }
        let hit = Hit::ProjectionRow { view: view_index, row: row_index, target: row.target };
        app.hits.push((rail::row(area, y), hit));
        if two_line && y + 1 < area.y.saturating_add(area.height) {
            app.hits.push((rail::row(area, y + 1), hit));
        }
    }
    for (action_index, action) in actions.iter().enumerate() {
        let Some(y) = viewport.footer_y(rail::RowSpan::new(action_index, 1)) else { continue };
        rail::action(
            frame,
            area,
            y,
            &action.label,
            focused && selected == rows.len().saturating_add(action_index),
            palette,
        );
        app.hits.push((
            rail::row(area, y),
            Hit::SidebarAction { view: view_index, action: action.target },
        ));
    }
    app.hits.push((rail::row(area, area.y), Hit::RailPad(RailKind::Projection(view_index))));
    app.hits.push((rail::divider(area), Hit::RailResize(RailKind::Projection(view_index))));
}

/// Draw the horizontal rule of every vertical split divider and register
/// its drag handle. Horizontal splits need no extra drawing: their handle
/// is the left child's border column, rerouted at press time.
pub fn draw_split_dividers(app: &mut App, frame: &mut Frame) {
    if app.sidebar_layout.dividers.is_empty() {
        return;
    }
    let palette = rail::RailPalette::for_app(app, false);
    for divider in app.sidebar_layout.dividers.clone() {
        if divider.dir != crate::config::SidebarSplitDir::Vertical || divider.rect.width == 0 {
            continue;
        }
        {
            let buf = frame.buffer_mut();
            let y = divider.rect.y;
            let last = divider.rect.x + divider.rect.width - 1;
            for x in divider.rect.x..last {
                buf[(x, y)].set_symbol("─").set_style(palette.border);
            }
            // The rail border column stays continuous through the divider.
            buf[(last, y)].set_symbol(palette.border_symbol).set_style(palette.border);
        }
        app.hits.push((
            divider.rect,
            Hit::SidebarSplitDivider { group: divider.group, index: divider.index },
        ));
    }
}

fn draw_plugin(app: &mut App, frame: &mut Frame) {
    let Some(area) = app.workspace_sidebar_area(frame.area().height) else { return };
    let width = area.width;
    let height = area.height;
    if width < 3 || height == 0 {
        return;
    }
    let content = app.sidebar_plugin_rect();
    let border_x = area.x + width - 1;
    let palette = rail::RailPalette::for_app(app, app.workspace_sidebar_focused());
    {
        let buf = frame.buffer_mut();
        for y in area.y..area.y + height {
            buf[(border_x, y)].set_symbol(palette.border_symbol).set_style(palette.border);
        }
    }
    // The divider column is a drag handle exactly like the built-in sidebar's;
    // without this hit zone, drag-resize is dead whenever a plugin owns the
    // sidebar (the plugin rect stops one column short of the divider).
    app.hits.push((rail::divider(area), Hit::RailResize(RailKind::Workspace)));
    if let Some(surface_id) = app.sidebar_plugin_surface {
        let Some(surface) = app.session.surface(surface_id) else { return };
        surface.take_dirty();
        let theme = app.config.theme;
        let rs = app
            .render_states
            .entry(surface_id)
            .or_insert_with(|| ghostty_vt::RenderState::new().expect("render state alloc"));
        if let Ok(render) = surface.render_frame(rs) {
            let _ = super::terminal_grid::draw_render_frame(
                frame,
                content,
                &render,
                &theme,
                &app.chrome,
                |_, _| false,
            );
            {
                let buf = frame.buffer_mut();
                for y in area.y..area.y + height {
                    buf[(border_x, y)].set_symbol(palette.border_symbol).set_style(palette.border);
                }
            }
            return;
        }
    }
    let message = app.sidebar_plugin_error.as_deref().unwrap_or("sidebar plugin unavailable");
    let base = Style::default();
    let dim = base.fg(Color::Indexed(244));
    let buf = frame.buffer_mut();
    for y in content.y..content.y + content.height {
        for x in content.x..content.x + content.width {
            buf[(x, y)].set_symbol(" ").set_style(base);
        }
    }
    let text = truncate(message, content.width.saturating_sub(2) as usize);
    if content.width > 2 {
        buf.set_stringn(
            content.x + 1,
            content.y + content.height / 2,
            &text,
            content.width.saturating_sub(2) as usize,
            dim,
        );
    }
}

fn draw_workspaces(app: &mut App, frame: &mut Frame) {
    let Some(area) = app.workspace_sidebar_area(frame.area().height) else { return };
    let palette = rail::RailPalette::for_app(app, app.workspace_sidebar_focused());
    let metrics = rail::RailMetrics::for_app(app);
    let workspace_drag = app.workspace_drag();
    let messages = &localization::catalog().sidebar;
    rail::prepare(frame, area, palette);

    let actions = app.workspace_sidebar_action_rows();
    let view_index = app.view_index_for_rail(RailKind::Workspace);
    let recoverable = app
        .machine_ui
        .as_ref()
        .map(|ui| ui.recoverable_workspaces().into_iter().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let body_rows = (app.tree.workspaces.len() + recoverable.len()) * metrics.stride;
    let selected_body = (app.workspace_sidebar_focused() && app.workspace_rail_follow_selection)
        .then(|| match app.workspace_rail_selection {
            WorkspaceRailSelection::Workspace
                if app.sidebar_workspace_selection < app.tree.workspaces.len() =>
            {
                Some(rail::RowSpan::new(
                    app.sidebar_workspace_selection * metrics.stride,
                    metrics.height,
                ))
            }
            WorkspaceRailSelection::Recoverable
                if app.sidebar_recoverable_workspace_selection < recoverable.len() =>
            {
                Some(rail::RowSpan::new(
                    (app.tree.workspaces.len() + app.sidebar_recoverable_workspace_selection)
                        * metrics.stride,
                    metrics.height,
                ))
            }
            _ => None,
        })
        .flatten();
    let selected_footer = if app.workspace_sidebar_focused() && app.workspace_rail_follow_selection
    {
        actions
            .iter()
            .position(|action| app.workspace_rail_selection.matches_action(action.target))
            .map(|row| rail::RowSpan::new(row, 1))
    } else {
        None
    };
    let actions_position = app.workspace_actions_position();
    let viewport = rail::viewport_positioned(
        area,
        body_rows,
        actions.len(),
        &mut app.workspace_rail_scroll,
        &mut app.workspace_footer_scroll,
        selected_body,
        selected_footer,
        actions_position,
    );
    let mut hits = Vec::new();
    let scrollbar_track = if viewport.body.height > 0 && body_rows > viewport.body.height as usize {
        Rect {
            x: area.x + area.width.saturating_sub(2),
            y: viewport.body.y,
            width: 1,
            height: viewport.body.height,
        }
    } else {
        Rect::default()
    };
    if scrollbar_track.height > 0 {
        hits.push((
            scrollbar_track,
            Hit::WorkspaceScrollbar {
                track: scrollbar_track,
                total_rows: body_rows,
                visible_rows: viewport.body.height as usize,
            },
        ));
    }
    for (i, ws) in app.tree.workspaces.iter().enumerate() {
        let span = rail::RowSpan::new(i * metrics.stride, metrics.height);
        let Some(y) = viewport.body_y(span) else { continue };
        let active = i == app.tree.active_workspace;
        let focused_selection = app.workspace_sidebar_focused()
            && app.workspace_rail_selection == WorkspaceRailSelection::Workspace
            && i == app.sidebar_workspace_selection;
        let highlighted = active || focused_selection;
        let screen = ws.active_screen_ref();
        let pane = screen.and_then(|s| s.pane(s.active_pane));
        let title = pane.map(|p| p.display_name()).unwrap_or("shell");
        let screen_count = ws.screens.len();
        let subtitle = if screen_count > 1 {
            format!("{title} ({screen_count} screens)")
        } else {
            title.to_string()
        };
        let label = app.workspace_button_label(i, &ws.name);
        rail::entry(
            frame,
            area,
            y,
            rail::Entry {
                name: &label,
                subtitle: &subtitle,
                highlighted,
                active,
                indicator: workspace_unread_color(&app.config.theme, ws),
                dimmed: workspace_drag.is_some_and(|(id, _)| id == ws.id),
            },
            palette,
            metrics,
        );
        hits.push((rail::row(area, y), Hit::Workspace { index: i, id: ws.id }));
        if metrics.height >= 2 {
            hits.push((rail::row(area, y + 1), Hit::Workspace { index: i, id: ws.id }));
        }
    }

    for (index, workspace) in recoverable.iter().enumerate() {
        let row = app.tree.workspaces.len() + index;
        let span = rail::RowSpan::new(row * metrics.stride, metrics.height);
        let Some(y) = viewport.body_y(span) else { continue };
        let selected = app.workspace_sidebar_focused()
            && app.workspace_rail_selection == WorkspaceRailSelection::Recoverable
            && index == app.sidebar_recoverable_workspace_selection;
        let subtitle = workspace.recoverable_until.as_ref().map_or_else(
            || messages.recoverable_workspace.to_string(),
            |until| format!("{} · {until}", messages.recoverable_workspace),
        );
        rail::entry(
            frame,
            area,
            y,
            rail::Entry {
                name: &workspace.name,
                subtitle: &subtitle,
                highlighted: selected,
                active: false,
                indicator: None,
                dimmed: true,
            },
            palette,
            metrics,
        );
        hits.push((rail::row(area, y), Hit::RecoverableWorkspace { index }));
        if metrics.height >= 2 {
            hits.push((rail::row(area, y + 1), Hit::RecoverableWorkspace { index }));
        }
    }

    if let Some((_, Some(index))) = workspace_drag {
        let marker_row = index.saturating_mul(metrics.stride).saturating_sub(1);
        if let Some(marker_y) = viewport.body_y(rail::RowSpan::new(marker_row, 1)) {
            let buf = frame.buffer_mut();
            for x in area.x..area.x + area.width.saturating_sub(1) {
                buf[(x, marker_y)]
                    .set_symbol("─")
                    .set_style(Style::default().fg(app.config.theme.border_active));
            }
        }
    }

    for (row, action) in actions.iter().enumerate() {
        let Some(y) = viewport.footer_y(rail::RowSpan::new(row, 1)) else { continue };
        rail::action(
            frame,
            area,
            y,
            &action.label,
            app.workspace_sidebar_focused()
                && app.workspace_rail_selection.matches_action(action.target),
            palette,
        );
        match action.target {
            crate::app::SidebarActionTarget::CreateWorkspace(mode) => {
                hits.push((rail::row(area, y), Hit::CreateWorkspace { mode }));
            }
            crate::app::SidebarActionTarget::Run(_) => {
                if let Some(view) = view_index {
                    hits.push((
                        rail::row(area, y),
                        Hit::SidebarAction { view, action: action.target },
                    ));
                }
            }
        }
    }
    if scrollbar_track.height > 0 {
        let (thumb_y, thumb_height) = viewport_thumb_geometry(
            body_rows,
            viewport.body.height as usize,
            viewport.body_offset,
            scrollbar_track.height,
        );
        let expanded = app.hover.is_some_and(|(x, y)| scrollbar_track.contains(x, y))
            || app.dragging_workspace_scrollbar();
        let state = if expanded {
            ScrollbarState::Expanded
        } else if app.workspace_sidebar_focused() {
            ScrollbarState::Highlighted
        } else {
            ScrollbarState::Idle
        };
        ScrollbarStyle::from_chrome(app.chrome).draw_thumb(
            frame.buffer_mut(),
            scrollbar_track,
            (thumb_y, thumb_height),
            Style::default(),
            state,
        );
    }
    hits.push((rail::row(area, area.y), Hit::RailPad(RailKind::Workspace)));
    hits.push((rail::divider(area), Hit::RailResize(RailKind::Workspace)));
    app.hits.extend(hits);
}

fn draw_files(app: &mut App, frame: &mut Frame) -> Option<(u16, u16)> {
    let area = app.workspace_sidebar_area(frame.area().height)?;
    let width = area.width;
    let height = area.height;
    if width < 3 || height == 0 {
        return None;
    }
    let content_width = width - 1;
    let content_w = content_width as usize;
    let chrome = app.chrome;
    let base = Style::default();
    let dim = base.fg(chrome.sidebar_dim_fg);
    let selected_bg = if app.config.theme_overrides.sidebar_active_bg {
        app.config.theme.sidebar_active_bg
    } else {
        chrome.sidebar_selected_bg
    };
    let selected_style = Style::default()
        .bg(selected_bg)
        .fg(chrome.sidebar_selected_fg)
        .add_modifier(Modifier::BOLD);
    let focused = app.workspace_sidebar_focused();
    let border = base
        .fg(if focused { app.config.theme.border_active } else { chrome.sidebar_border })
        .add_modifier(if focused { Modifier::BOLD } else { Modifier::empty() });
    let border_symbol = if focused { "┃" } else { "│" };
    let header_style = if focused {
        Style::default()
            .bg(chrome.status_active_bg)
            .fg(app.config.theme.border_active)
            .add_modifier(Modifier::BOLD)
    } else {
        dim
    };

    let entries = app
        .sidebar_files
        .visible_entries()
        .map(|entry| (entry.name.clone(), entry.is_dir()))
        .collect::<Vec<_>>();
    let selected = app.sidebar_files.selected();
    let current_dir = app.sidebar_files.current_dir().to_string_lossy().into_owned();
    let pinned = app.sidebar_files.is_pinned();
    let filter_mode = app.sidebar_files.filter_mode();
    let filter_input = filter_mode
        .then(|| app.sidebar_files.visible_filter_text_and_cursor(content_w.saturating_sub(1)));
    let show_hidden = app.sidebar_files.show_hidden();
    let total = app.sidebar_files.total_len();
    let listing_error = app.sidebar_files.listing_error().map(str::to_owned);
    let message = app.sidebar_files.message().map(str::to_owned);
    let unread = unread_summary(app);

    let buf = frame.buffer_mut();
    for y in area.y..area.y + height {
        for x in area.x..area.x + content_width {
            buf[(x, y)].set_symbol(" ").set_style(base);
        }
        buf[(area.x + width - 1, y)].set_symbol(border_symbol).set_style(border);
    }

    if focused {
        for x in area.x..area.x + content_width {
            buf[(x, area.y)].set_style(header_style);
        }
    }
    let marker = if pinned { "● " } else { "  " };
    buf.set_stringn(area.x, area.y, marker, content_w, if focused { header_style } else { dim });
    let badge = unread.map(|(count, _)| format!("• {count}"));
    let badge_width = badge.as_ref().map(|text| text.chars().count()).unwrap_or(0);
    let path_width = content_w.saturating_sub(2 + badge_width + usize::from(badge_width > 0));
    let path = middle_truncate(&current_dir, path_width);
    let path_style = if focused { header_style } else { base }.add_modifier(Modifier::BOLD);
    buf.set_stringn(area.x + 2, area.y, &path, path_width, path_style);
    if let (Some(text), Some((_, color))) = (badge, unread) {
        let badge_x = area.x + content_width.saturating_sub(text.chars().count() as u16);
        buf.set_stringn(
            badge_x,
            area.y,
            &text,
            text.chars().count(),
            header_style.fg(color).add_modifier(Modifier::BOLD),
        );
    }

    let body_start = area.y + 1;
    let body_height = height.saturating_sub(2) as usize;
    let mut hits = Vec::new();
    if let Some(error) = listing_error {
        if body_height > 0 {
            buf.set_stringn(area.x, body_start, truncate(&error, content_w), content_w, dim);
        }
    } else if entries.is_empty() {
        if body_height > 0 {
            buf.set_stringn(area.x, body_start, " No files", content_w, dim);
        }
    } else {
        let offset = file_scroll_offset(selected, body_height, entries.len());
        for (line, (name, is_dir)) in entries.iter().skip(offset).take(body_height).enumerate() {
            let y = body_start + line as u16;
            let row_index = offset + line;
            let style = if row_index == selected { selected_style } else { base };
            if row_index == selected {
                for x in area.x..area.x + content_width {
                    buf[(x, y)].set_style(style);
                }
            }
            let prefix = if *is_dir { "▸ " } else { "  " };
            buf.set_stringn(area.x, y, prefix, content_w, style.add_modifier(Modifier::DIM));
            let name_width = content_w.saturating_sub(2);
            buf.set_stringn(area.x + 2, y, truncate(name, name_width), name_width, style);
            hits.push((
                Rect { x: area.x, y, width: content_width, height: 1 },
                Hit::SidebarFile { index: row_index },
            ));
        }
    }

    let mut input_cursor = None;
    if height > 1 {
        let footer_y = area.y + height - 1;
        if let Some((shown, cursor_col)) = filter_input {
            let input_width = content_width.saturating_sub(1);
            buf.set_stringn(area.x, footer_y, "/", 1, dim);
            buf.set_stringn(area.x + 1, footer_y, &shown, input_width as usize, dim);
            let input_rect = Rect { x: area.x + 1, y: footer_y, width: input_width, height: 1 };
            hits.push((input_rect, Hit::SidebarFilterInput));
            if app.workspace_sidebar_focused() {
                input_cursor = Some((input_rect.x + cursor_col as u16, footer_y));
            }
        } else {
            let footer = if let Some(message) = message {
                message
            } else {
                format!(
                    "{}/{}  .:{}  / filter",
                    entries.len(),
                    total,
                    if show_hidden { "on" } else { "off" }
                )
            };
            buf.set_stringn(area.x, footer_y, truncate(&footer, content_w), content_w, dim);
        }
    }
    hits.push((rail::divider(area), Hit::RailResize(RailKind::Workspace)));
    app.hits.extend(hits);
    input_cursor
}

fn unread_summary(app: &App) -> Option<(usize, Color)> {
    let mut count = 0;
    let mut highest = None;
    for notification in app
        .tree
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .filter_map(|tab| tab.notification.filter(|notification| notification.unread))
    {
        count += 1;
        let ranked = match notification.level {
            "error" => (2u8, app.config.theme.notification_error),
            "warning" => (1, app.config.theme.notification_warning),
            _ => (0, app.config.theme.notification_info),
        };
        if highest.is_none_or(|current: (u8, Color)| ranked.0 > current.0) {
            highest = Some(ranked);
        }
    }
    highest.map(|(_, color)| (count, color))
}

fn file_scroll_offset(selected: usize, visible_height: usize, total: usize) -> usize {
    if visible_height == 0 || total <= visible_height || selected < visible_height {
        return 0;
    }
    (selected + 1).saturating_sub(visible_height).min(total - visible_height)
}
