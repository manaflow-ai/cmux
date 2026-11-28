//! Agent notification levels are applied before a producer adds an unread item.
//! Ordinary errors, plan reviews and cache reminders keep their existing delivery.
//! `Blocked` is the one opt-in event: a report (screen detection, a plugin, the
//! socket) that turns an agent Blocked with no hook alert of its own posts only
//! when `notifications.delivery.blocked` is `badge` or `banner`.
use serde_json::Value;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AgentEvent {
    PermissionRequest,
    Question,
    TaskComplete,
    Blocked,
}

impl AgentEvent {
    pub(super) fn from_hook(kind: &str) -> Option<Self> {
        match kind {
            "agent.approval.requested" => Some(Self::PermissionRequest),
            "agent.question.requested" => Some(Self::Question),
            "agent.turn.completed" => Some(Self::TaskComplete),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum Delivery {
    Off,
    Badge,
    #[default]
    Banner,
}

#[derive(Clone, Copy)]
pub(super) struct AgentNotificationLevels {
    permission_request: Delivery,
    question: Delivery,
    task_complete: Delivery,
    blocked: Delivery,
}

impl Default for AgentNotificationLevels {
    /// The levels of an empty settings file: every event at its default.
    fn default() -> Self {
        Self::from_settings(&Value::Null)
    }
}

impl AgentNotificationLevels {
    pub(super) fn from_settings(root: &Value) -> Self {
        let level = |key: &str| {
            root.pointer("/notifications/delivery")
                .and_then(|levels| levels.get(key))
                .and_then(Value::as_str)
        };
        let request = |key: &str| match level(key) {
            Some("off") => Delivery::Off,
            Some("badge") => Delivery::Badge,
            _ => Delivery::Banner,
        };
        Self {
            permission_request: request("permissionRequest"),
            question: request("question"),
            task_complete: if level("taskComplete") == Some("off") {
                Delivery::Off
            } else {
                Delivery::Banner
            },
            blocked: match level("blocked") {
                Some("badge") => Delivery::Badge,
                Some("banner") => Delivery::Banner,
                _ => Delivery::Off,
            },
        }
    }

    pub(super) fn for_event(self, event: AgentEvent) -> Delivery {
        match event {
            AgentEvent::PermissionRequest => self.permission_request,
            AgentEvent::Question => self.question,
            AgentEvent::TaskComplete => self.task_complete,
            AgentEvent::Blocked => self.blocked,
        }
    }
}

#[cfg(test)]
#[path = "agent_notification_delivery_tests.rs"]
mod tests;
