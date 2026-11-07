use std::cell::Cell;

use serde_json::{Value, json};

use super::super::cloud_start_chat::Machine;
use super::{Parsed, Route, Start, Target, cloud_words, here_words, parse, route};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn start(list: &[&str]) -> Start {
    match parse(&words(list)).unwrap() {
        Parsed::Run(start) => start,
        Parsed::Help => panic!("help"),
    }
}

fn catalog() -> Value {
    json!({"machines": [
        {"id": "machine_mac", "name": "local", "origin": "local",
         "capabilities": ["terminal", "workspace", "agent_session"]},
        {"id": "machine_vm", "name": "dev", "origin": "cloud", "status": "running",
         "capabilities": ["terminal", "agent_session"]},
        {"id": "machine_box", "name": "box", "origin": "ssh", "status": "running",
         "capabilities": ["terminal", "agent_session"]},
        {"id": "machine_term", "name": "term", "origin": "ssh", "status": "running",
         "capabilities": ["terminal"]},
        {"id": "machine_nap", "name": "nap", "origin": "server", "status": "unavailable",
         "capabilities": ["agent_session"]},
        {"id": "machine_twin_a", "name": "twin", "origin": "ssh", "status": "running",
         "capabilities": ["agent_session"]},
        {"id": "machine_twin_b", "name": "twin", "origin": "ssh", "status": "running",
         "capabilities": ["agent_session"]},
        {"id": "machine_cloud_named", "name": "cloud", "origin": "cloud", "status": "running",
         "capabilities": ["agent_session"]},
    ]})
}

/// The app's `cloud list-machines` answer: vm-dev is titled dev.
fn listed() -> Result<Value, Value> {
    Ok(json!({"account": {"signed_in": true}, "machines": [
        {"machine_id": "vm-dev", "title": "dev"},
        {"machine_id": "vm-a", "title": "twin-title"},
        {"machine_id": "vm-b", "title": "twin-title"},
        {"machine_id": "vm-cloud-named", "title": "cloud"},
    ]}))
}

fn code(result: Result<Route, Value>) -> String {
    result.unwrap_err()["code"].as_str().unwrap().to_owned()
}

#[test]
fn no_target_is_a_chat_here() {
    let parsed = start(&[]);
    assert_eq!(parsed.target, Target::Here);
    assert_eq!(start(&["--", "hi there"]).prompt.as_deref(), Some("hi there"));
    assert_eq!(start(&["--agent", "codex", "hi"]).prompt.as_deref(), Some("hi"));
    assert_eq!(
        here_words(&words(&["--socket", "/s"]), &start(&["--agent", "codex", "--cwd", "/w", "hi"]))
            .unwrap(),
        words(&[
            "--socket",
            "/s",
            "agents",
            "chat",
            "new",
            "--harness",
            "codex",
            "--cwd",
            "/w",
            "--",
            "hi"
        ])
    );
}

#[test]
fn a_target_flag_sends_it_elsewhere() {
    assert_eq!(start(&["--device", "machine_box"]).target, Target::Device("machine_box".into()));
    assert_eq!(start(&["--device=cloud"]).target, Target::Device("cloud".into()));
    assert_eq!(start(&["--vm", "new"]).target, Target::Vm(Machine::New));
    assert_eq!(start(&["--vm", "dev"]).target, Target::Vm(Machine::Named("dev".into())));
    assert_eq!(start(&["--vm", "machine:vm-1"]).target, Target::Vm(Machine::Target("vm-1".into())));
    assert!(parse(&words(&["--device", "a", "--vm", "b"])).is_err());
    assert!(parse(&words(&["--device", " "])).is_err());
    assert!(parse(&words(&["--vm", "machine:"])).is_err());
    assert!(parse(&words(&["--prompt", "a", "b"])).is_err());
    assert_eq!(parse(&words(&["--help"])).unwrap(), Parsed::Help);
}

#[test]
fn a_vm_chat_is_the_cloud_start_chat_run() {
    let vm =
        start(&["--vm", "dev", "--agent", "codex", "--wait", "--timeout", "60", "--prompt", "go"]);
    assert_eq!(
        cloud_words(&vm, &Machine::Named("dev".into())).unwrap(),
        words(&[
            "--prompt",
            "go",
            "--name",
            "dev",
            "--agent",
            "codex",
            "--timeout",
            "60",
            "--wait"
        ])
    );
    assert_eq!(
        cloud_words(&start(&["go"]), &Machine::Target("vm-1".into())).unwrap(),
        words(&["--prompt", "go", "--target", "machine:vm-1"])
    );
    // A Cloud chat needs a prompt, and takes no model or chat name.
    assert!(cloud_words(&start(&[]), &Machine::New).is_err());
    assert!(cloud_words(&start(&["--model", "m", "go"]), &Machine::New).is_err());
    // A chat here does not wait.
    assert!(here_words(&[], &start(&["--wait", "go"])).is_err());
}

#[test]
fn cloud_is_a_selector_and_needs_a_sign_in() {
    assert_eq!(route("cloud", &catalog(), || true, listed), Ok(Route::Cloud(Machine::New)));
    assert_eq!(code(route("cloud", &catalog(), || false, listed)), "chat_target.signed_out");
    // A device named "cloud" is reached by its id, never by the selector.
    assert_eq!(
        route("machine_cloud_named", &catalog(), || true, listed),
        Ok(Route::Cloud(Machine::Target("vm-cloud-named".into())))
    );
}

#[test]
fn devices_are_checked_against_the_catalog() {
    let asked = Cell::new(false);
    let ask = || {
        asked.set(true);
        false
    };
    // The local device needs no sign-in, and is not asked for one.
    assert_eq!(route("machine_mac", &catalog(), ask, listed), Ok(Route::Here));
    assert!(!asked.get());
    assert_eq!(route("local", &catalog(), || false, listed), Ok(Route::Here));
    // A connected Cloud machine by id or name, signed in.
    assert_eq!(
        route("machine_vm", &catalog(), || true, listed),
        Ok(Route::Cloud(Machine::Target("vm-dev".into())))
    );
    assert_eq!(
        route("dev", &catalog(), || true, listed),
        Ok(Route::Cloud(Machine::Target("vm-dev".into())))
    );
    assert_eq!(code(route("machine_vm", &catalog(), || false, listed)), "chat_target.signed_out");
    // Refusals the SDK names.
    assert_eq!(
        code(route("machine_gone", &catalog(), || true, listed)),
        "chat_target.unknown_device"
    );
    assert_eq!(
        code(route("machine_term", &catalog(), || true, listed)),
        "chat_target.not_permitted"
    );
    assert_eq!(code(route("machine_nap", &catalog(), || true, listed)), "chat_target.unavailable");
    // A name of two devices names none.
    assert_eq!(code(route("twin", &catalog(), || true, listed)), "chat_target.ambiguous_device");
    // An ssh device that passes the check has no CLI route yet: refused, never started elsewhere.
    assert_eq!(code(route("machine_box", &catalog(), || true, listed)), "chat_target.no_route");
}

/// The daemon answers `machine.list` with a bare array (resource_api.rs): every device lookup
/// reads it as the object form.
#[test]
fn the_daemons_array_catalog_resolves_devices() {
    let array = catalog()["machines"].clone();
    assert!(array.is_array());
    assert_eq!(route("machine_mac", &array, || false, listed), Ok(Route::Here));
    assert_eq!(
        route("dev", &array, || true, listed),
        Ok(Route::Cloud(Machine::Target("vm-dev".into())))
    );
    assert_eq!(code(route("twin", &array, || true, listed)), "chat_target.ambiguous_device");
    assert_eq!(code(route("machine_box", &array, || true, listed)), "chat_target.no_route");
    assert_eq!(code(route("machine_gone", &array, || true, listed)), "chat_target.unknown_device");
}

/// A connected Cloud device runs on the app's existing machine, by id or by its one title, and is
/// refused when the app lists none or several: `cmux chat --device` never makes a machine.
#[test]
fn a_cloud_device_is_an_existing_cloud_machine() {
    let by_id = || Ok(json!({"machines": [{"machine_id": "machine_vm", "title": "other"}]}));
    assert_eq!(
        route("machine_vm", &catalog(), || true, by_id),
        Ok(Route::Cloud(Machine::Target("machine_vm".into())))
    );
    let none = || Ok(json!({"machines": []}));
    assert_eq!(code(route("machine_vm", &catalog(), || true, none)), "chat_target.unavailable");
    let two = || {
        Ok(json!({"machines": [{"machine_id": "a", "title": "dev"},
                                         {"machine_id": "b", "title": "dev"}]}))
    };
    assert_eq!(code(route("machine_vm", &catalog(), || true, two)), "chat_target.unavailable");
    // The app's list is read only for a Cloud device.
    let unread = || -> Result<Value, Value> { panic!("listed") };
    assert_eq!(route("machine_mac", &catalog(), || false, unread), Ok(Route::Here));
}
