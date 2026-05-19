#![allow(dead_code)]

//! `FreeDesktop` notification integration for Linux desktops.

use notify_rust::{Notification, NotificationHandle};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentNotification {
    pub title: String,
    pub body: String,
    pub workspace_id: Option<String>,
}

impl AgentNotification {
    #[must_use]
    pub fn waiting_for_input(agent_name: &str, workspace_title: &str) -> Self {
        Self {
            title: format!("{agent_name} needs input"),
            body: format!("{workspace_title} is waiting for your response."),
            workspace_id: None,
        }
    }

    #[must_use]
    pub fn waiting_for_input_in_workspace(
        agent_name: &str,
        workspace_id: impl Into<String>,
        workspace_title: &str,
    ) -> Self {
        Self {
            workspace_id: Some(workspace_id.into()),
            ..Self::waiting_for_input(agent_name, workspace_title)
        }
    }
}

pub trait Notifier {
    type Handle;
    type Error;

    fn notify(&self, notification: &AgentNotification) -> Result<Self::Handle, Self::Error>;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct FreedesktopNotifier;

impl Notifier for FreedesktopNotifier {
    type Handle = NotificationHandle;
    type Error = notify_rust::error::Error;

    fn notify(&self, notification: &AgentNotification) -> Result<Self::Handle, Self::Error> {
        Notification::new()
            .appname("cmux")
            .summary(&notification.title)
            .body(&notification.body)
            .icon("cmux")
            .show()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waiting_notification_includes_context() {
        let notification = AgentNotification::waiting_for_input("Claude", "api refactor");
        assert_eq!(notification.title, "Claude needs input");
        assert!(notification.body.contains("api refactor"));
    }

    #[test]
    fn waiting_notification_can_include_workspace_id() {
        let notification =
            AgentNotification::waiting_for_input_in_workspace("Codex", "workspace-1", "tests");
        assert_eq!(notification.workspace_id.as_deref(), Some("workspace-1"));
    }
}
