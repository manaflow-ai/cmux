//! Split view — recursive GtkPaned tree from LayoutNode.

use std::collections::HashMap;
use std::rc::Rc;

use gtk4::prelude::*;
use uuid::Uuid;

use crate::app::AppState;
use crate::model::panel::{LayoutNode, Panel, SplitOrientation};
use crate::ui::terminal_panel;

/// Build a GTK widget tree from a LayoutNode.
///
/// - `LayoutNode::Pane` → GtkStack (with tabs if multiple panels) wrapping terminal widgets
/// - `LayoutNode::Split` → GtkPaned with recursive children
pub fn build_layout(
    node: &LayoutNode,
    panels: &HashMap<Uuid, Panel>,
    attention_panel_id: Option<Uuid>,
    state: &Rc<AppState>,
) -> gtk4::Widget {
    match node {
        LayoutNode::Pane {
            panel_ids,
            selected_panel_id,
        } => build_pane(
            panel_ids,
            *selected_panel_id,
            panels,
            attention_panel_id,
            state,
        ),

        LayoutNode::Split {
            orientation,
            divider_position,
            first,
            second,
        } => build_split(
            *orientation,
            *divider_position,
            first,
            second,
            panels,
            attention_panel_id,
            state,
        ),
    }
}

/// Build a pane widget (single or tabbed panels).
fn build_pane(
    panel_ids: &[Uuid],
    selected_id: Option<Uuid>,
    panels: &HashMap<Uuid, Panel>,
    attention_panel_id: Option<Uuid>,
    state: &Rc<AppState>,
) -> gtk4::Widget {
    if panel_ids.is_empty() {
        // Empty pane — show placeholder
        let label = gtk4::Label::new(Some("Empty pane"));
        label.set_hexpand(true);
        label.set_vexpand(true);
        return label.upcast();
    }

    if panel_ids.len() == 1 {
        // Single panel — no tabs needed
        let panel_id = panel_ids[0];
        if let Some(panel) = panels.get(&panel_id) {
            return terminal_panel::create_panel_widget(
                panel,
                attention_panel_id == Some(panel_id),
                state,
            );
        }
        let label = gtk4::Label::new(Some("Panel not found"));
        return label.upcast();
    }

    // Multiple panels — use GtkStack with switcher
    let stack = gtk4::Stack::new();
    stack.set_hexpand(true);
    stack.set_vexpand(true);

    for &panel_id in panel_ids {
        if let Some(panel) = panels.get(&panel_id) {
            let widget = terminal_panel::create_panel_widget(
                panel,
                attention_panel_id == Some(panel_id),
                state,
            );
            let page = stack.add_child(&widget);
            page.set_title(panel.display_title());
            page.set_name(&panel_id.to_string());
        }
    }

    // Select the active panel
    if let Some(sel_id) = selected_id {
        stack.set_visible_child_name(&sel_id.to_string());
    }

    // If there are tabs, add a tab switcher
    let vbox = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    if panel_ids.len() > 1 {
        let switcher = gtk4::StackSwitcher::new();
        switcher.set_stack(Some(&stack));
        vbox.append(&switcher);
    }
    vbox.append(&stack);
    vbox.set_hexpand(true);
    vbox.set_vexpand(true);
    vbox.upcast()
}

/// Build a split widget (GtkPaned with two children).
fn build_split(
    orientation: SplitOrientation,
    divider_position: f64,
    first: &LayoutNode,
    second: &LayoutNode,
    panels: &HashMap<Uuid, Panel>,
    attention_panel_id: Option<Uuid>,
    state: &Rc<AppState>,
) -> gtk4::Widget {
    let gtk_orientation = match orientation {
        SplitOrientation::Horizontal => gtk4::Orientation::Horizontal,
        SplitOrientation::Vertical => gtk4::Orientation::Vertical,
    };

    let paned = gtk4::Paned::new(gtk_orientation);
    paned.set_wide_handle(true);
    paned.set_hexpand(true);
    paned.set_vexpand(true);

    let first_widget = build_layout(first, panels, attention_panel_id, state);
    let second_widget = build_layout(second, panels, attention_panel_id, state);

    paned.set_start_child(Some(&first_widget));
    paned.set_end_child(Some(&second_widget));

    // Set divider position after the widget is mapped
    let pos = divider_position;
    paned.connect_map(move |paned| {
        let size = match paned.orientation() {
            gtk4::Orientation::Horizontal => paned.width(),
            _ => paned.height(),
        };
        if size > 0 {
            paned.set_position((size as f64 * pos) as i32);
        }
    });

    paned.upcast()
}
