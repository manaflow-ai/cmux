//! Sidebar — workspace list using GtkListBox.

use std::path::Path;
use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::{lock_or_recover, AppState};
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
        let tab_manager = lock_or_recover(&state.shared.tab_manager);
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

    let outer = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
    outer.set_margin_start(10);
    outer.set_margin_end(10);
    outer.set_margin_top(8);
    outer.set_margin_bottom(8);

    // 1. Title row: index + title + unread badge
    outer.append(&build_title_row(workspace, index));

    // 2. Status entries (all of them)
    for entry in &workspace.status_entries {
        outer.append(&build_status_label(entry));
    }

    // 3. Git branch
    if let Some(ref branch) = workspace.git_branch {
        outer.append(&build_branch_label(branch));
    }

    // 4. Directory (only if not redundant with branch display)
    let dir = compact_path(&workspace.current_directory);
    if dir != "~" || workspace.git_branch.is_none() {
        outer.append(&build_meta_label(&dir, "sidebar-directory"));
    }

    // 5. Progress
    if let Some(ref progress) = workspace.progress {
        outer.append(&build_progress_widget(progress));
    }

    // 6. Latest log entry
    if let Some(entry) = workspace.log_entries.last() {
        outer.append(&build_log_label(entry));
    }

    // 7. Latest notification
    if let Some(ref notification) = workspace.latest_notification {
        let label = build_meta_label(notification, "sidebar-notification-text");
        if workspace.unread_count > 0 {
            label.add_css_class("sidebar-notification");
        }
        outer.append(&label);
    }

    row.set_child(Some(&outer));
    row
}

fn build_title_row(workspace: &Workspace, index: usize) -> gtk4::Box {
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

    header
}

fn build_status_label(entry: &crate::model::workspace::StatusEntry) -> gtk4::Box {
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 4);
    row.add_css_class("sidebar-status-row");

    // Color dot or icon text
    let icon_text = entry.icon.as_deref().unwrap_or("\u{2022}"); // bullet
    let icon = gtk4::Label::new(Some(icon_text));
    icon.add_css_class("caption");
    if let Some(ref color) = entry.color {
        // Apply inline color via CSS provider
        let css = format!("label {{ color: {}; }}", color);
        let provider = gtk4::CssProvider::new();
        provider.load_from_data(&css);
        icon.style_context().add_provider(
            &provider,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    } else {
        icon.add_css_class("accent");
    }
    row.append(&icon);

    let text = gtk4::Label::new(Some(&format!("{}: {}", entry.key, entry.value)));
    text.set_halign(gtk4::Align::Start);
    text.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    text.add_css_class("caption");
    text.add_css_class("dim-label");
    row.append(&text);

    row
}

fn build_branch_label(branch: &crate::model::panel::GitBranch) -> gtk4::Label {
    let text = if branch.is_dirty {
        format!("\u{2387} {} *", branch.branch) // ⎇
    } else {
        format!("\u{2387} {}", branch.branch)
    };
    let label = gtk4::Label::new(Some(&text));
    label.set_halign(gtk4::Align::Start);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    label.add_css_class("caption");
    label.add_css_class("sidebar-branch");
    label
}

fn build_progress_widget(progress: &crate::model::workspace::Progress) -> gtk4::Box {
    let container = gtk4::Box::new(gtk4::Orientation::Vertical, 1);
    container.add_css_class("sidebar-progress");

    let bar = gtk4::ProgressBar::new();
    bar.set_fraction(progress.value.clamp(0.0, 1.0));
    bar.add_css_class("sidebar-progress-bar");
    container.append(&bar);

    if let Some(ref text) = progress.label {
        let pct = (progress.value * 100.0).round() as u32;
        let label = gtk4::Label::new(Some(&format!("{text} {pct}%")));
        label.set_halign(gtk4::Align::Start);
        label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
        label.add_css_class("caption");
        label.add_css_class("dim-label");
        container.append(&label);
    }

    container
}

fn build_log_label(entry: &crate::model::workspace::LogEntry) -> gtk4::Label {
    let icon = match entry.level.as_str() {
        "success" => "\u{2714}", // ✔
        "warning" => "\u{26A0}", // ⚠
        "error" => "\u{2718}",   // ✘
        "progress" => "\u{25B6}", // ▶
        _ => "\u{2139}",         // ℹ
    };
    let text = format!("{} {}", icon, entry.message);
    let label = gtk4::Label::new(Some(&text));
    label.set_halign(gtk4::Align::Start);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    label.add_css_class("caption");

    let css_class = match entry.level.as_str() {
        "success" => "sidebar-log-success",
        "warning" => "sidebar-log-warning",
        "error" => "sidebar-log-error",
        "progress" => "sidebar-log-progress",
        _ => "dim-label",
    };
    label.add_css_class(css_class);
    label
}

fn build_meta_label(text: &str, css_class: &str) -> gtk4::Label {
    let label = gtk4::Label::new(Some(text));
    label.set_halign(gtk4::Align::Start);
    label.set_wrap(false);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    label.add_css_class("caption");
    label.add_css_class("dim-label");
    label.add_css_class(css_class);
    label
}

fn compact_path(path: &str) -> String {
    if path.is_empty() {
        return "~".to_string();
    }

    if let Ok(home) = std::env::var("HOME") {
        // Guard against HOME="/" where strip_prefix would match any absolute path
        if home != "/" {
            let p = Path::new(path);
            if let Ok(stripped) = p.strip_prefix(&home) {
                let s = stripped.display();
                return if stripped.as_os_str().is_empty() {
                    "~".to_string()
                } else {
                    format!("~/{s}")
                };
            }
        }
    }

    let path = Path::new(path);
    if let Some(name) = path.file_name().and_then(|name| name.to_str()) {
        return name.to_string();
    }

    path.to_string_lossy().into_owned()
}
