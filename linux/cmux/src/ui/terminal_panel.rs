//! Terminal panel — wraps a GhosttyGlSurface in a panel container.

use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::AppState;
use crate::model::panel::{Panel, PanelType};

/// Create a GTK widget for a panel.
pub fn create_panel_widget(
    panel: &Panel,
    is_attention_source: bool,
    state: &Rc<AppState>,
) -> gtk4::Widget {
    match panel.panel_type {
        PanelType::Terminal => create_terminal_widget(panel, is_attention_source, state),
        PanelType::Browser => create_browser_placeholder(panel, is_attention_source),
    }
}

/// Create a terminal panel widget backed by GhosttyGlSurface.
fn create_terminal_widget(
    panel: &Panel,
    is_attention_source: bool,
    state: &Rc<AppState>,
) -> gtk4::Widget {
    let container = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    container.set_hexpand(true);
    container.set_vexpand(true);
    container.add_css_class("panel-shell");
    if is_attention_source {
        container.add_css_class("attention-panel");
    }

    let gl_surface = state.terminal_surface_for(panel.id, panel.directory.as_deref());
    {
        let state = Rc::clone(state);
        let panel_id = panel.id;
        gl_surface.set_close_handler(move |process_alive| {
            let _ = state.close_panel(panel_id, process_alive);
        });
    }
    if let Some(parent) = gl_surface.parent() {
        if let Ok(parent_box) = parent.downcast::<gtk4::Box>() {
            parent_box.remove(&gl_surface);
        }
    }

    container.append(&gl_surface);

    // Store the panel ID for later lookup
    container.set_widget_name(&panel.id.to_string());

    container.upcast()
}

/// Create a placeholder for the browser panel (Phase 4).
fn create_browser_placeholder(panel: &Panel, is_attention_source: bool) -> gtk4::Widget {
    let container = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    container.set_hexpand(true);
    container.set_vexpand(true);
    container.add_css_class("panel-shell");
    if is_attention_source {
        container.add_css_class("attention-panel");
    }

    let label = gtk4::Label::new(Some("Browser panel (coming in Phase 4)"));
    label.set_hexpand(true);
    label.set_vexpand(true);
    label.add_css_class("dim-label");
    container.append(&label);

    container.set_widget_name(&panel.id.to_string());
    container.upcast()
}
