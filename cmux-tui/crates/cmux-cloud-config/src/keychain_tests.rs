use super::*;

fn install_key() -> Item {
    Item {
        service: "com.cmuxterm.app.next.install-key.api.cmux.dev".into(),
        account: "install-key-0123456789abcdef".into(),
    }
}

#[test]
fn the_deadline_answers_before_the_daemon_relay_gives_up() {
    // The relay call may mint twice (a 401), each mint waiting once; the daemon's provider deadline is 30 s.
    assert!(DEADLINE * 2 < Duration::from_secs(30));
}

#[test]
fn a_refusal_names_the_item_and_the_next_step() {
    let refusal = refusal(&install_key(), DEADLINE);
    assert_eq!(refusal["code"], "owner.unreachable");
    assert_eq!(refusal["retryable"], true);
    assert_eq!(
        refusal["message"],
        "the Keychain did not answer for \"com.cmuxterm.app.next.install-key.api.cmux.dev\" \
         (account install-key-0123456789abcdef) within 10 s: unlock it or allow cmux access"
    );
    assert_eq!(
        refusal["details"]["keychain"],
        json!({
            "service": "com.cmuxterm.app.next.install-key.api.cmux.dev",
            "account": "install-key-0123456789abcdef",
            "deadline_seconds": 10,
        })
    );
}

#[test]
fn seconds_round_up_and_never_read_zero() {
    assert_eq!(seconds(Duration::from_millis(1)), 1);
    assert_eq!(seconds(Duration::from_millis(1500)), 2);
    assert_eq!(seconds(Duration::from_secs(10)), 10);
    assert_eq!(seconds(Duration::ZERO), 1);
}
