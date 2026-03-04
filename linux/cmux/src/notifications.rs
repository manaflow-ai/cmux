//! Notification store and desktop notification integration.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A notification from a terminal or agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Notification {
    pub id: Uuid,
    pub title: String,
    pub body: String,
    pub source_workspace_id: Option<Uuid>,
    pub source_panel_id: Option<Uuid>,
    pub timestamp: f64,
    pub is_read: bool,
}

/// Notification store — keeps track of all notifications.
#[derive(Debug, Default)]
pub struct NotificationStore {
    notifications: Vec<Notification>,
}

impl NotificationStore {
    pub fn new() -> Self {
        Self {
            notifications: Vec::new(),
        }
    }

    /// Add a notification and optionally send a desktop notification.
    pub fn add(
        &mut self,
        title: &str,
        body: &str,
        workspace_id: Option<Uuid>,
        panel_id: Option<Uuid>,
        send_desktop: bool,
    ) -> Uuid {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        let notification = Notification {
            id: Uuid::new_v4(),
            title: title.to_string(),
            body: body.to_string(),
            source_workspace_id: workspace_id,
            source_panel_id: panel_id,
            timestamp: now,
            is_read: false,
        };

        let id = notification.id;

        if send_desktop {
            send_desktop_notification(title, body);
        }

        self.notifications.push(notification);
        id
    }

    /// Get all notifications.
    pub fn all(&self) -> &[Notification] {
        &self.notifications
    }

    /// Get unread count.
    pub fn unread_count(&self) -> usize {
        self.notifications.iter().filter(|n| !n.is_read).count()
    }

    /// Get unread count for a specific workspace.
    pub fn unread_count_for_workspace(&self, workspace_id: Uuid) -> usize {
        self.notifications
            .iter()
            .filter(|n| !n.is_read && n.source_workspace_id == Some(workspace_id))
            .count()
    }

    /// Mark a notification as read.
    pub fn mark_read(&mut self, id: Uuid) {
        if let Some(n) = self.notifications.iter_mut().find(|n| n.id == id) {
            n.is_read = true;
        }
    }

    /// Mark all notifications as read.
    pub fn mark_all_read(&mut self) {
        for n in &mut self.notifications {
            n.is_read = true;
        }
    }

    /// Clear all notifications.
    pub fn clear(&mut self) {
        self.notifications.clear();
    }
}

/// Send a desktop notification using gio::Notification.
fn send_desktop_notification(title: &str, body: &str) {
    // Use gio::Notification for GNOME-native notifications
    let notification = gio::Notification::new(title);
    notification.set_body(Some(body));

    // The notification needs an Application to send.
    // This will be connected when the GtkApplication is available.
    // For now, log it.
    tracing::info!("Desktop notification: {} - {}", title, body);
}
