use super::*;

fn book() -> Vec<(String, String)> {
    vec![
        ("a".repeat(44), "gcp-agent-lane-10".to_owned()),
        ("b".repeat(44), "twice".to_owned()),
        ("b".repeat(44), "twice-again".to_owned()),
        ("c".repeat(44), "../etc".to_owned()),
    ]
}

#[test]
fn a_listed_machine_reaches_its_own_socket_beside_the_brokers() {
    let got = admit(Some("/srv/broker/broker.sock"), &book(), &"a".repeat(44)).unwrap();
    assert_eq!(got, PathBuf::from("/srv/broker/client-gcp-agent-lane-10.sock"));
}

#[test]
fn no_configured_broker_is_off() {
    let refused = admit(None, &book(), &"a".repeat(44)).unwrap_err();
    assert_eq!(refused.reason, "service.off");
}

#[test]
fn an_unlisted_twice_listed_or_odd_name_is_refused() {
    for from in ["z".repeat(44), "b".repeat(44), "c".repeat(44)] {
        let refused = admit(Some("/srv/broker.sock"), &book(), &from).unwrap_err();
        assert_eq!(refused.reason, "service.unknown_machine", "{from}");
    }
}

#[test]
fn a_relative_broker_socket_is_misconfigured() {
    let refused = admit(Some("broker.sock"), &book(), &"a".repeat(44)).unwrap_err();
    assert_eq!(refused.reason, "service.misconfigured");
}
