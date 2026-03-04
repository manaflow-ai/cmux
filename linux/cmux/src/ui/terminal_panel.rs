//! Terminal panel — wraps a GhosttyGlSurface in a panel container.

use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::AppState;
use crate::model::panel::{Panel, PanelType};

/// Create a GTK widget for a panel.
pub fn create_panel_widget(panel: &Panel, _state: &Rc<AppState>) -> gtk4::Widget {
    match panel.panel_type {
        PanelType::Terminal => create_terminal_widget(panel),
        PanelType::Browser => create_browser_placeholder(panel),
    }
}

/// Create a terminal panel widget backed by GhosttyGlSurface.
fn create_terminal_widget(panel: &Panel) -> gtk4::Widget {
    let container = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    container.set_hexpand(true);
    container.set_vexpand(true);

    // Create the ghostty GL surface
    let gl_surface = ghostty_gtk::surface::GhosttyGlSurface::new();
    gl_surface.set_hexpand(true);
    gl_surface.set_vexpand(true);

    // The surface will be initialized with the ghostty app when the app state
    // is fully set up. For now, just add it to the container.
    // TODO: Connect to ghostty app in Phase 1 integration
    // gl_surface.initialize(app.raw(), panel.directory.as_deref(), None);

    container.append(&gl_surface);

    // Store the panel ID for later lookup
    container.set_widget_name(&panel.id.to_string());

    container.upcast()
}

/// Create a placeholder for the browser panel (Phase 4).
fn create_browser_placeholder(panel: &Panel) -> gtk4::Widget {
    let container = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    container.set_hexpand(true);
    container.set_vexpand(true);

    let label = gtk4::Label::new(Some("Browser panel (coming in Phase 4)"));
    label.set_hexpand(true);
    label.set_vexpand(true);
    label.add_css_class("dim-label");
    container.append(&label);

    container.set_widget_name(&panel.id.to_string());
    container.upcast()
}
