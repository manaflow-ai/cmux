use serde_json::{Value, json};

use super::{Route, decide};

fn machines() -> Option<Vec<Value>> {
    json!([
        {"id": "vm_a7b3c9", "title": "build-box", "workspaces": []},
        {"id": "vm_d4e5f6", "title": "twin", "workspaces": []},
        {"id": "vm_000111", "title": "twin", "workspaces": []},
    ])
    .as_array()
    .cloned()
}

fn link(machine: &str) -> Result<String, Value> {
    Ok(format!("/tmp/link-{machine}.sock"))
}

/// Every spelling of a Cloud VM (`vm:ID`, its `vm_…` id, the old `machine:ID`, its title) sends
/// the request to that VM's link socket, with the id verbatim.
#[test]
fn a_cloud_vm_by_any_name_goes_to_its_link_socket() {
    for selector in
        ["vm:vm_a7b3c9", "vm_a7b3c9", "machine:vm_a7b3c9", "build-box", "name:build-box"]
    {
        assert_eq!(
            decide(selector, machines, link),
            Route::Link {
                machine_id: "vm_a7b3c9".into(),
                socket: "/tmp/link-vm_a7b3c9.sock".into()
            },
            "{selector}"
        );
    }
}

/// The local daemon's own machines (`current`, `machine_…` ids, a paired device's name) stay
/// local: the app is not even asked.
#[test]
fn a_local_machine_stays_with_the_local_daemon() {
    for selector in ["current", "machine_0123456789abcdef0123456789abcdef"] {
        assert_eq!(
            decide(selector, || panic!("no app read for {selector}"), |_| panic!("no link")),
            Route::Local
        );
    }
    assert_eq!(decide("studio-mac", machines, |_| panic!("no link")), Route::Local);
}

/// A VM-shaped selector the app does not list is refused as a VM, never sent to the local
/// daemon (which answered `validation.invalid` for `vm_…`).
#[test]
fn an_unknown_vm_is_named_as_a_vm_with_its_id_verbatim() {
    let Route::Refused(error) = decide("vm:vm_ffffff", machines, link) else { panic!() };
    assert_eq!(error["code"], "selector.not_found");
    assert!(error["message"].as_str().unwrap_or_default().contains("vm_ffffff"), "{error}");
}

/// With no app, a VM selector says the app is needed; any other selector stays local.
#[test]
fn without_the_app_a_vm_needs_it() {
    let Route::Refused(error) = decide("vm_a7b3c9", || None, link) else { panic!() };
    assert_eq!(error["code"], "cloud.app_required");
    assert!(error["message"].as_str().unwrap_or_default().contains("vm:vm_a7b3c9"), "{error}");
    assert_eq!(decide("studio-mac", || None, link), Route::Local);
}

/// A title two VMs share is ambiguous; a VM with no link says how to reach it.
#[test]
fn an_ambiguous_title_and_a_missing_link_are_refusals() {
    let Route::Refused(error) = decide("twin", machines, link) else { panic!() };
    assert_eq!(error["code"], "selector.ambiguous");
    let no_link =
        |_: &str| Err(json!({"code": "machine_stream.unavailable", "message": "no link"}));
    let Route::Refused(error) = decide("build-box", machines, no_link) else { panic!() };
    assert_eq!(error["code"], "machine.unreachable");
    assert!(error["message"].as_str().unwrap_or_default().contains("vm:vm_a7b3c9"), "{error}");
}

/// The routed request carries the link socket and no `--machine`: the VM's daemon is its own
/// current machine.
#[test]
fn the_routed_globals_name_the_socket_and_drop_the_machine() {
    let global = crate::cli::GlobalArgs {
        machine: Some("vm:vm_a7b3c9".into()),
        ..crate::cli::GlobalArgs::default()
    };
    let routed = super::routed(&global, "/tmp/link.sock");
    assert_eq!(routed.machine, None);
    assert_eq!(routed.socket.as_deref(), Some(std::path::Path::new("/tmp/link.sock")));
}
