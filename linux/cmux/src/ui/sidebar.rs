//! Sidebar — workspace list using GtkListBox.

use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::AppState;

/// Create the sidebar widget containing the workspace list.
/// Returns both the sidebar box and the inner ListBox (for external refresh).
pub fn create_sidebar(
    state: &Rc<AppState>,
    content_box: &gtk4::Box,
) -> (gtk4::Box, gtk4::ListBox) {
    let sidebar_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    sidebar_box.add_css_class("sidebar");

    // Scrolled window for the workspace list
    let scrolled = gtk4::ScrolledWindow::new();
    scrolled.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
    scrolled.set_vexpand(true);

    let list_box = gtk4::ListBox::new();
    list_box.set_selection_mode(gtk4::SelectionMode::Single);
    list_box.add_css_class("navigation-sidebar");

    // Populate the list
    populate_workspace_list(&list_box, state);

    // Handle selection changes — also rebuild the content area
    {
        let state = state.clone();
        let content_box = content_box.clone();
        list_box.connect_row_selected(move |_list_box, row| {
            if let Some(row) = row {
                let i = row.index();
                if i >= 0 {
                    let index = i as usize;
                    state.tab_manager().select(index);
                    super::window::rebuild_content(&content_box, &state);
                    tracing::debug!("Workspace selected: index={}", index);
                }
            }
        });
    }

    scrolled.set_child(Some(&list_box));
    sidebar_box.append(&scrolled);

    (sidebar_box, list_box)
}

/// Refresh the sidebar list from the current tab manager state.
pub fn refresh_sidebar(list_box: &gtk4::ListBox, state: &Rc<AppState>) {
    populate_workspace_list(list_box, state);
}

/// Populate the workspace list from the current tab manager state.
///
/// Important: collects all rows while holding the TabManager lock, then drops
/// the lock before calling `select_row` to avoid deadlock (the `row-selected`
/// signal handler also acquires the lock).
fn populate_workspace_list(list_box: &gtk4::ListBox, state: &Rc<AppState>) {
    // Remove existing rows
    while let Some(child) = list_box.first_child() {
        list_box.remove(&child);
    }

    // Build rows while holding the lock
    let (rows, selected_index) = {
        let tm = state.tab_manager();
        let selected = tm.selected_index();
        let rows: Vec<gtk4::ListBoxRow> = tm
            .iter()
            .enumerate()
            .map(|(i, ws)| create_workspace_row(ws, i))
            .collect();
        (rows, selected)
    };
    // Lock released here — safe to trigger signals

    for (i, row) in rows.iter().enumerate() {
        list_box.append(row);
        if selected_index == Some(i) {
            list_box.select_row(Some(row));
        }
    }
}

/// Create a list box row for a workspace.
fn create_workspace_row(ws: &crate::model::Workspace, index: usize) -> gtk4::ListBoxRow {
    let row = gtk4::ListBoxRow::new();

    let hbox = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
    hbox.set_margin_start(8);
    hbox.set_margin_end(8);
    hbox.set_margin_top(6);
    hbox.set_margin_bottom(6);

    // Workspace index label (1-based)
    let index_label = gtk4::Label::new(Some(&format!("{}", index + 1)));
    index_label.add_css_class("dim-label");
    index_label.add_css_class("caption");
    hbox.append(&index_label);

    // Title
    let title_label = gtk4::Label::new(Some(ws.display_title()));
    title_label.set_hexpand(true);
    title_label.set_halign(gtk4::Align::Start);
    title_label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    hbox.append(&title_label);

    // Unread badge
    if ws.unread_count > 0 {
        let badge = gtk4::Label::new(Some(&ws.unread_count.to_string()));
        badge.add_css_class("badge");
        badge.add_css_class("accent");
        hbox.append(&badge);
    }

    // Git branch indicator
    if let Some(ref git) = ws.git_branch {
        let branch_label = gtk4::Label::new(Some(&git.branch));
        branch_label.add_css_class("dim-label");
        branch_label.add_css_class("caption");
        if git.is_dirty {
            branch_label.add_css_class("warning");
        }
        hbox.append(&branch_label);
    }

    row.set_child(Some(&hbox));
    row
}
