//! The app's carrier children against the real parser: every argv in
//! `cmux-tui/spec/fixtures/carrier-child-argv.json` (the app's
//! CloudCarrierArgvContractTests check that CloudCarrierDial builds exactly
//! these) must parse here, with no network. The app's shell stand-ins
//! hid an argv the bundled CLI refused (exit 64), which this closes.

use std::path::Path;

use serde_json::Value;

use super::{DialService, parse, parse_serve};

fn children() -> Vec<Value> {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/fixtures/carrier-child-argv.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let fixture: Value = serde_json::from_str(&text).unwrap();
    fixture.get("children").and_then(Value::as_array).cloned().unwrap_or_default()
}

fn text<'a>(child: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter().try_fold(child, |value, key| value.get(*key))?.as_str()
}

#[test]
fn every_child_the_app_spawns_parses_with_the_real_carrier_cli() {
    let children = children();
    assert!(children.len() >= 2, "the fixture lost its children");
    for child in &children {
        let name = text(child, &["name"]).unwrap_or("?");
        let argv: Vec<String> = child
            .get("argv")
            .and_then(Value::as_array)
            .map(|words| words.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        let (command, args) = argv.split_first().unwrap_or_else(|| panic!("{name}: no argv"));
        assert_eq!(command, "carrier", "{name}: not a carrier child");
        let machine = text(child, &["swift", "machine"]);
        match args.first().map(String::as_str) {
            Some("dial") => {
                let dial = parse(args)
                    .unwrap_or_else(|| panic!("{name}: `cmux {}` exits 64", argv.join(" ")));
                assert_eq!(Some(dial.machine.as_str()), machine, "{name}");
                let service = match text(child, &["swift", "service"]) {
                    Some("desktop") => DialService::Desktop,
                    _ => DialService::Mux,
                };
                assert_eq!(dial.service, service, "{name}");
            }
            Some("serve") => {
                let serve = parse_serve(args)
                    .unwrap_or_else(|| panic!("{name}: `cmux {}` exits 64", argv.join(" ")));
                assert_eq!(Some(serve.dial.machine.as_str()), machine, "{name}");
                assert_eq!(serve.socket.to_str(), text(child, &["swift", "socket"]), "{name}");
            }
            other => panic!("{name}: the carrier CLI has no verb {other:?}"),
        }
    }
}
