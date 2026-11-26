use super::*;
use cmux_hub_host::b64;

/// A `Current` serving session `s1` with `scope`, and its stop flag.
fn serving(scope: &str) -> (Current, Arc<AtomicBool>) {
    let stop = Arc::new(AtomicBool::new(false));
    let served = Served { id: "s1".into(), scope: scope.into(), stop: stop.clone() };
    (Arc::new(Mutex::new(Some(served))), stop)
}

fn is_empty(current: &Current) -> bool {
    current.lock().unwrap().is_none()
}

#[test]
fn a_dropped_hub_link_stops_the_session_it_served() {
    // Revocations sent while the link is down are never replayed: fail closed.
    let (current, stop) = serving("full");
    let held = stop.clone();
    let (result, stopped) = hold_link(&current, || {
        assert!(!held.load(Ordering::SeqCst), "stopped while the link was up");
        Err("socket closed (1006 connection closed)".into())
    });
    assert!(result.is_err());
    assert_eq!(stopped.as_deref(), Some("s1"));
    assert!(stop.load(Ordering::SeqCst));
    assert!(is_empty(&current));
    // A link the hub closed cleanly too.
    let (current, stop) = serving("view");
    let (result, stopped) = hold_link(&current, || Ok(()));
    assert!(result.is_ok());
    assert_eq!(stopped.as_deref(), Some("s1"));
    assert!(stop.load(Ordering::SeqCst));
    // Nothing served, nothing stopped.
    let current: Current = Arc::new(Mutex::new(None));
    assert_eq!(hold_link(&current, || Ok(())).1, None);
}

fn consent_dir(tag: &str) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-screen-host-consent-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn consent_is_read_again_for_each_ticket() {
    let dir = consent_dir("admit");
    LocalConsent { view: true, full: true }.save(&dir).unwrap();
    assert_eq!(admit(&dir, "full", true), Some(false));
    // Control withdrawn (linux-host `enable --view-only`), the host still running.
    LocalConsent { view: true, full: false }.save(&dir).unwrap();
    assert_eq!(admit(&dir, "full", true), None);
    assert_eq!(admit(&dir, "view", true), Some(true));
    // A consent file it cannot trust admits nothing.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir.join("consent.json"), std::fs::Permissions::from_mode(0o644))
            .unwrap();
        assert_eq!(admit(&dir, "view", true), None);
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn withdrawn_consent_stops_the_session_it_no_longer_allows() {
    let both = LocalConsent { view: true, full: true };
    let view_only = LocalConsent { view: true, full: false };
    let (current, stop) = serving("full");
    assert_eq!(withdraw_unconsented(&current, Ok(both), true), None);
    assert!(!stop.load(Ordering::SeqCst));
    assert_eq!(withdraw_unconsented(&current, Ok(view_only), true).as_deref(), Some("s1"));
    assert!(stop.load(Ordering::SeqCst));
    assert!(is_empty(&current));
    // A view session goes on under view-only consent.
    let (current, stop) = serving("view");
    assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
    assert!(!stop.load(Ordering::SeqCst));
    // An unreadable consent file stops it.
    assert_eq!(
        withdraw_unconsented(&current, Err("consent.json: bad mode".into()), true).as_deref(),
        Some("s1")
    );
    assert!(stop.load(Ordering::SeqCst));
    let current: Current = Arc::new(Mutex::new(None));
    assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
}

#[test]
fn a_deleted_consent_file_admits_nothing_and_stops_the_view_session() {
    let dir = consent_dir("deleted");
    LocalConsent { view: true, full: false }.save(&dir).unwrap();
    let (current, stop) = serving("view");
    assert_eq!(withdraw_unconsented(&current, LocalConsent::load(&dir), true), None);
    std::fs::remove_file(dir.join("consent.json")).unwrap();
    assert_eq!(admit(&dir, "view", true), None);
    assert_eq!(
        withdraw_unconsented(&current, LocalConsent::load(&dir), true).as_deref(),
        Some("s1")
    );
    assert!(stop.load(Ordering::SeqCst));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_host_without_input_serves_control_tickets_view_only() {
    let dir = consent_dir("no-input");
    LocalConsent { view: true, full: true }.save(&dir).unwrap();
    // A capture that applies no input (the Wayland portal): a control ticket is served
    // view only.
    assert_eq!(admit(&dir, "full", false), Some(true));
    assert_eq!(admit(&dir, "full", true), Some(false));
    std::fs::remove_dir_all(&dir).unwrap();
}

fn ticket_push(sid_in_jws: &str) -> Value {
    let claims = serde_json::json!({"sid": sid_in_jws, "role": "host", "peerKey": "KEY"});
    let payload = b64::encode(claims.to_string().as_bytes())
        .trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_");
    serde_json::json!({
        "type": "session.ticket", "sessionId": "s1", "role": "host", "scope": "full",
        "ticket": format!("eyJhbGciOiJFUzI1NiJ9.{payload}.c2ln"),
        "signalURL": "wss://hub.example/v1/sessions/s1/ws", "ice": [],
        "peer": {"id": "v1", "name": "Mac", "signingKey": "KEY"}
    })
}

#[test]
fn a_refused_host_ticket_ends_its_session() {
    assert!(matches!(on_ticket(&ticket_push("s1"), |_| Some(true)), OnTicket::Serve(_, true)));
    assert!(matches!(
        on_ticket(&ticket_push("s1"), |_| None),
        OnTicket::End(id, "failed", _) if id == "s1"
    ));
    // A ticket that does not agree with its JWS is ended too, as the Mac host does: the
    // approved session would otherwise stay open on the hub.
    let mut malformed = ticket_push("s2");
    assert!(matches!(
        on_ticket(&malformed, |_| Some(true)),
        OnTicket::End(id, "failed", _) if id == "s1"
    ));
    malformed["ticket"] = "not a jws".into();
    assert!(matches!(
        on_ticket(&malformed, |_| Some(true)),
        OnTicket::End(id, "failed", _) if id == "s1"
    ));
    // With no session id there is nothing to end.
    malformed["sessionId"] = Value::Null;
    assert!(matches!(on_ticket(&malformed, |_| Some(true)), OnTicket::Drop(_)));
}
