use super::*;

fn server(status: i64, code: &str, message: &str) -> HubError {
    HubError::Server { status, code: code.into(), message: message.into() }
}

// MacScreenHubTests.endReasonsReadTheProtocolsAuthoritativeReasons
#[test]
fn end_reasons_read_the_protocols_authoritative_reasons() {
    let cases = [
        ("permission_revoked", EndReason::PermissionRevoked),
        ("permission_changed", EndReason::PermissionRevoked),
        ("host_revoked", EndReason::PermissionRevoked),
        ("device_removed:viewer", EndReason::ViewerRemoved),
        ("device_removed:host", EndReason::HostRemoved),
        ("device_removed", EndReason::DeviceRemoved),
        ("sharing_off", EndReason::SharingOff),
        ("host_stopped", EndReason::HostStopped),
        ("viewer_disconnected", EndReason::ViewerDisconnected),
        ("tab_closed", EndReason::ViewerDisconnected),
        ("signed_out", EndReason::SignedOut),
        ("signed_out:quit", EndReason::SignedOut),
        ("peer_offline", EndReason::PeerOffline),
        ("failed", EndReason::Failed),
        ("expired", EndReason::Expired),
        ("approve_failed", EndReason::ApproveFailed),
        ("consent_required", EndReason::ConsentRequired),
        ("moved", EndReason::Moved),
        ("bye", EndReason::Other),
    ];
    for (text, reason) in cases {
        assert_eq!(EndReason::parse(Some(text)), reason, "{text}");
    }
    assert_eq!(EndReason::parse(None), EndReason::Other);
    assert!(EndReason::ApproveFailed.message().english("Mac mini 2").contains("Mac mini 2"));
    assert_eq!(HubReason::HostStopped.raw(), "host_stopped");
    assert_eq!(HubReason::ViewerDisconnected.raw(), "viewer_disconnected");
    assert_eq!(HubReason::SignedOut.raw(), "signed_out");
    // The serde names are the raw values.
    assert_eq!(serde_json::to_value(HubReason::ConsentRequired).unwrap(), "consent_required");
}

// MacScreenHubTests.endTextsNameTheHost
#[test]
fn end_texts_name_the_host() {
    for reason in [
        EndReason::PermissionRevoked,
        EndReason::HostRemoved,
        EndReason::SharingOff,
        EndReason::HostStopped,
        EndReason::PeerOffline,
    ] {
        assert!(reason.message().english("Mac mini 2").contains("Mac mini 2"));
    }
    assert_ne!(EndReason::HostStopped.message(), EndReason::Other.message());
    assert!(
        EndReason::PermissionRevoked.removes_access() && EndReason::ViewerRemoved.removes_access()
    );
    assert!(!EndReason::HostStopped.removes_access() && !EndReason::SharingOff.removes_access());
    // Every key is distinct, and a named text has its `%@`.
    let mut keys: Vec<_> = EndReason::ALL.iter().map(|r| r.message().key).collect();
    keys.sort_unstable();
    keys.dedup();
    assert_eq!(keys.len(), EndReason::ALL.len());
    for r in EndReason::ALL {
        assert_eq!(r.message().names, r.message().text.contains("%@"));
    }
}

// MacScreenHubTests.reGrantedAccessIsNotRemoved, removedDevicesOfferNoReconnect
#[test]
fn reconnect_and_removed_access() {
    assert!(!EndReason::AccessChanged.removes_access() && EndReason::AccessChanged.can_reconnect());
    assert!(!EndReason::HostRemoved.can_reconnect() && !EndReason::ViewerRemoved.can_reconnect());
    assert!(!EndReason::DeviceRemoved.can_reconnect());
    assert!(EndReason::HostStopped.can_reconnect() && EndReason::PermissionRevoked.can_reconnect());
}

// MacScreenFailureReasonTests.theHubsFailedEndCarriesTheHostsReason
#[test]
fn the_hubs_failed_end_carries_the_hosts_reason() {
    assert_eq!(
        EndReason::parse(Some("failed: no Screen Sharing helper: none installed")),
        EndReason::Failed
    );
    assert_eq!(EndReason::parse(Some("failed")), EndReason::Failed);
    assert_eq!(
        EndReason::failure_detail(Some("failed: the screen host stopped")).as_deref(),
        Some("the screen host stopped")
    );
    assert_eq!(EndReason::failure_detail(Some("failed")).as_deref(), Some(""));
    assert_eq!(EndReason::failure_detail(Some("host_stopped")), None);
    assert_eq!(EndReason::failure_detail(None), None);
    // `failedx` is neither `failed` nor `failed:`.
    assert_eq!(EndReason::parse(Some("failedx")), EndReason::Other);
}

// MacScreenFailureReasonTests.theHostsEndTextFitsTheHub
#[test]
fn the_hosts_end_text_fits_the_hub() {
    assert_eq!(HubReason::failure(""), "failed");
    assert_eq!(
        HubReason::failure("the screen host could not start: x"),
        "failed: the screen host could not start: x"
    );
    assert_eq!(HubReason::failure("failed: capture\nline two"), "failed: capture line two");
    let long = HubReason::failure(&"é".repeat(300));
    assert!(long.encode_utf16().count() <= HUB_REASON_LIMIT);
    assert!(long.starts_with("failed: é"));
    assert_eq!(long.encode_utf16().count(), HUB_REASON_LIMIT);
    // Round trip: the viewer reads back what the host sent.
    assert_eq!(
        EndReason::failure_detail(Some(&HubReason::failure("capture: denied"))).as_deref(),
        Some("capture: denied")
    );
    // A leading `failed:` is never doubled, control characters go, blanks trim.
    assert_eq!(HubReason::failure(" failed: failed:  x\u{7}\u{200B}y \t"), "failed: xy");
    assert_eq!(HubReason::failure("failed:"), "failed");
    // A surrogate pair never splits at the limit.
    let emoji = HubReason::failure(&"😀".repeat(60));
    assert_eq!((emoji.encode_utf16().count(), emoji.chars().count()), (100, 8 + 46));
    let odd = HubReason::failure(&format!("a{}", "😀".repeat(60)));
    assert_eq!(odd.encode_utf16().count(), 99);
}

// MacScreenHubTests.refusalsFollowTheProtocolsCodes
#[test]
fn refusals_follow_the_protocols_codes() {
    let refusal = |code: &str, status: i64| Refusal::from_error(&server(status, code, ""));
    assert_eq!(refusal("permission_none", 403), Refusal::PermissionNone);
    assert_eq!(refusal("scope_exceeds_permission", 403), Refusal::ScopeExceeds);
    assert_eq!(refusal("host_offline", 409), Refusal::HostOffline);
    assert_eq!(refusal("not_shared", 403), Refusal::NotShared);
    assert_eq!(refusal("not_found", 404), Refusal::NotFound);
    assert_eq!(refusal("device_removed", 410), Refusal::NotFound);
    assert_eq!(refusal("unauthorized", 401), Refusal::NotSignedIn);
    assert_eq!(refusal("internal", 500), Refusal::Other { reason: Some("internal".into()) });
    assert_eq!(Refusal::from_error(&HubError::NotSignedIn), Refusal::NotSignedIn);
    assert_eq!(Refusal::from_error(&HubError::NotConfigured), Refusal::NotSignedIn);
    assert_eq!(
        Refusal::from_error(&HubError::Transport { detail: "offline".into() }),
        Refusal::Other { reason: Some("offline".into()) }
    );
}

// MacScreenHubTests.anUnknownRefusalKeepsTheHubsReason, notFoundOffersNoRetry
#[test]
fn an_unknown_refusal_keeps_the_hubs_reason() {
    let rate_limited =
        Refusal::from_error(&server(429, "rate_limited", "too many requests; wait a minute"));
    assert_eq!(
        rate_limited,
        Refusal::Other { reason: Some("too many requests; wait a minute".into()) }
    );
    assert_eq!(
        Refusal::from_error(&server(403, "new_code", " ")),
        Refusal::Other { reason: Some("new_code".into()) }
    );
    assert_eq!(
        Refusal::from_error(&HubError::Http { status: 502 }),
        Refusal::Other { reason: Some("HTTP 502".into()) }
    );
    assert_eq!(
        Refusal::from_error(&HubError::Decoding { detail: "missing session".into() }),
        Refusal::Other { reason: Some("missing session".into()) }
    );
    assert_eq!(
        Refusal::from_error(&HubError::Transport { detail: String::new() }),
        Refusal::Other { reason: None }
    );
    assert!(rate_limited.can_retry());
    assert!(!Refusal::NotFound.can_retry());
    assert!(Refusal::HostOffline.can_retry() && Refusal::NotShared.can_retry());
    let json = serde_json::to_value(&rate_limited).unwrap();
    assert_eq!(
        json,
        serde_json::json!({"refusal": "other", "reason": "too many requests; wait a minute"})
    );
    let error: HubError = serde_json::from_value(
        serde_json::json!({"error": "server", "status": 409, "code": "host_offline", "message": ""}),
    )
    .unwrap();
    assert_eq!(Refusal::from_error(&error), Refusal::HostOffline);
}
