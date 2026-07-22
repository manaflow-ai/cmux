//! Left sidebar renderer for the built-in files/workspaces views and the
//! external plugin PTY. Owns its full column including the status-bar row
//! (the status bar starts after the sidebar) and rebuilds the click hit map
//! as it draws.

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};

use super::{middle_truncate, rail, truncate};
use crate::app::{App, Hit, RailKind, WorkspaceRailSelection};
use crate::config::SidebarView;
use crate::localization;
use crate::machine::{
    MachineRailSelection, MachineStatus, ProviderScopeKind, WorkspaceCreationMode,
};

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

pub fn draw(app: &mut App, frame: &mut Frame) {
    if app.workspace_sidebar_area(frame.area().height).is_none() {
        return;
    }
    if app.config.sidebar.plugin.is_some() {
        draw_plugin(app, frame);
        return;
    }
    match app.sidebar_view {
        SidebarView::Files => draw_files(app, frame),
        SidebarView::Workspaces => draw_workspaces(app, frame),
    }
}

pub fn draw_machines(app: &mut App, frame: &mut Frame) {
    let Some(area) = app.machine_sidebar_area(frame.area().height) else { return };
    let Some(machine_ui) = app.machine_ui.as_ref() else { return };
    let machines = machine_ui.snapshot.machines.clone();
    let active = machine_ui.snapshot.active;
    let capabilities = machine_ui.snapshot.capabilities;
    let selection = machine_ui.selection;
    let managed_machines = machine_ui.managed_machines().to_vec();
    let provider = machine_ui.provider.clone();
    let rail_selection = machine_ui.rail_selection;
    let palette = rail::RailPalette::for_app(app, app.machine_sidebar_focused());
    let messages = &localization::catalog().sidebar;
    rail::prepare(frame, area, palette);
    rail::header(frame, area, messages.machines, palette);

    let mut body_rows = 0;
    let scope_row = provider.as_ref().filter(|provider| !provider.scopes.is_empty()).map(|_| {
        let row = body_rows;
        body_rows += 1;
        row
    });
    let actions_row = provider.as_ref().filter(|provider| !provider.actions.is_empty()).map(|_| {
        let row = body_rows;
        body_rows += 1;
        row
    });
    if (scope_row.is_some() || actions_row.is_some()) && !machines.is_empty() {
        body_rows += 1;
    }
    let machine_start = body_rows;
    if machines.is_empty() {
        body_rows += 1;
    } else {
        body_rows += machines.len() * rail::ENTRY_STRIDE;
    }
    let create_footer = capabilities.create.then_some(0);
    let connect_footer = capabilities.connect.then_some(usize::from(capabilities.create));
    let footer_rows = usize::from(capabilities.create) + usize::from(capabilities.connect);
    let selected_body = if app.machine_sidebar_focused() && app.machine_rail_follow_selection {
        match rail_selection {
            MachineRailSelection::Scope => scope_row.map(|row| rail::RowSpan::new(row, 1)),
            MachineRailSelection::Actions => actions_row.map(|row| rail::RowSpan::new(row, 1)),
            MachineRailSelection::Machine => (!machines.is_empty()).then_some(rail::RowSpan::new(
                machine_start + selection * rail::ENTRY_STRIDE,
                rail::ENTRY_HEIGHT,
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
    if let Some(provider) = provider.as_ref() {
        if let Some(y) = scope_row.and_then(|row| viewport.body_y(rail::RowSpan::new(row, 1))) {
            let scope_label = provider
                .selected_scope()
                .map(|scope| {
                    let kind = match scope.kind {
                        ProviderScopeKind::Personal => messages.personal_scope,
                        ProviderScopeKind::Team => messages.team_scope,
                    };
                    format!("{kind} · {} ▾", scope.name)
                })
                .unwrap_or_else(|| format!("{} ▾", messages.scope));
            rail::button(
                frame,
                area,
                y,
                &scope_label,
                app.machine_sidebar_focused() && rail_selection == MachineRailSelection::Scope,
                palette,
            );
            hits.push((rail::row(area, y), Hit::ProviderScope));
        }
        if let Some(y) = actions_row.and_then(|row| viewport.body_y(rail::RowSpan::new(row, 1))) {
            rail::button(
                frame,
                area,
                y,
                &format!("{} ▾", messages.provider_actions),
                app.machine_sidebar_focused() && rail_selection == MachineRailSelection::Actions,
                palette,
            );
            hits.push((rail::row(area, y), Hit::ProviderActions));
        }
    }
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
        let span =
            rail::RowSpan::new(machine_start + index * rail::ENTRY_STRIDE, rail::ENTRY_HEIGHT);
        let Some(y) = viewport.body_y(span) else { continue };
        let is_active = Some(machine.key) == active;
        let focused = app.machine_sidebar_focused()
            && rail_selection == MachineRailSelection::Machine
            && selection == index;
        let managed = managed_machines.iter().find(|managed| managed.key == machine.key);
        let recoverable = managed.is_some_and(|managed| {
            managed.status == crate::machine::ManagedMachineStatus::Recoverable
        });
        let status = match machine.status {
            MachineStatus::Running => messages.running,
            MachineStatus::Connecting => messages.connecting,
            MachineStatus::Sleeping => messages.sleeping,
            MachineStatus::Stopped => messages.stopped,
            MachineStatus::Unavailable => messages.unavailable,
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
            match machine.status {
                MachineStatus::Running => Some(app.config.theme.notification_info),
                MachineStatus::Connecting | MachineStatus::Sleeping => {
                    Some(app.config.theme.notification_warning)
                }
                MachineStatus::Stopped => None,
                MachineStatus::Unavailable => Some(app.config.theme.notification_error),
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
        );
        hits.push((rail::row(area, y), Hit::Machine { index, key: machine.key }));
        hits.push((rail::row(area, y + 1), Hit::Machine { index, key: machine.key }));
    }

    if let Some(y) = create_footer.and_then(|row| viewport.footer_y(rail::RowSpan::new(row, 1))) {
        rail::action(
            frame,
            area,
            y,
            messages.new_vm,
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
    hits.push((rail::divider(area), Hit::RailResize(RailKind::Machine)));
    app.hits.extend(hits);
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
    let focused = app.workspace_sidebar_focused();
    let border_style = Style::default().fg(if focused {
        app.config.theme.border_active
    } else {
        app.config.theme.border_inactive
    });
    {
        let buf = frame.buffer_mut();
        for y in area.y..area.y + height {
            buf[(border_x, y)].set_symbol("│").set_style(border_style);
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
                    buf[(border_x, y)].set_symbol("│").set_style(border_style);
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
    let workspace_drag = app.workspace_drag();
    let messages = &localization::catalog().sidebar;
    rail::prepare(frame, area, palette);
    rail::header(frame, area, messages.workspaces, palette);

    let creation_modes = app.workspace_creation_modes();
    let recoverable = app
        .machine_ui
        .as_ref()
        .map(|ui| ui.recoverable_workspaces().into_iter().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let body_rows = (app.tree.workspaces.len() + recoverable.len()) * rail::ENTRY_STRIDE;
    let selected_body = (app.workspace_sidebar_focused() && app.workspace_rail_follow_selection)
        .then(|| match app.workspace_rail_selection {
            WorkspaceRailSelection::Workspace
                if app.sidebar_workspace_selection < app.tree.workspaces.len() =>
            {
                Some(rail::RowSpan::new(
                    app.sidebar_workspace_selection * rail::ENTRY_STRIDE,
                    rail::ENTRY_HEIGHT,
                ))
            }
            WorkspaceRailSelection::Recoverable
                if app.sidebar_recoverable_workspace_selection < recoverable.len() =>
            {
                Some(rail::RowSpan::new(
                    (app.tree.workspaces.len() + app.sidebar_recoverable_workspace_selection)
                        * rail::ENTRY_STRIDE,
                    rail::ENTRY_HEIGHT,
                ))
            }
            _ => None,
        })
        .flatten();
    let selected_footer = if app.workspace_sidebar_focused() && app.workspace_rail_follow_selection
    {
        creation_modes
            .iter()
            .position(|mode| app.workspace_rail_selection.matches_mode(*mode))
            .map(|row| rail::RowSpan::new(row, 1))
    } else {
        None
    };
    let viewport = rail::viewport(
        area,
        body_rows,
        creation_modes.len(),
        &mut app.workspace_rail_scroll,
        &mut app.workspace_footer_scroll,
        selected_body,
        selected_footer,
    );

    let mut hits = Vec::new();
    for (i, ws) in app.tree.workspaces.iter().enumerate() {
        let span = rail::RowSpan::new(i * rail::ENTRY_STRIDE, rail::ENTRY_HEIGHT);
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
        rail::entry(
            frame,
            area,
            y,
            rail::Entry {
                name: &ws.name,
                subtitle: &subtitle,
                highlighted,
                active,
                indicator: workspace_unread_color(&app.config.theme, ws),
                dimmed: workspace_drag.is_some_and(|(id, _)| id == ws.id),
            },
            palette,
        );
        hits.push((rail::row(area, y), Hit::Workspace { index: i, id: ws.id }));
        hits.push((rail::row(area, y + 1), Hit::Workspace { index: i, id: ws.id }));
    }

    for (index, workspace) in recoverable.iter().enumerate() {
        let row = app.tree.workspaces.len() + index;
        let span = rail::RowSpan::new(row * rail::ENTRY_STRIDE, rail::ENTRY_HEIGHT);
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
        );
        hits.push((rail::row(area, y), Hit::RecoverableWorkspace { index }));
        hits.push((rail::row(area, y + 1), Hit::RecoverableWorkspace { index }));
    }

    if let Some((_, Some(index))) = workspace_drag {
        let marker_row = index.saturating_mul(rail::ENTRY_STRIDE).saturating_sub(1);
        if let Some(marker_y) = viewport.body_y(rail::RowSpan::new(marker_row, 1)) {
            let buf = frame.buffer_mut();
            for x in area.x..area.x + area.width.saturating_sub(1) {
                buf[(x, marker_y)]
                    .set_symbol("─")
                    .set_style(Style::default().fg(app.config.theme.border_active));
            }
        }
    }

    for (row, mode) in creation_modes.iter().copied().enumerate() {
        let Some(y) = viewport.footer_y(rail::RowSpan::new(row, 1)) else { continue };
        let label = match mode {
            None => messages.new_workspace,
            Some(WorkspaceCreationMode::Isolated) => messages.new_isolated_workspace,
            Some(WorkspaceCreationMode::Host) => messages.new_shared_workspace,
        };
        rail::action(
            frame,
            area,
            y,
            label,
            app.workspace_sidebar_focused() && app.workspace_rail_selection.matches_mode(mode),
            palette,
        );
        hits.push((rail::row(area, y), Hit::CreateWorkspace { mode }));
    }
    hits.push((rail::divider(area), Hit::RailResize(RailKind::Workspace)));
    app.hits.extend(hits);
}

fn draw_files(app: &mut App, frame: &mut Frame) {
    let Some(area) = app.workspace_sidebar_area(frame.area().height) else { return };
    let width = area.width;
    let height = area.height;
    if width < 3 || height == 0 {
        return;
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
    let border = base.fg(if app.workspace_sidebar_focused() {
        app.config.theme.border_active
    } else {
        chrome.sidebar_border
    });

    let entries = app
        .sidebar_files
        .visible_entries()
        .map(|entry| (entry.name.clone(), entry.is_dir()))
        .collect::<Vec<_>>();
    let selected = app.sidebar_files.selected();
    let current_dir = app.sidebar_files.current_dir().to_string_lossy().into_owned();
    let pinned = app.sidebar_files.is_pinned();
    let filter_mode = app.sidebar_files.filter_mode();
    let query = app.sidebar_files.query().to_string();
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
        buf[(area.x + width - 1, y)].set_symbol("│").set_style(border);
    }

    let marker = if pinned { "● " } else { "  " };
    buf.set_stringn(area.x, area.y, marker, content_w, dim);
    let badge = unread.map(|(count, _)| format!("• {count}"));
    let badge_width = badge.as_ref().map(|text| text.chars().count()).unwrap_or(0);
    let path_width = content_w.saturating_sub(2 + badge_width + usize::from(badge_width > 0));
    let path = middle_truncate(&current_dir, path_width);
    buf.set_stringn(area.x + 2, area.y, &path, path_width, base.add_modifier(Modifier::BOLD));
    if let (Some(text), Some((_, color))) = (badge, unread) {
        let badge_x = area.x + content_width.saturating_sub(text.chars().count() as u16);
        buf.set_stringn(
            badge_x,
            area.y,
            &text,
            text.chars().count(),
            base.fg(color).add_modifier(Modifier::BOLD),
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

    if height > 1 {
        let footer = if filter_mode {
            format!("/{query}█")
        } else if let Some(message) = message {
            message
        } else {
            format!(
                "{}/{}  .:{}  / filter",
                entries.len(),
                total,
                if show_hidden { "on" } else { "off" }
            )
        };
        buf.set_stringn(area.x, area.y + height - 1, truncate(&footer, content_w), content_w, dim);
    }
    hits.push((rail::divider(area), Hit::RailResize(RailKind::Workspace)));
    app.hits.extend(hits);
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
