//! Main application window using AdwNavigationSplitView.

use std::cell::RefCell;
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

    // Sidebar
    let sidebar_page = adw::NavigationPage::new(
        &sidebar::create_sidebar(state),
        "Workspaces",
    );
    split_view.set_sidebar(Some(&sidebar_page));

    // Content area
    let content_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content_box.set_hexpand(true);
    content_box.set_vexpand(true);

    // Build the initial layout from the selected workspace
    rebuild_content(&content_box, state);

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
        new_ws_btn.connect_clicked(move |_| {
            let ws = crate::model::Workspace::new();
            state.tab_manager.borrow_mut().add_workspace(ws);
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
            if let Some(ws) = state.tab_manager.borrow_mut().selected_mut() {
                ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
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
            if let Some(ws) = state.tab_manager.borrow_mut().selected_mut() {
                ws.split(SplitOrientation::Vertical, PanelType::Terminal);
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
    setup_shortcuts(&window, state, &content_box);

    window
}

/// Rebuild the content area from the current workspace layout.
pub fn rebuild_content(content_box: &gtk4::Box, state: &Rc<AppState>) {
    // Remove all children
    while let Some(child) = content_box.first_child() {
        content_box.remove(&child);
    }

    let tm = state.tab_manager.borrow();
    if let Some(ws) = tm.selected() {
        let widget = split_view::build_layout(&ws.layout, &ws.panels, state);
        content_box.append(&widget);
    } else {
        // Empty state
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
) {
    let controller = gtk4::EventControllerKey::new();

    let state = state.clone();
    let content_box = content_box.clone();

    controller.connect_key_pressed(move |_controller, keyval, _keycode, modifier| {
        let ctrl = modifier.contains(gdk4::ModifierType::CONTROL_MASK);
        let shift = modifier.contains(gdk4::ModifierType::SHIFT_MASK);

        // Match on GDK keyval constants (uppercase, since shift is held)
        match (keyval, ctrl, shift) {
            // Ctrl+Shift+T: new workspace
            (gdk4::Key::T, true, true) => {
                let ws = crate::model::Workspace::new();
                state.tab_manager.borrow_mut().add_workspace(ws);
                rebuild_content(&content_box, &state);
                glib::Propagation::Stop
            }
            // Ctrl+Shift+W: close workspace
            (gdk4::Key::W, true, true) => {
                let mut tm = state.tab_manager.borrow_mut();
                if let Some(idx) = tm.selected_index() {
                    tm.remove(idx);
                }
                drop(tm);
                rebuild_content(&content_box, &state);
                glib::Propagation::Stop
            }
            // Ctrl+Shift+D: horizontal split
            (gdk4::Key::D, true, true) => {
                if let Some(ws) = state.tab_manager.borrow_mut().selected_mut() {
                    ws.split(SplitOrientation::Horizontal, PanelType::Terminal);
                }
                rebuild_content(&content_box, &state);
                glib::Propagation::Stop
            }
            // Ctrl+Shift+E: vertical split
            (gdk4::Key::E, true, true) => {
                if let Some(ws) = state.tab_manager.borrow_mut().selected_mut() {
                    ws.split(SplitOrientation::Vertical, PanelType::Terminal);
                }
                rebuild_content(&content_box, &state);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });

    window.add_controller(controller);
}
