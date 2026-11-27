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
