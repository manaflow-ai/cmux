//! Main application window using AdwNavigationSplitView.

use std::rc::Rc;

use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::app::AppState;
use crate::model::panel::SplitOrientation;
use crate::model::PanelType;
use crate::ui::{sidebar, split_view};

/// Create the main application window.
pub fn create_window(
    app: &adw::Application,
    state: &Rc<AppState>,
) -> adw::ApplicationWindow {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("cmux")
        .default_width(1200)
        .default_height(800)
        .build();

    // Create the split view: sidebar | content
    let split_view = adw::NavigationSplitView::new();
    split_view.set_min_sidebar_width(180.0);
    split_view.set_max_sidebar_width(320.0);

    // Content area (created first so sidebar can reference it)
    let content_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content_box.set_hexpand(true);
    content_box.set_vexpand(true);

    // Build the initial layout from the selected workspace
    rebuild_content(&content_box, state);

    // Sidebar (receives content_box so selection changes rebuild content)
    let (sidebar_widget, sidebar_list) = sidebar::create_sidebar(state, &content_box);
    let sidebar_page = adw::NavigationPage::new(&sidebar_widget, "Workspaces");
    split_view.set_sidebar(Some(&sidebar_page));

    let content_page = adw::NavigationPage::new(&content_box, "Terminal");
    split_view.set_content(Some(&content_page));

    // Header bar with action buttons
    let header = adw::HeaderBar::new();

    // New workspace button
    let new_ws_btn = gtk4::Button::from_icon_name("tab-new-symbolic");
    new_ws_btn.set_tooltip_text(Some("New Workspace"));
    {
        let state = state.clone();
        let content_box = content_box.clone();
        let sidebar_list = sidebar_list.clone();
        new_ws_btn.connect_clicked(move |_| {
            {
                let ws = crate::model::Workspace::new();
                state.tab_manager().add_workspace(ws);
            } // MutexGuard dropped before refresh/rebuild re-acquire lock
            sidebar::refresh_sidebar(&sidebar_list, &state);
            rebuild_content(&content_box, &state);
            tracing::debug!("New workspace added");
        });
    }
    header.pack_start(&new_ws_btn);

    // Split horizontal button
    let split_h_btn = gtk4::Button::from_icon_name("view-dual-symbolic");
    split_h_btn.set_tooltip_text(Some("Split Horizontal"));
    {
        let state = state.clone();
        let content_box = content_box.clone();
        split_h_btn.connect_clicked(move |_| {
            let did_split = {
                state.tab_manager().selected_mut().map(|ws| {
                    ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
                }).is_some()
            }; // MutexGuard dropped
            if did_split {
                rebuild_content(&content_box, &state);
            }
        });
    }
    header.pack_start(&split_h_btn);

    // Split vertical button
    let split_v_btn = gtk4::Button::from_icon_name("view-paged-symbolic");
    split_v_btn.set_tooltip_text(Some("Split Vertical"));
    {
        let state = state.clone();
        let content_box = content_box.clone();
        split_v_btn.connect_clicked(move |_| {
            let did_split = {
                state.tab_manager().selected_mut().map(|ws| {
                    ws.split(SplitOrientation::Vertical, PanelType::Terminal);
                }).is_some()
            }; // MutexGuard dropped
            if did_split {
                rebuild_content(&content_box, &state);
            }
        });
    }
    header.pack_start(&split_v_btn);

    // Wrap content with header
    let outer_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    outer_box.append(&header);
    outer_box.append(&split_view);

    window.set_content(Some(&outer_box));

    // Keyboard shortcuts
    setup_shortcuts(&window, state, &content_box, &sidebar_list);

    window
}

/// Rebuild the content area from the current workspace layout.
pub fn rebuild_content(content_box: &gtk4::Box, state: &Rc<AppState>) {
    // Remove all children
    while let Some(child) = content_box.first_child() {
        content_box.remove(&child);
    }

    // Clone layout data under lock, release before GTK widget construction
    let ws_data = {
        let tm = state.tab_manager();
        tm.selected().map(|ws| (ws.layout.clone(), ws.panels.clone()))
    }; // MutexGuard dropped

    if let Some((layout, panels)) = ws_data {
        let widget = split_view::build_layout(&layout, &panels, state);
        content_box.append(&widget);
    } else {
        let label = gtk4::Label::new(Some("No workspace selected"));
        label.add_css_class("dim-label");
        content_box.append(&label);
    }
}

/// Set up keyboard shortcuts for the window.
fn setup_shortcuts(
    window: &adw::ApplicationWindow,
    state: &Rc<AppState>,
    content_box: &gtk4::Box,
    sidebar_list: &gtk4::ListBox,
) {
    let controller = gtk4::EventControllerKey::new();

    let state = state.clone();
    let content_box = content_box.clone();
    let sidebar_list = sidebar_list.clone();

    controller.connect_key_pressed(move |_controller, keyval, _keycode, modifier| {
        let ctrl = modifier.contains(gdk4::ModifierType::CONTROL_MASK);
        let shift = modifier.contains(gdk4::ModifierType::SHIFT_MASK);

        // Match on GDK keyval constants (uppercase, since shift is held)
        match (keyval, ctrl, shift) {
            // Ctrl+Shift+T: new workspace
            (gdk4::Key::T, true, true) => {
                {
                    let ws = crate::model::Workspace::new();
                    state.tab_manager().add_workspace(ws);
                } // MutexGuard dropped before refresh/rebuild
                sidebar::refresh_sidebar(&sidebar_list, &state);
                rebuild_content(&content_box, &state);
                glib::Propagation::Stop
            }
            // Ctrl+Shift+W: close workspace
            (gdk4::Key::W, true, true) => {
                {
                    let mut tm = state.tab_manager();
                    if let Some(idx) = tm.selected_index() {
                        tm.remove(idx);
                    }
                } // MutexGuard dropped before refresh/rebuild
                sidebar::refresh_sidebar(&sidebar_list, &state);
                rebuild_content(&content_box, &state);
                glib::Propagation::Stop
            }
            // Ctrl+Shift+D: horizontal split
            (gdk4::Key::D, true, true) => {
                let did_split = {
                    state.tab_manager().selected_mut().map(|ws| {
                        ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
                    }).is_some()
                }; // MutexGuard dropped
                if did_split {
                    rebuild_content(&content_box, &state);
                }
                glib::Propagation::Stop
            }
            // Ctrl+Shift+E: vertical split
            (gdk4::Key::E, true, true) => {
                let did_split = {
                    state.tab_manager().selected_mut().map(|ws| {
                        ws.split(SplitOrientation::Vertical, PanelType::Terminal);
                    }).is_some()
                }; // MutexGuard dropped
                if did_split {
                    rebuild_content(&content_box, &state);
                }
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });

    window.add_controller(controller);
}
