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
                assert_eq!(levels.for_event(AgentEvent::PermissionRequest), expected_permission);
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
        for event in [AgentEvent::PermissionRequest, AgentEvent::Question, AgentEvent::TaskComplete]
        {
            assert_eq!(levels.for_event(event), Delivery::Banner);
        }
    }
}

#[test]
fn agent_blocked_delivery_is_opt_in_with_three_levels() {
    assert_eq!(AgentNotificationLevels::default().for_event(AgentEvent::Blocked), Delivery::Off);
    for (value, expected) in [
        (json!("off"), Delivery::Off),
        (json!("badge"), Delivery::Badge),
        (json!("banner"), Delivery::Banner),
        (json!("loud"), Delivery::Off),
        (json!(true), Delivery::Off),
    ] {
        let levels = AgentNotificationLevels::from_settings(
            &json!({"notifications": {"delivery": {"blocked": value}}}),
        );
        assert_eq!(levels.for_event(AgentEvent::Blocked), expected);
        // The other events keep their own levels.
        assert_eq!(levels.for_event(AgentEvent::Question), Delivery::Banner);
    }
}
