//! Sidebar — workspace list using GtkListBox.

use std::path::Path;
use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::AppState;
use crate::model::Workspace;

pub struct SidebarWidgets {
    pub root: gtk4::Box,
    pub list_box: gtk4::ListBox,
}

/// Create the sidebar widget containing the workspace list.
pub fn create_sidebar(state: &Rc<AppState>) -> SidebarWidgets {
    let sidebar_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    sidebar_box.add_css_class("sidebar");

    let scrolled = gtk4::ScrolledWindow::new();
    scrolled.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
    scrolled.set_vexpand(true);

    let list_box = gtk4::ListBox::new();
    list_box.set_selection_mode(gtk4::SelectionMode::Single);
    list_box.add_css_class("navigation-sidebar");

    refresh_sidebar(&list_box, state);

    scrolled.set_child(Some(&list_box));
    sidebar_box.append(&scrolled);

    SidebarWidgets {
        root: sidebar_box,
        list_box,
    }
}

/// Refresh the workspace list from shared state.
pub fn refresh_sidebar(list_box: &gtk4::ListBox, state: &Rc<AppState>) {
    while let Some(child) = list_box.first_child() {
        list_box.remove(&child);
    }

    // Build rows and capture selection index while holding the lock, then
    // release the lock before calling list_box.select_row.  select_row emits
    // `row-selected` synchronously; the connected handler tries to acquire
    // the same tab_manager lock, which would deadlock on std::sync::Mutex.
    let (rows, selected_index): (Vec<gtk4::ListBoxRow>, Option<usize>) = {
        let tab_manager = state.shared.tab_manager.lock().unwrap();
        let selected_index = tab_manager.selected_index();
        let rows = tab_manager
            .iter()
            .enumerate()
            .map(|(index, workspace)| create_workspace_row(workspace, index))
            .collect();
        (rows, selected_index)
    };

    for (index, row) in rows.iter().enumerate() {
        list_box.append(row);
        if selected_index == Some(index) {
            list_box.select_row(Some(row));
        }
    }
}

fn create_workspace_row(workspace: &Workspace, index: usize) -> gtk4::ListBoxRow {
    let row = gtk4::ListBoxRow::new();
    row.add_css_class("workspace-row");

    let outer = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
    outer.set_margin_start(10);
    outer.set_margin_end(10);
    outer.set_margin_top(8);
    outer.set_margin_bottom(8);

    let header = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);

    let index_label = gtk4::Label::new(Some(&format!("{}", index + 1)));
    index_label.add_css_class("dim-label");
    index_label.add_css_class("caption");
    header.append(&index_label);

    let title_label = gtk4::Label::new(Some(workspace.display_title()));
    title_label.set_hexpand(true);
    title_label.set_halign(gtk4::Align::Start);
    title_label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    header.append(&title_label);

    if workspace.unread_count > 0 {
        let badge = gtk4::Label::new(Some(&workspace.unread_count.to_string()));
        badge.add_css_class("badge");
        badge.add_css_class("accent");
        header.append(&badge);
    }

    outer.append(&header);

    let meta_label = gtk4::Label::new(Some(&workspace_meta_text(workspace)));
    meta_label.set_halign(gtk4::Align::Start);
    meta_label.set_wrap(false);
    meta_label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    meta_label.add_css_class("caption");
    meta_label.add_css_class("dim-label");
    outer.append(&meta_label);

    let notification_text = workspace
        .latest_notification
        .clone()
        .unwrap_or_else(|| compact_path(&workspace.current_directory));
    let notification_label = gtk4::Label::new(Some(&notification_text));
    notification_label.set_halign(gtk4::Align::Start);
    notification_label.set_wrap(false);
    notification_label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    notification_label.add_css_class("caption");
    if workspace.unread_count > 0 {
        notification_label.add_css_class("sidebar-notification");
    } else {
        notification_label.add_css_class("dim-label");
    }
    outer.append(&notification_label);

    row.set_child(Some(&outer));
    row
}

fn workspace_meta_text(workspace: &Workspace) -> String {
    let mut parts = Vec::new();

    if let Some(status) = workspace.sidebar_status_label() {
        parts.push(status.to_string());
    }

    if let Some(git_branch) = &workspace.git_branch {
        parts.push(if git_branch.is_dirty {
            format!("git {} *", git_branch.branch)
        } else {
            format!("git {}", git_branch.branch)
        });
    } else {
        parts.push(compact_path(&workspace.current_directory));
    }

    parts.join(" | ")
}

fn compact_path(path: &str) -> String {
    if path.is_empty() {
        return "/".to_string();
    }

    if let Ok(home) = std::env::var("HOME") {
        if let Some(stripped) = path.strip_prefix(&home) {
            return format!("~{}", stripped);
        }
    }

    let path = Path::new(path);
    if let Some(name) = path.file_name().and_then(|name| name.to_str()) {
        return name.to_string();
    }

    path.to_string_lossy().into_owned()
}
