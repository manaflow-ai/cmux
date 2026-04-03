//! Main application window using AdwNavigationSplitView.

use std::rc::Rc;

use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::app::{lock_or_recover, AppState, UiEvent};
use crate::model::panel::SplitOrientation;
use crate::model::{PanelType, Workspace};
use crate::ui::{sidebar, split_view};

/// Create the main application window.
pub fn create_window(
    app: &adw::Application,
    state: &Rc<AppState>,
    ui_events: UnboundedReceiver<UiEvent>,
) -> adw::ApplicationWindow {
    install_css();
    ensure_icon_theme();

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("cmux")
        .default_width(1280)
        .default_height(860)
        .build();

    // Add the "background" CSS class so the window has an opaque background.
    // Without this, the GTK default (slightly transparent) background can bleed
    // through the GL terminal surface, making the terminal bg appear brighter
    // than configured. Vanilla Ghostty sets this when background-opacity >= 1.
    window.add_css_class("background");

    let split_view = adw::NavigationSplitView::new();
    split_view.set_min_sidebar_width(220.0);
    split_view.set_max_sidebar_width(360.0);
    split_view.set_vexpand(true);
    split_view.set_hexpand(true);

    let sidebar_widgets = sidebar::create_sidebar(state);
    let list_box = sidebar_widgets.list_box.clone();
    let sidebar_page = adw::NavigationPage::new(&sidebar_widgets.root, "Workspaces");
    split_view.set_sidebar(Some(&sidebar_page));

    let content_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content_box.set_hexpand(true);
    content_box.set_vexpand(true);
    // Make content containers transparent so the window's "background" CSS
    // class is the only opaque layer. Without this, Adwaita's default
    // container backgrounds (slightly lighter) bleed through the GL surface
    // whose renderer clears to transparent rgba(0,0,0,0).
    content_box.add_css_class("transparent");
    rebuild_content(&content_box, state);

    let content_page = adw::NavigationPage::new(&content_box, "Terminal");
    content_page.add_css_class("transparent");
    split_view.set_content(Some(&content_page));

    bind_sidebar_selection(&list_box, &content_box, state);
    bind_shared_state_updates(&list_box, &content_box, state, ui_events);

    let header = adw::HeaderBar::new();

    let new_ws_btn = gtk4::Button::from_icon_name("tab-new-symbolic");
    new_ws_btn.set_tooltip_text(Some("New Workspace"));
    {
        let state = state.clone();
        let list_box = list_box.clone();
        let content_box = content_box.clone();
        new_ws_btn.connect_clicked(move |_| {
            let workspace = Workspace::new();
            lock_or_recover(&state.shared.tab_manager).add_workspace(workspace);
            refresh_ui(&list_box, &content_box, &state);
        });
    }
    header.pack_start(&new_ws_btn);

    let split_h_btn = gtk4::Button::from_icon_name("view-dual-symbolic");
    split_h_btn.set_tooltip_text(Some("Split Horizontal"));
    {
        let state = state.clone();
        let list_box = list_box.clone();
        let content_box = content_box.clone();
        split_h_btn.connect_clicked(move |_| {
            if let Some(workspace) = lock_or_recover(&state.shared.tab_manager).selected_mut() {
                workspace.split(SplitOrientation::Horizontal, PanelType::Terminal);
            }
            refresh_ui(&list_box, &content_box, &state);
        });
    }
    header.pack_start(&split_h_btn);

    let split_v_btn = gtk4::Button::from_icon_name("view-paged-symbolic");
    split_v_btn.set_tooltip_text(Some("Split Vertical"));
    {
        let state = state.clone();
        let list_box = list_box.clone();
        let content_box = content_box.clone();
        split_v_btn.connect_clicked(move |_| {
            if let Some(workspace) = lock_or_recover(&state.shared.tab_manager).selected_mut() {
                workspace.split(SplitOrientation::Vertical, PanelType::Terminal);
            }
            refresh_ui(&list_box, &content_box, &state);
        });
    }
    header.pack_start(&split_v_btn);

    let outer_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    outer_box.append(&header);
    outer_box.append(&split_view);

    window.set_content(Some(&outer_box));
    setup_shortcuts(&window, state, &list_box, &content_box);

    {
        let state = state.clone();
        window.connect_is_active_notify(move |window| {
            let active = window.is_active();
            if let Some(app) = state.ghostty_app.borrow().as_ref() {
                app.set_focus(active);
            }
        });
    }

    window
}

/// Rebuild the content area from the current workspace layout.
pub fn rebuild_content(content_box: &gtk4::Box, state: &Rc<AppState>) {
    while let Some(child) = content_box.first_child() {
        content_box.remove(&child);
    }

    // Clone workspace data out of the lock so we don't hold it during
    // GTK widget construction (build_layout callbacks may re-acquire it).
    let workspace_data = {
        let tab_manager = lock_or_recover(&state.shared.tab_manager);
        tab_manager.selected().map(|ws| {
            (ws.id, ws.layout.clone(), ws.panels.clone(), ws.attention_panel_id)
        })
    };

    if let Some((id, layout, panels, attention_panel_id)) = workspace_data {
        let widget = split_view::build_layout(id, &layout, &panels, attention_panel_id, state);
        content_box.append(&widget);
    } else {
        let label = gtk4::Label::new(Some("No workspace selected"));
        label.add_css_class("dim-label");
        content_box.append(&label);
    }
}

fn refresh_ui(list_box: &gtk4::ListBox, content_box: &gtk4::Box, state: &Rc<AppState>) {
    state.prune_terminal_cache();
    sidebar::refresh_sidebar(list_box, state);
    rebuild_content(content_box, state);
}

fn bind_sidebar_selection(list_box: &gtk4::ListBox, content_box: &gtk4::Box, state: &Rc<AppState>) {
    let state = state.clone();
    let lb = list_box.clone();
    let content_box = content_box.clone();

    list_box.connect_row_selected(move |_list_box, row| {
        let Some(row) = row else {
            return;
        };

        let index = row.index();
        if index < 0 {
            return;
        }
        if select_workspace_by_index(&state, index as usize) {
            refresh_ui(&lb, &content_box, &state);
        }
    });
}

fn bind_shared_state_updates(
    list_box: &gtk4::ListBox,
    content_box: &gtk4::Box,
    state: &Rc<AppState>,
    mut ui_events: UnboundedReceiver<UiEvent>,
) {
    let state = state.clone();
    let list_box = list_box.clone();
    let content_box = content_box.clone();

    glib::MainContext::default().spawn_local(async move {
        while let Some(event) = ui_events.recv().await {
            let mut pending = Some(event);
            let mut needs_refresh = false;
            loop {
                let event = match pending.take() {
                    Some(event) => event,
                    None => match ui_events.try_recv() {
                        Ok(event) => event,
                        Err(_) => break,
                    },
                };

                match event {
                    UiEvent::Refresh
                    | UiEvent::SurfacePwd { .. }
                    | UiEvent::SurfaceTitle { .. } => needs_refresh = true,
                    UiEvent::SendInput { panel_id, text } => {
                        let sent = state.send_input_to_panel(panel_id, &text);
                        if !sent {
                            tracing::warn!(
                                %panel_id,
                                "surface.send_input dropped because panel is not ready"
                            );
                        }
                    }
                }
            }

            if needs_refresh {
                refresh_ui(&list_box, &content_box, &state);
            }
        }
    });
}

fn select_workspace_by_index(state: &Rc<AppState>, index: usize) -> bool {
    let (selected, already_selected, workspace_id) = {
        let mut tab_manager = lock_or_recover(&state.shared.tab_manager);
        let already_selected = tab_manager.selected_index() == Some(index);
        let selected = tab_manager.select(index);
        let workspace_id = tab_manager.get(index).map(|workspace| workspace.id);
        (selected, already_selected, workspace_id)
    };

    if !selected || already_selected {
        return false;
    }

    if let Some(workspace_id) = workspace_id {
        mark_workspace_read(state, workspace_id);
    }

    true
}

fn select_latest_unread(state: &Rc<AppState>) -> bool {
    let workspace_id = {
        let mut tab_manager = lock_or_recover(&state.shared.tab_manager);
        tab_manager.select_latest_unread()
    };

    let Some(workspace_id) = workspace_id else {
        return false;
    };

    mark_workspace_read(state, workspace_id);
    true
}

fn mark_workspace_read(state: &Rc<AppState>, workspace_id: uuid::Uuid) {
    lock_or_recover(&state.shared.notifications).mark_workspace_read(workspace_id);

    if let Some(workspace) =
        lock_or_recover(&state.shared.tab_manager).workspace_mut(workspace_id)
    {
        workspace.mark_notifications_read();
    }
}

fn setup_shortcuts(
    window: &adw::ApplicationWindow,
    state: &Rc<AppState>,
    list_box: &gtk4::ListBox,
    content_box: &gtk4::Box,
) {
    let controller = gtk4::EventControllerKey::new();

    let state = state.clone();
    let list_box = list_box.clone();
    let content_box = content_box.clone();

    controller.connect_key_pressed(move |_controller, keyval, _keycode, modifier| {
        let ctrl = modifier.contains(gdk4::ModifierType::CONTROL_MASK);
        let shift = modifier.contains(gdk4::ModifierType::SHIFT_MASK);

        match (keyval, ctrl, shift) {
            (gdk4::Key::T, true, true) => {
                let workspace = Workspace::new();
                lock_or_recover(&state.shared.tab_manager).add_workspace(workspace);
                refresh_ui(&list_box, &content_box, &state);
                glib::Propagation::Stop
            }
            (gdk4::Key::W, true, true) => {
                let mut tab_manager = lock_or_recover(&state.shared.tab_manager);
                if let Some(index) = tab_manager.selected_index() {
                    tab_manager.remove(index);
                }
                drop(tab_manager);
                refresh_ui(&list_box, &content_box, &state);
                glib::Propagation::Stop
            }
            (gdk4::Key::D, true, true) => {
                if let Some(workspace) = lock_or_recover(&state.shared.tab_manager).selected_mut() {
                    workspace.split(SplitOrientation::Horizontal, PanelType::Terminal);
                }
                refresh_ui(&list_box, &content_box, &state);
                glib::Propagation::Stop
            }
            (gdk4::Key::E, true, true) => {
                if let Some(workspace) = lock_or_recover(&state.shared.tab_manager).selected_mut() {
                    workspace.split(SplitOrientation::Vertical, PanelType::Terminal);
                }
                refresh_ui(&list_box, &content_box, &state);
                glib::Propagation::Stop
            }
            (gdk4::Key::U, true, true) => {
                if select_latest_unread(&state) {
                    refresh_ui(&list_box, &content_box, &state);
                }
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });

    window.add_controller(controller);
}

/// Ensure Adwaita symbolic icons are available regardless of the active icon theme.
///
/// Custom themes (e.g. Flat-Remix) may not include GNOME/Adwaita-specific
/// symbolic icons like `tab-new-symbolic`. Adding "Adwaita" as a suffix
/// theme tells GTK to fall back to it for any missing icons.
/// Ensure Adwaita symbolic icons are available regardless of the active icon theme.
///
/// Custom themes (e.g. Flat-Remix) inherit from AdwaitaLegacy/hicolor but
/// not from the modern Adwaita theme, so GNOME symbolic icons like
/// `tab-new-symbolic` are missing. Override via GtkSettings since this is
/// a libadwaita app that depends on Adwaita's icon set.
fn ensure_icon_theme() {
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_icon_theme_name(Some("Adwaita"));
    }
}

fn install_css() {
    let provider = gtk4::CssProvider::new();
    provider.load_from_data(
        "
        .workspace-row {
            border-radius: 10px;
        }

        .sidebar-notification {
            color: @accent_color;
            font-weight: 600;
        }

        .sidebar-branch {
            color: @accent_color;
        }

        .sidebar-status-row {
            margin-top: 1px;
        }

        .sidebar-progress-bar {
            min-height: 4px;
            border-radius: 2px;
        }

        .sidebar-log-success {
            color: #2ec27e;
        }

        .sidebar-log-warning {
            color: #e5a50a;
        }

        .sidebar-log-error {
            color: #e01b24;
        }

        .sidebar-log-progress {
            color: @accent_color;
        }

        .transparent {
            background-color: transparent;
        }

        .panel-shell {
            border: 1px solid rgba(127, 127, 127, 0.18);
            border-radius: 10px;
            padding: 3px;
            background-color: transparent;
        }

        .attention-panel {
            border: 2px solid #3584e4;
            background-color: rgba(53, 132, 228, 0.08);
        }
        ",
    );

    if let Some(display) = gdk4::Display::default() {
        gtk4::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}
