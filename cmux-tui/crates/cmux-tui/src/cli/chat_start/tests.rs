use std::cell::Cell;

use serde_json::{Value, json};

use super::super::cloud_start_chat::Machine;
use super::{Parsed, Reads, Route, Start, cloud_words, here_words, parse, route, start_words};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn start(list: &[&str]) -> Start {
    match parse(&words(list), None).unwrap() {
        Parsed::Run(start) => start,
        Parsed::Help => panic!("help"),
    }
}

/// The daemon answers `machine.list` with a bare array (resource_api.rs `MachineList`).
fn catalog() -> Value {
    json!([
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
    ])
}

/// The app's `cloud list-machines` answer.
fn listed() -> Value {
    json!({"account": {"signed_in": true}, "machines": [
        {"machine_id": "vm-dev", "title": "dev"},
        {"machine_id": "vm-a", "title": "twin-title"},
        {"machine_id": "vm-b", "title": "twin-title"},
        {"machine_id": "vm-cloud-named", "title": "cloud"},
    ]})
}

/// `route` with the fixtures, signed in or not.
fn at(on: &str, signed_in: bool) -> Result<Route, Value> {
    route(
        Some(on),
        Reads {
            catalog: || Ok(catalog()),
            signed_in: || signed_in,
            cloud_machines: || Ok(listed()),
        },
    )
}

fn code(result: Result<Route, Value>) -> String {
    let error = result.unwrap_err();
    assert!(error["details"]["next"].as_str().is_some_and(|next| !next.is_empty()), "{error}");
    error["code"].as_str().unwrap().to_owned()
}

#[test]
fn no_target_is_a_chat_here() {
    let parsed = start(&[]);
    assert_eq!(parsed.on, None);
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
    let unread = || -> Result<Value, Value> { panic!("read") };
    let reads = Reads { catalog: unread, signed_in: || panic!("asked"), cloud_machines: unread };
    assert_eq!(route(None, reads), Ok(Route::Here));
    assert_eq!(at("here", false), Ok(Route::Here));
}

#[test]
fn one_flag_names_every_target() {
    assert_eq!(start(&["--on", "machine_box"]).on.as_deref(), Some("machine_box"));
    assert_eq!(start(&["--on=cloud"]).on.as_deref(), Some("cloud"));
    assert_eq!(start(&["--on", "vm:new", "go"]).on.as_deref(), Some("vm:new"));
    assert!(parse(&words(&["--on", " "]), None).is_err());
    assert!(parse(&words(&["--on", "a", "--on", "b"]), None).is_err());
    assert!(parse(&words(&["--on", "vm:"]), None).is_err());
    assert!(parse(&words(&["--prompt", "a", "b"]), None).is_err());
    // The old per-kind flags are not flags.
    assert!(parse(&words(&["--device", "machine_box"]), None).is_err());
    assert!(parse(&words(&["--vm", "new"]), None).is_err());
    assert_eq!(parse(&words(&["--help"]), None).unwrap(), Parsed::Help);
}

#[test]
fn cmux_target_names_the_target_when_on_is_absent() {
    let with_env = |list: &[&str], env: &str| match parse(&words(list), Some(env.into())).unwrap() {
        Parsed::Run(start) => start.on,
        Parsed::Help => panic!(),
    };
    assert_eq!(with_env(&["hi"], "vm:dev").as_deref(), Some("vm:dev"));
    assert_eq!(with_env(&["--on", "here", "hi"], "vm:dev").as_deref(), Some("here"));
    assert_eq!(with_env(&["hi"], "  "), None);
}

#[test]
fn a_vm_chat_is_the_cloud_start_chat_run() {
    let vm =
        start(&["--on", "vm:dev", "--agent", "codex", "--wait", "--timeout", "60", "-p", "go"]);
    assert_eq!(
        cloud_words(&vm, &Machine::Target("vm-dev".into())).unwrap(),
        words(&[
            "--prompt",
            "go",
            "--target",
            "machine:vm-dev",
            "--agent",
            "codex",
            "--timeout",
            "60",
            "--wait"
        ])
    );
    assert_eq!(cloud_words(&start(&["go"]), &Machine::New).unwrap(), words(&["--prompt", "go"]));
    // A Cloud chat needs a prompt, and takes no model or chat name.
    assert!(cloud_words(&start(&[]), &Machine::New).is_err());
    assert!(cloud_words(&start(&["--model", "m", "go"]), &Machine::New).is_err());
    // A chat here does not wait.
    assert!(here_words(&[], &start(&["--wait", "go"])).is_err());
}

#[test]
fn vm_targets_are_new_or_an_existing_vm_never_made_for_them() {
    assert_eq!(at("vm:new", true), Ok(Route::Cloud(Machine::New)));
    assert_eq!(at("vm:vm-dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(at("vm:machine:vm-dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(at("vm:dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(code(at("vm:nothing", true)), "chat_target.unknown_vm");
    assert_eq!(code(at("vm:twin-title", true)), "chat_target.unknown_vm");
}

#[test]
fn cloud_is_a_selector_and_needs_a_sign_in() {
    assert_eq!(at("cloud", true), Ok(Route::Cloud(Machine::New)));
    assert_eq!(code(at("cloud", false)), "chat_target.signed_out");
    // A device named "cloud" is reached by its id, never by the selector.
    assert_eq!(
        at("machine_cloud_named", true),
        Ok(Route::Cloud(Machine::Target("vm-cloud-named".into())))
    );
}

#[test]
fn devices_are_checked_against_the_daemons_catalog() {
    let asked = Cell::new(false);
    let reads = Reads {
        catalog: || Ok(catalog()),
        signed_in: || {
            asked.set(true);
            false
        },
        cloud_machines: || -> Result<Value, Value> { panic!("listed") },
    };
    // The local device needs no sign-in, and is not asked for one.
    assert_eq!(route(Some("machine_mac"), reads), Ok(Route::Here));
    assert!(!asked.get());
    assert_eq!(at("local", false), Ok(Route::Here));
    // A connected Cloud VM by id or name, signed in: the app's existing VM.
    assert_eq!(at("machine_vm", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(at("dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(code(at("machine_vm", false)), "chat_target.signed_out");
    // Refusals the SDK names, each with what to run next.
    assert_eq!(code(at("machine_gone", true)), "chat_target.unknown_device");
    assert_eq!(code(at("machine_term", true)), "chat_target.not_permitted");
    assert_eq!(code(at("machine_nap", true)), "chat_target.unavailable");
    // A name of two devices names none.
    assert_eq!(code(at("twin", true)), "chat_target.ambiguous_device");
    // An ssh device that passes the check has no CLI route yet: refused, never started elsewhere.
    assert_eq!(code(at("machine_box", true)), "chat_target.no_route");
    let unknown = at("machine_gone", true).unwrap_err();
    assert!(unknown["message"].as_str().unwrap().contains("cmux machine list"), "{unknown}");
}

/// The object form of the catalog reads the same.
#[test]
fn the_object_catalog_reads_like_the_daemons_array() {
    let object = || Ok(json!({"machines": catalog()}));
    for on in ["machine_mac", "dev", "twin", "machine_box", "machine_gone"] {
        let reads = Reads { catalog: object, signed_in: || true, cloud_machines: || Ok(listed()) };
        assert_eq!(route(Some(on), reads), at(on, true), "{on}");
    }
}

/// A connected Cloud device runs on the app's existing VM, by id or by its one title, and is
/// refused when the app lists none or several.
#[test]
fn a_cloud_device_is_an_existing_cloud_vm() {
    let with = |listed: Value| {
        route(
            Some("machine_vm"),
            Reads { catalog: || Ok(catalog()), signed_in: || true, cloud_machines: || Ok(listed) },
        )
    };
    assert_eq!(
        with(json!({"machines": [{"machine_id": "machine_vm", "title": "other"}]})),
        Ok(Route::Cloud(Machine::Target("machine_vm".into())))
    );
    assert_eq!(code(with(json!({"machines": []}))), "chat_target.unavailable");
    let two = json!({"machines": [{"machine_id": "a", "title": "dev"},
                                  {"machine_id": "b", "title": "dev"}]});
    assert_eq!(code(with(two)), "chat_target.unavailable");
}

/// `cmux chat PROMPT` is a start, like `cmux chat new PROMPT`; the other chat verbs are not.
#[test]
fn a_bare_prompt_is_a_start() {
    assert_eq!(start_words(&words(&["fix the tests"])), Some(&words(&["fix the tests"])[..]));
    assert_eq!(start_words(&words(&["new", "hi"])), Some(&words(&["hi"])[..]));
    assert_eq!(start_words(&words(&["--on", "cloud", "hi"])), Some(&words(&["--on", "cloud", "hi"])[..]));
    assert_eq!(start_words(&[]), Some(&[][..]));
    assert_eq!(start_words(&words(&["send", "x"])), None);
    assert_eq!(start_words(&words(&["list"])), None);
}
