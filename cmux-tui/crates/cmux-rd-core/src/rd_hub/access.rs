//! What each approval button tells the hub (`MacScreenApprovalChoice`), what each access level
//! grants (`MacScreenAccess`), the session scopes' titles and the scope Connect Again asks for.

use super::Message;
use serde::{Deserialize, Serialize};

/// A session's scope (the protocol's `view` / `full`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    View,
    #[default]
    Full,
}

impl Scope {
    /// "View Only" or "Full Control".
    pub fn title(self) -> Message {
        match self {
            Scope::View => Message::plain("macScreen.scope.view", "View Only"),
            Scope::Full => Message::plain("macScreen.scope.full", "Full Control"),
        }
    }
}

/// One device's Mac Screen access on one Mac (the protocol's permission scope; the
/// Devices and Mac Screen pickers).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Access {
    None,
    Ask,
    View,
    Full,
}

impl Access {
    /// Every choice, in the pickers' order.
    pub const ALL: [Access; 4] = [Access::None, Access::Ask, Access::View, Access::Full];

    /// The picker's value (the protocol's own name).
    pub fn value(self) -> &'static str {
        match self {
            Access::None => "none",
            Access::Ask => "ask",
            Access::View => "view",
            Access::Full => "full",
        }
    }

    /// The access a picker value names; `None` for anything else.
    pub fn from_value(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.value() == value)
    }

    pub fn title(self) -> Message {
        match self {
            Access::None => Message::plain("macScreen.access.none", "None"),
            Access::Ask => Message::plain("macScreen.access.ask", "Ask"),
            Access::View => Message::plain("macScreen.access.view", "View Only"),
            Access::Full => Message::plain("macScreen.access.full", "Full Control"),
        }
    }

    /// Whether this device may ask the host for a session: not at None, which means the
    /// host blocked it (the hub refuses the request without a prompt).
    pub fn allows_requests(self) -> bool {
        self != Access::None
    }

    /// Whether a session of `requested` starts without a prompt.
    pub fn grants(self, requested: Scope) -> bool {
        match self {
            Access::None | Access::Ask => false,
            Access::View => requested == Scope::View,
            Access::Full => true,
        }
    }
}

/// The scope Connect Again asks for: what the host allows now (Full re-granted asks for
/// Full, View for View), else the last one asked.
pub fn scope_to_request(last: Scope, access: Option<Access>) -> Scope {
    match access {
        Some(Access::Full) => Scope::Full,
        Some(Access::View) => Scope::View,
        _ => last,
    }
}

/// The hub's decision on a pending request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Deny,
    Once,
    Always,
}

/// The host's answers to a request (the approval prompt's buttons).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalChoice {
    Deny,
    Once,
    AlwaysView,
    AlwaysFull,
}

/// What the hub is told for one button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Answer {
    pub decision: Decision,
    /// The session's scope: a decision may lower Full to View, never raise it.
    pub scope: Scope,
    /// A permission to store afterwards when the decision alone cannot.
    pub then_permission: Option<Access>,
}

impl ApprovalChoice {
    pub const ALL: [ApprovalChoice; 4] = [
        ApprovalChoice::Deny,
        ApprovalChoice::Once,
        ApprovalChoice::AlwaysView,
        ApprovalChoice::AlwaysFull,
    ];

    /// The answer for a request of `requested` (Always Allow Full Control on a View
    /// request: the session stays View, the permission becomes Full).
    pub fn answer(self, requested: Scope) -> Answer {
        let (decision, scope, then_permission) = match self {
            ApprovalChoice::Deny => (Decision::Deny, requested, None),
            ApprovalChoice::Once => (Decision::Once, requested, None),
            ApprovalChoice::AlwaysView => (Decision::Always, Scope::View, None),
            ApprovalChoice::AlwaysFull if requested == Scope::Full => {
                (Decision::Always, Scope::Full, None)
            }
            ApprovalChoice::AlwaysFull => (Decision::Always, Scope::View, Some(Access::Full)),
        };
        Answer { decision, scope, then_permission }
    }

    /// The prompt's button title.
    pub fn title(self) -> Message {
        match self {
            ApprovalChoice::Deny => Message::plain("macScreen.approval.deny", "Deny"),
            ApprovalChoice::Once => Message::plain("macScreen.approval.once", "Allow Once"),
            ApprovalChoice::AlwaysView => {
                Message::plain("macScreen.approval.alwaysView", "Always Allow View Only")
            }
            ApprovalChoice::AlwaysFull => {
                Message::plain("macScreen.approval.alwaysFull", "Always Allow Full Control")
            }
        }
    }
}

/// The device hub box's line while the hub has not started.
pub fn hub_startup_message(startup_failed: bool) -> Option<Message> {
    startup_failed.then_some(Message::plain(
        "devices.status.failed",
        "Couldn’t reach the device hub. cmux keeps trying.",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn answer(choice: ApprovalChoice, requested: Scope) -> String {
        let a = choice.answer(requested);
        let name = |v: serde_json::Value| v.as_str().unwrap_or("-").to_owned();
        format!(
            "{}/{}/{}",
            name(serde_json::to_value(a.decision).unwrap()),
            name(serde_json::to_value(a.scope).unwrap()),
            a.then_permission.map_or("-", Access::value)
        )
    }

    // MacScreenHubTests.eachButtonTellsTheHubTheRightDecisionAndScope
    #[test]
    fn each_button_tells_the_hub_the_right_decision_and_scope() {
        use ApprovalChoice::*;
        assert_eq!(answer(Deny, Scope::Full), "deny/full/-");
        assert_eq!(answer(Once, Scope::View), "once/view/-");
        assert_eq!(answer(Once, Scope::Full), "once/full/-");
        assert_eq!(answer(AlwaysView, Scope::Full), "always/view/-");
        assert_eq!(answer(AlwaysView, Scope::View), "always/view/-");
        assert_eq!(answer(AlwaysFull, Scope::Full), "always/full/-");
        assert_eq!(answer(AlwaysFull, Scope::View), "always/view/full");
        assert_eq!(serde_json::to_value(AlwaysFull).unwrap(), "always_full");
        for c in ApprovalChoice::ALL {
            assert!(!c.title().text.is_empty());
        }
    }

    // MacScreenAccessTests.pickerValuesAreTheProtocolsScopes
    #[test]
    fn picker_values_are_the_protocols_scopes() {
        let values: Vec<_> = Access::ALL.iter().map(|a| a.value()).collect();
        assert_eq!(values, ["none", "ask", "view", "full"]);
        for access in Access::ALL {
            assert_eq!(Access::from_value(access.value()), Some(access));
            assert!(!access.title().text.is_empty());
            assert_eq!(serde_json::to_value(access).unwrap(), access.value());
        }
        assert_eq!(Access::from_value("admin"), None);
    }

    // MacScreenAccessTests.whatEachAccessGrantsWithoutAPrompt, noAskForAccessAtNone
    #[test]
    fn what_each_access_grants_without_a_prompt() {
        assert!(!Access::None.grants(Scope::View));
        assert!(!Access::Ask.grants(Scope::View));
        assert!(Access::View.grants(Scope::View));
        assert!(!Access::View.grants(Scope::Full));
        assert!(Access::Full.grants(Scope::Full));
        assert!(!Access::None.allows_requests());
        assert!(Access::Ask.allows_requests() && Access::View.allows_requests());
        assert!(Access::Full.allows_requests());
    }

    // MacScreenHubViewerTests.connectAgainFollowsTheCurrentPermission
    #[test]
    fn connect_again_follows_the_current_permission() {
        assert_eq!(scope_to_request(Scope::View, Some(Access::Full)), Scope::Full);
        assert_eq!(scope_to_request(Scope::Full, Some(Access::View)), Scope::View);
        assert_eq!(scope_to_request(Scope::Full, Some(Access::Ask)), Scope::Full);
        assert_eq!(scope_to_request(Scope::View, None), Scope::View);
    }

    #[test]
    fn titles_and_startup_message() {
        assert_eq!(Scope::View.title().text, "View Only");
        assert_eq!(Scope::Full.title().key, "macScreen.scope.full");
        assert_eq!(hub_startup_message(false), None);
        assert_eq!(hub_startup_message(true).unwrap().key, "devices.status.failed");
    }
}
