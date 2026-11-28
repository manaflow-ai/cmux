//! Ported from `MacScreenHubTests.swift` (`MacScreenDevicesSettingsTests`) and `MacScreenQuietCardTests`.
use super::*;

const HOST: &str = "host-1";

fn names() -> HashMap<String, String> {
    [(HOST.to_owned(), "Studio".to_owned()), ("v1".to_owned(), "Laptop".to_owned())].into()
}

fn entry(
    id: &str,
    event: &str,
    viewer: Option<&str>,
    host: Option<&str>,
    detail: Option<&str>,
) -> AuditEntry {
    AuditEntry {
        id: id.into(),
        event: event.into(),
        viewer_id: viewer.map(Into::into),
        host_id: host.map(Into::into),
        detail: detail.map(Into::into),
        ..Default::default()
    }
}

fn row(e: &AuditEntry) -> HistoryRow {
    history_row(e, &names())
}

#[test]
fn history_rows_show_metadata_as_people_read_it() {
    let mut ended = entry("e1", "ended", Some("v1"), Some(HOST), Some("bye"));
    ended.scope = Some("full".into());
    ended.duration_s = Some(1347.0);
    let r = row(&ended);
    assert_eq!((r.device.english(), r.host.english()), ("Laptop".into(), "Studio".into()));
    assert_eq!(r.duration, "22m 27s");
    assert!(r.event == "ended" && !r.event_text.english().is_empty());
    assert_eq!(r.scope, Words::t("macScreen.scope.full", "Full Control"));

    let changed = entry("e2", "permission_changed", Some("gone"), Some(HOST), Some("ask->full"));
    let r = row(&changed);
    assert_eq!(r.detail.english(), "Ask → Full Control");
    assert_eq!(r.device, history_row(&changed, &HashMap::new()).device);
    assert!(r.duration.is_empty());

    let stopped = entry("e3", "ended", Some("v1"), Some(HOST), Some("host_stopped"));
    assert!(row(&stopped).detail.english().contains("Studio"));
    // A removed device no longer listed: never "Removed device was removed".
    let unknown =
        row(&entry("e6", "ended", Some("gone"), Some(HOST), Some("device_removed:viewer")));
    assert!(!unknown.detail.english().contains(&unknown.device.english()));
    let removed = entry("e4", "ended", Some("v1"), Some(HOST), Some("device_removed:viewer"));
    assert!(row(&removed).detail.english().contains("Laptop"));
    let disconnected = entry("e5", "ended", Some("v1"), Some(HOST), Some("viewer_disconnected"));
    assert!(row(&disconnected).detail.english().contains("Laptop"));
    // A removed device's name comes from the entry when no list knows it.
    let mut gone =
        entry("e11", "ended", Some("gone-id"), Some(HOST), Some("device_removed:viewer"));
    gone.viewer_name = Some("Old Laptop".into());
    let r = row(&gone);
    assert!(r.device.english() == "Old Laptop" && r.detail.english().contains("Old Laptop"));
    // The backend names the device in deviceId.
    let joined = AuditEntry {
        device_id: Some("v1".into()),
        ..entry("e9", "device_added", None, None, None)
    };
    let r = row(&joined);
    assert!(r.detail.english().contains("Laptop") && r.device.english() == "Laptop");
    let bye = entry("e10", "ended", Some("v1"), Some(HOST), Some("bye"));
    assert!(!row(&bye).detail.english().is_empty());
    let added = row(&entry("e7", "device_added", None, Some("v1"), None));
    assert!(added.detail.english().contains("Laptop") && !added.event_text.english().is_empty());
    assert_eq!(added.tone, "success");
    let left = entry("e8", "device_removed", Some("v1"), None, None);
    assert!(row(&left).detail.english().contains("Laptop"));
    assert_eq!(duration_text(8.0), "8s");
    assert_eq!(duration_text(3840.0), "1h 4m");
}

#[test]
fn audit_entries_read_the_hubs_json() {
    let e: AuditEntry = serde_json::from_value(serde_json::json!({
        "id": "e1", "event": "ended", "viewerId": "v1", "hostId": "h", "duration_s": 8.0, "ts": "2026-01-01T00:00:00Z"
    }))
    .unwrap();
    assert_eq!((e.viewer_id.as_deref(), e.duration_s), (Some("v1"), Some(8.0)));
}

#[test]
fn relay_drafts_keep_the_saved_secret_only_when_left_empty() {
    let draft = |mode: &str,
                 secret: Option<&str>,
                 username: Option<&str>,
                 password: Option<&str>| RelayDraft {
        id: Some("r1".into()),
        name: "Home".into(),
        urls: vec![
            " turns:turn.example.com:5349 ".into(),
            "".into(),
            "turn:turn.example.com:3478?transport=udp".into(),
        ],
        mode: mode.into(),
        secret: secret.map(Into::into),
        username: username.map(Into::into),
        password: password.map(Into::into),
        enabled: true,
        priority: 0,
    };
    let shared = |s: &str| RelaySecret::SharedSecret { secret: s.into() };
    let stat = |u: &str, p: &str| RelaySecret::Static { username: u.into(), password: p.into() };
    assert_eq!(
        draft_secret(&draft("shared_secret", Some("s3cret"), None, None), None),
        Some(shared("s3cret"))
    );
    assert_eq!(
        draft_secret(&draft("shared_secret", None, None, None), Some(&shared("old"))),
        Some(shared("old"))
    );
    assert_eq!(
        draft_secret(&draft("shared_secret", None, None, None), Some(&stat("u", "p"))),
        None
    );
    assert_eq!(
        draft_secret(&draft("static", None, Some("u"), Some("p")), None),
        Some(stat("u", "p"))
    );
    assert_eq!(draft_secret(&draft("static", None, Some("u"), None), None), None);
    assert_eq!(
        draft_secret(&draft("static", None, None, None), Some(&stat("a", "b"))),
        Some(stat("a", "b"))
    );
    assert_eq!(
        draft_urls(&draft("static", None, None, None)),
        ["turns:turn.example.com:5349", "turn:turn.example.com:3478?transport=udp"]
    );
    let ok = validate_relay(&draft("shared_secret", Some("s"), None, None), None).unwrap();
    assert_eq!((ok.name.as_str(), ok.urls.len()), ("Home", 2));
    let bad_url = RelayDraft {
        urls: vec!["https://x".into()],
        ..draft("shared_secret", Some("s"), None, None)
    };
    assert_eq!(
        validate_relay(&bad_url, None).unwrap_err().key.as_deref(),
        Some("devices.error.urls")
    );
    let no_name = RelayDraft { name: "  ".into(), ..draft("static", None, None, None) };
    assert_eq!(
        validate_relay(&no_name, None).unwrap_err().key.as_deref(),
        Some("devices.error.name")
    );
    assert_eq!(
        validate_relay(&draft("static", None, None, None), None).unwrap_err().key.as_deref(),
        Some("devices.error.credentials")
    );
}

#[test]
fn check_relay_outcomes_read_as_success_or_failure() {
    assert_eq!(check_result(CheckOutcome::Relayed).tone, "success");
    assert_eq!(check_result(CheckOutcome::NoRelayCandidate).tone, "danger");
    assert_eq!(check_result(CheckOutcome::Failed).tone, "danger");
    let texts: std::collections::HashSet<_> = [
        CheckOutcome::RefusedCredentials,
        CheckOutcome::Unreachable,
        CheckOutcome::NoRelayCandidate,
    ]
    .map(|o| check_result(o).text.english())
    .into();
    assert_eq!(texts.len(), 3);
}

#[test]
fn a_redial_is_held_and_a_link_that_will_not_come_back_is_not() {
    assert!(redials(Connection::Reconnecting));
    assert!(!redials(Connection::Removed), "a link that will not come back is never held");
    assert!(!redialing(HubStatus::Starting, Connection::Connecting));
    assert_eq!(hub_status(HubStatus::Ready, Connection::Connected).tone, "success");
    assert_eq!(
        hub_status(HubStatus::Ready, Connection::Reconnecting).text.key.as_deref(),
        Some("devices.status.connecting")
    );
    assert_eq!(hub_status(HubStatus::Failed, Connection::Connected).tone, "danger");
}

#[test]
fn the_card_without_a_hub() {
    assert!(!no_hub_card(&NoHub::default()).available);
    let failed = no_hub_card(&NoHub {
        configured: true,
        startup_message: Some("x".into()),
        ..Default::default()
    });
    assert_eq!(
        (failed.status.tone.as_str(), failed.startup_error.as_deref()),
        ("danger", Some("x"))
    );
    let loading = no_hub_card(&NoHub { configured: true, restoring: true, ..Default::default() });
    assert_eq!(loading.status.text.key.as_deref(), Some("macScreen.home.devicesLoading"));
    let left = no_hub_card(&NoHub { configured: true, can_sign_in: true, ..Default::default() });
    assert!(left.sign_in.is_some());
    let out = no_hub_card(&NoHub { configured: true, ..Default::default() });
    assert!(
        out.sign_in.is_none() && out.status.text.key.as_deref() == Some("devices.status.signedOut")
    );
}

#[test]
fn device_rows_and_gestures() {
    assert_eq!(platform_label(None).english(), "Mac");
    assert_eq!(presence(false, Some("2 days ago")).english(), "Offline · seen 2 days ago");
    assert_eq!(remove_confirm(false, "Studio").title.english(), "Remove Studio from your devices?");
    assert_eq!(screen_action(Some(Platform::Windows), false, true), None);
    assert!(screen_action(Some(Platform::Linux), false, false).unwrap().disabled);
    assert_eq!(screen_action(Some(Platform::Macos), true, false).unwrap().kind, "share");
    assert_eq!(open_screen_refusal(true, false, Some(Platform::Macos), true), None);
    assert_eq!(
        open_screen_refusal(true, false, Some(Platform::Macos), false).unwrap().key.as_deref(),
        Some("devices.error.offline")
    );
    assert_eq!(
        open_screen_refusal(false, false, None, true).unwrap().key.as_deref(),
        Some("devices.error.gone")
    );
    assert_eq!(rename_name(Some("  ")), None);
    assert_eq!(rename_name(Some(" Mini ")).as_deref(), Some("Mini"));
    assert_eq!(
        failure_message(&Failure::Hub { code: Some("not_found".into()) }).key.as_deref(),
        Some("devices.error.gone")
    );
    assert_eq!(
        failure_message(&Failure::NotConfigured).key.as_deref(),
        Some("devices.error.signedOut")
    );
    assert_eq!(EndReason::of(Some("failed: x")), EndReason::Failed);
    assert_eq!(EndReason::of(Some("signed_out:quit")), EndReason::SignedOut);
}
