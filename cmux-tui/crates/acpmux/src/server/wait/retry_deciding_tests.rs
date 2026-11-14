use super::*;

/// A row whose failed turn's retry is being decided holds a wait's answer, for at most
/// `RETRY_DECIDING_MAX` from when the wait first saw it so; any other row holds nothing.
#[test]
fn a_row_deciding_its_retry_holds_a_wait_for_a_bounded_time() {
    let mut since = HashMap::new();
    let t0 = tokio::time::Instant::now();
    let deciding = json!({"status": "ready", "turn": null, "retryDeciding": true});
    let mut holds = |s: &Value, at| holds_for_retry(s, since.entry("s".to_owned()), at);
    assert!(holds(&deciding, t0));
    assert!(holds(&deciding, t0 + Duration::from_secs(4)));
    assert!(!holds(&deciding, t0 + RETRY_DECIDING_MAX), "bounded");
    // Settled, then deciding again (its retry failed too): counted afresh.
    let settled = json!({"status": "ready", "turn": null, "retry": {"attempt": 1}});
    assert!(!holds(&settled, t0 + Duration::from_secs(6)));
    assert!(holds(&deciding, t0 + Duration::from_secs(7)));
    for s in [
        json!({"status": "running", "turn": {"turnId": "t2"}, "retryDeciding": true}),
        json!({"status": "closed", "turn": null, "retryDeciding": true}),
        json!({"status": "closed", "missing": true, "retryDeciding": true}),
        json!({"status": "unreachable", "stale": true, "turn": null, "retryDeciding": true}),
        json!({"status": "ready", "turn": null}),
    ] {
        let mut since = HashMap::new();
        assert!(!holds_for_retry(&s, since.entry("s".to_owned()), t0), "{s}");
    }
}
