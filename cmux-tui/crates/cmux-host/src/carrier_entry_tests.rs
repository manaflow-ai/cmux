use std::path::Path;

use super::*;

const SLOT: &str = "AAAAAAAAAAAAAAAAAAAAAA";

fn config(carrier: &str) -> String {
    format!(r#"{{"remoteWs": {{"bind": "127.0.0.1:1337"}}, "carrier": {carrier}}}"#)
}

#[test]
fn no_config_or_no_carrier_section_is_off() {
    assert_eq!(parse(None), Ok(None));
    assert_eq!(parse(Some("{}")), Ok(None));
    assert_eq!(parse(Some(r#"{"remoteWs": {"bind": "127.0.0.1:1337"}}"#)), Ok(None));
}

#[test]
fn a_carrier_section_names_the_relay_slot_and_its_ticket_command() {
    let route = parse(Some(&config(&format!(
        r#"{{"relay": "relay+do://relay.cmux.dev", "machine": "vm_0123456789abcdefghij", "slot": "{SLOT}"}}"#
    ))))
    .unwrap()
    .unwrap();
    assert_eq!(
        route,
        CarrierRoute {
            relay: "relay+do://relay.cmux.dev".into(),
            machine: "vm_0123456789abcdefghij".into(),
            slot: SLOT.into(),
        }
    );
    assert_eq!(
        route.args(Path::new("/home/cmux/.cmux/bin/cmux-tui")),
        [
            "--relay",
            "relay+do://relay.cmux.dev",
            "--relay-slot",
            SLOT,
            "--relay-ticket-command",
            "/home/cmux/.cmux/bin/cmux-tui",
            "--relay-ticket-command-arg",
            "host",
            "--relay-ticket-command-arg",
            "cloud",
            "--relay-ticket-command-arg",
            "carrier-ticket",
        ]
    );
}

#[test]
fn a_malformed_carrier_section_is_refused() {
    let good_machine = "vm_0123456789abcdefghij";
    for (carrier, why) in [
        ("[]".to_owned(), "not an object"),
        (
            format!(
                r#"{{"relay": "relay+wss://r.example", "machine": "{good_machine}", "slot": "{SLOT}"}}"#
            ),
            "relay+do",
        ),
        (
            format!(r#"{{"relay": "relay+do://", "machine": "{good_machine}", "slot": "{SLOT}"}}"#),
            "no valid host",
        ),
        (
            format!(
                r#"{{"relay": "relay+do://u:p@r.example/x?t=1", "machine": "{good_machine}", "slot": "{SLOT}"}}"#
            ),
            "no valid host",
        ),
        (
            format!(
                r#"{{"relay": "relay+do://r.example", "machine": "host_1", "slot": "{SLOT}"}}"#
            ),
            "machine id",
        ),
        (
            format!(
                r#"{{"relay": "relay+do://r.example", "machine": "{good_machine}", "slot": "short"}}"#
            ),
            "slot",
        ),
        (format!(r#"{{"relay": "relay+do://r.example", "machine": "{good_machine}"}}"#), "missing"),
        (
            format!(
                r#"{{"relay": "relay+do://r.example", "machine": "{good_machine}", "slot": "{SLOT}", "ticket": "x"}}"#
            ),
            "unknown key",
        ),
        (
            format!(r#"{{"relay": 1, "machine": "{good_machine}", "slot": "{SLOT}"}}"#),
            "not a string",
        ),
    ] {
        let error = parse(Some(&config(&carrier))).unwrap_err();
        assert!(error.contains(why), "{carrier}: {error}");
    }
    assert!(parse(Some("not json")).is_err());
}
