use std::path::Path;

use serde_json::Value;

use super::*;

const SLOT: &str = "AAAAAAAAAAAAAAAAAAAAAA";

fn section(text: &str) -> Result<CarrierRoute, String> {
    match serde_json::from_str::<Value>(text) {
        Ok(value) => parse_section(&value),
        Err(e) => Err(format!("not JSON: {e}")),
    }
}

#[test]
fn a_carrier_section_names_the_relay_slot_and_its_ticket_command() {
    let route = section(&format!(
        r#"{{"relay": "relay+do://relay.cmux.dev", "machine": "vm_0123456789abcdefghij", "slot": "{SLOT}"}}"#
    ))
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
        let error = section(&carrier).unwrap_err();
        assert!(error.contains(why), "{carrier}: {error}");
    }
}

fn route() -> CarrierRoute {
    CarrierRoute {
        relay: "relay+do://relay.cmux.dev".into(),
        machine: "vm_0123456789abcdefghij".into(),
        slot: SLOT.into(),
    }
}

#[test]
fn the_carrier_file_round_trips_and_no_file_is_off() {
    let file = CarrierFile {
        route: route(),
        team: "team_0123456789abcdefghij".into(),
        issuer: "cmux:cloud:production".into(),
    };
    let text = file.to_json().to_string();
    assert_eq!(parse_file(Some(&text)), Ok(Some(file)));
    assert_eq!(parse_file(None), Ok(None));
}

#[test]
fn a_malformed_carrier_file_is_refused() {
    let good = CarrierFile {
        route: route(),
        team: "team_0123456789abcdefghij".into(),
        issuer: "cmux:cloud:staging".into(),
    }
    .to_json();
    let mut cases = vec!["not json".to_owned(), "[]".to_owned(), "{}".to_owned()];
    for (field, bad) in [
        ("team", Value::from("other")),
        ("issuer", Value::from("stg")),
        ("slot", Value::from("short")),
        ("ticket", Value::from("x")),
    ] {
        let mut value = good.clone();
        value[field] = bad;
        cases.push(value.to_string());
    }
    for field in ["relay", "machine", "slot", "team", "issuer"] {
        let mut value = good.clone();
        value.as_object_mut().unwrap().remove(field);
        cases.push(value.to_string());
    }
    for text in cases {
        assert!(parse_file(Some(&text)).is_err(), "{text}");
    }
}

#[test]
fn the_route_flags_of_a_running_session_host_are_read_back() {
    let bin = Path::new("/home/cmux/.cmux/bin/cmux-tui");
    let mut argv: Vec<String> =
        ["cmux-tui", "server", "--remote-ws", "127.0.0.1:1337"].map(String::from).to_vec();
    assert!(args_in(&argv).is_empty());
    argv.extend(route().args(bin));
    assert_eq!(args_in(&argv), route().args(bin));
}
