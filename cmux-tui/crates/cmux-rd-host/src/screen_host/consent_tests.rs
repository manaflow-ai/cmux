use super::*;

fn request(scope: &str) -> Request {
    Request {
        id: "s1".into(),
        viewer_id: "v".into(),
        viewer_name: "Mac".into(),
        viewer_key_fingerprint: None,
        scope: scope.into(),
        received_ms: 1_000,
    }
}

#[test]
fn a_request_is_never_answered_without_the_person() {
    assert_eq!(on_request(&request("view")), OnRequest::AskThePerson);
    assert_eq!(on_request(&request("full")), OnRequest::AskThePerson);
}

#[test]
fn decisions_never_raise_the_scope_or_pass_local_consent() {
    let all = LocalConsent { view: true, full: true };
    assert_eq!(decision_scope(&request("full"), None, all, true).as_deref(), Ok("full"));
    assert_eq!(decision_scope(&request("full"), Some("view"), all, true).as_deref(), Ok("view"));
    assert!(decision_scope(&request("view"), Some("full"), all, true).is_err());
    assert!(decision_scope(&request("view"), Some("none"), all, true).is_err());
    let view_only = LocalConsent { view: true, full: false };
    assert!(decision_scope(&request("full"), None, view_only, true).is_err());
    assert_eq!(
        decision_scope(&request("full"), Some("view"), view_only, true).as_deref(),
        Ok("view")
    );
}

#[test]
fn local_consent_maps_ticket_scopes() {
    assert_eq!(LocalConsent::default().serve("view", true), Some(true));
    assert_eq!(LocalConsent::default().serve("full", true), None);
    assert_eq!(LocalConsent { view: true, full: true }.serve("full", true), Some(false));
    assert_eq!(LocalConsent { view: true, full: false }.serve("full", true), None);
    assert_eq!(LocalConsent::default().serve("control", true), None);
}

#[test]
fn a_host_that_applies_no_input_serves_and_offers_view_only() {
    // The Wayland portal capture drops every input event: a control session would
    // promise what it does not do.
    let all = LocalConsent { view: true, full: true };
    assert_eq!(all.serve("full", false), Some(true));
    assert_eq!(all.serve("view", false), Some(true));
    assert_eq!(LocalConsent::default().serve("full", false), None);
    // Approving a request for control offers view.
    assert_eq!(decision_scope(&request("full"), None, all, false).as_deref(), Ok("view"));
    assert_eq!(decision_scope(&request("full"), Some("view"), all, false).as_deref(), Ok("view"));
    let refused = decision_scope(&request("full"), Some("full"), all, false).unwrap_err();
    assert!(refused.contains("--scope view"), "{refused}");
}

#[test]
fn pending_requests_expire_and_are_private() {
    let dir = std::env::temp_dir().join(format!("cmux-screen-host-pending-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let pending = Pending::new(&dir);
    pending.add(request("view"), 1_000).unwrap();
    assert_eq!(pending.list(2_000).unwrap().len(), 1);
    assert!(pending.list(1_000 + REQUEST_TTL_MS).unwrap().is_empty());
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let mode = std::fs::metadata(dir.join("requests.json")).unwrap().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    assert_eq!(pending.remove("s1", 2_000).unwrap().map(|r| r.id), Some("s1".into()));
    assert!(pending.list(2_000).unwrap().is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}
