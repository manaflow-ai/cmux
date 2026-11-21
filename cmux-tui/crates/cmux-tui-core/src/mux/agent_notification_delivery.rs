//! Agent notification levels are applied before a producer adds an unread item.
//! Ordinary errors, plan reviews and cache reminders keep their existing delivery.
use serde_json::Value;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AgentEvent {
    PermissionRequest,
    Question,
    TaskComplete,
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

#[derive(Clone, Copy, Default)]
pub(super) struct AgentNotificationLevels {
    permission_request: Delivery,
    question: Delivery,
    task_complete: Delivery,
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
        }
    }

    pub(super) fn for_event(self, event: AgentEvent) -> Delivery {
        match event {
            AgentEvent::PermissionRequest => self.permission_request,
            AgentEvent::Question => self.question,
            AgentEvent::TaskComplete => self.task_complete,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn agent_delivery_settings_allow_all_eighteen_independent_combinations() {
        let choices =
            [("off", Delivery::Off), ("badge", Delivery::Badge), ("banner", Delivery::Banner)];
        for (permission, expected_permission) in choices {
            for (question, expected_question) in choices {
                for (completion, expected_completion) in
                    [("off", Delivery::Off), ("banner", Delivery::Banner)]
                {
                    let levels = AgentNotificationLevels::from_settings(&json!({
                        "notifications": {"delivery": {"permissionRequest": permission, "question": question, "taskComplete": completion}}
                    }));
                    assert_eq!(
                        levels.for_event(AgentEvent::PermissionRequest),
                        expected_permission
                    );
                    assert_eq!(levels.for_event(AgentEvent::Question), expected_question);
                    assert_eq!(levels.for_event(AgentEvent::TaskComplete), expected_completion);
                }
            }
        }
    }

    #[test]
    fn agent_delivery_leaves_unconfigured_and_unsupported_choices_at_normal_delivery() {
        for root in [json!({}), json!({"notifications":{"delivery":{"taskComplete":"badge"}}})] {
            let levels = AgentNotificationLevels::from_settings(&root);
            for event in
                [AgentEvent::PermissionRequest, AgentEvent::Question, AgentEvent::TaskComplete]
            {
                assert_eq!(levels.for_event(event), Delivery::Banner);
            }
        }
    }
}
