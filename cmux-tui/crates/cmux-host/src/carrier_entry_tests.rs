use std::path::Path;

use serde_json::Value;

use super::*;

const SLOT: &str = "AAAAAAAAAAAAAAAAAAAAAA";

/// The host entry as the units run it: `<current>/bin/cmux host`.
fn host() -> Vec<String> {
    vec!["/opt/cmux/current/bin/cmux".to_owned(), "host".to_owned()]
}

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
        route.args(&host(), Path::new(GRANT_CONFIG_FILE)),
        [
            "--relay",
            "relay+do://relay.cmux.dev",
            "--relay-slot",
            SLOT,
            "--relay-ticket-command",
            "/opt/cmux/current/bin/cmux",
            "--relay-ticket-command-arg",
            "host",
            "--relay-ticket-command-arg",
            "cloud",
            "--relay-ticket-command-arg",
            "carrier-ticket",
            "--carrier-grant-config",
            "/run/cmux/carrier-grant.json",
            "--remote-local-socket",
            "/run/cmux-rd/desktop.sock",
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

#[test]
fn the_relay_host_and_port_are_checked_strictly() {
    let with = |relay: &str| {
        section(&format!(
            r#"{{"relay": "{relay}", "machine": "vm_0123456789abcdefghij", "slot": "{SLOT}"}}"#
        ))
    };
    for good in ["relay+do://relay.cmux.dev", "relay+do://relay.example:8443", "relay+do://r-1.x"] {
        assert!(with(good).is_ok(), "{good}");
    }
    for bad in [
        "relay+do://relay.example:",
        "relay+do://relay.example:notaport",
        "relay+do://relay.example:0",
        "relay+do://relay.example:65536",
        "relay+do://relay.example:443:443",
        "relay+do://relay..example",
        "relay+do://-relay.example",
        "relay+do://relay-.example",
        "relay+do://.relay.example",
        "relay+do://relay.example.",
    ] {
        assert!(with(bad).is_err(), "{bad}");
    }
}

fn keyset() -> Value {
    serde_json::json!({
        "version": "0123456789abcdef",
        "keys": {"k1": {
            "kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": "k1",
            "x": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        }},
    })
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
        keyset: keyset(),
    };
    let text = file.to_json().to_string();
    assert_eq!(parse_file(Some(&text)), Ok(Some(file.clone())));
    assert_eq!(parse_file(None), Ok(None));
    // The session host's copy holds only the public fields.
    let mut public: Vec<String> =
        file.grant_config().as_object().unwrap().keys().cloned().collect();
    public.sort();
    assert_eq!(public, ["issuer", "keyset", "machine", "team"]);
}

#[test]
fn a_malformed_carrier_file_is_refused() {
    let good = CarrierFile {
        route: route(),
        team: "team_0123456789abcdefghij".into(),
        issuer: "cmux:cloud:staging".into(),
        keyset: keyset(),
    }
    .to_json();
    let mut cases = vec!["not json".to_owned(), "[]".to_owned(), "{}".to_owned()];
    for (field, bad) in [
        ("team", Value::from("other")),
        ("issuer", Value::from("stg")),
        ("slot", Value::from("short")),
        ("ticket", Value::from("x")),
        ("keyset", serde_json::json!({"version": "0123456789abcdef", "keys": {}})),
    ] {
        let mut value = good.clone();
        value[field] = bad;
        cases.push(value.to_string());
    }
    for field in ["relay", "machine", "slot", "team", "issuer", "keyset"] {
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
    let bin = &host();
    let mut argv: Vec<String> =
        ["cmux-tui", "server", "--remote-ws", "127.0.0.1:1337"].map(String::from).to_vec();
    assert!(args_in(&argv).is_empty());
    let grant = Path::new(GRANT_CONFIG_FILE);
    argv.extend(route().args(bin, grant));
    assert_eq!(args_in(&argv), route().args(bin, grant));
}

/// A refreshed keyset for the same issuer replaces the kept one, the rest
/// of the file as it was; the same keyset, another issuer, an invalid
/// keyset or no valid file change nothing.
#[test]
fn a_rotated_keyset_rewrites_the_carrier_file() {
    let file = CarrierFile {
        route: route(),
        team: "team_0123456789abcdefghij".into(),
        issuer: "cmux:cloud:production".into(),
        keyset: keyset(),
    };
    let text = file.to_json().to_string();
    let mut rotated = keyset();
    rotated["version"] = Value::from("fedcba9876543210");
    rotated["keys"]["k2"] = rotated["keys"]["k1"].clone();
    rotated["keys"]["k2"]["kid"] = Value::from("k2");
    let issuer = "cmux:cloud:production";
    let written = with_keyset(Some(&text), issuer, &rotated).expect("a rotation is kept");
    let kept = parse_file(Some(&written)).unwrap().unwrap();
    assert_eq!(kept, CarrierFile { keyset: rotated.clone(), ..file.clone() });
    assert_eq!(
        file.route.args(&host(), Path::new("/g")),
        kept.route.args(&host(), Path::new("/g"))
    );
    assert_eq!(with_keyset(Some(&text), issuer, &keyset()), None);
    assert_eq!(with_keyset(Some(&text), "cmux:cloud:staging", &rotated), None);
    let empty = serde_json::json!({"version": "fedcba9876543210", "keys": {}});
    assert_eq!(with_keyset(Some(&text), issuer, &empty), None);
    assert_eq!(with_keyset(None, issuer, &rotated), None);
    assert_eq!(with_keyset(Some("{}"), issuer, &rotated), None);
}

/// The standalone `cmux-host` takes its verbs with no `host` noun.
#[test]
fn the_standalone_host_entry_runs_cloud_carrier_ticket() {
    let args = route().args(&["/usr/bin/cmux-host".to_owned()], Path::new(GRANT_CONFIG_FILE));
    let at = args.iter().position(|arg| arg == "--relay-ticket-command").unwrap();
    assert_eq!(
        args[at..at + 6],
        [
            "--relay-ticket-command",
            "/usr/bin/cmux-host",
            "--relay-ticket-command-arg",
            "cloud",
            "--relay-ticket-command-arg",
            "carrier-ticket",
        ]
    );
}
