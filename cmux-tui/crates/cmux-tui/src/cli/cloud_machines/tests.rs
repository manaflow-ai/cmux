use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;

use super::*;

const LOCAL: &str = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn local_row() -> Value {
    json!({"id": LOCAL, "name": "local", "origin": "local", "status": "running",
           "connectable": true, "deleted": false, "recoverable": false})
}

/// An app's `cloud.machines` rows (`AppControl.cloudMachineRow`, trimmed).
fn app_rows() -> Vec<Value> {
    vec![
        json!({"id": "vm-brave-otter", "title": "brave-otter", "status": "running",
               "api_status": "running", "stage": "ready", "daemon": "connected"}),
        json!({"id": "vm-calm-heron", "title": "", "status": "paused",
               "api_status": "paused", "stage": "idle", "daemon": "disconnected"}),
    ]
}

/// A fake app control socket that answers one request with `reply` and
/// returns the request it got.
fn fake_app(reply: Value) -> (PathBuf, std::thread::JoinHandle<Value>) {
    let dir = cmux_unix_socket::short_test_dir("cmux-cloud");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        let mut reply = reply;
        reply["id"] = request["id"].clone();
        writeln!(writer, "{reply}").unwrap();
        drop(dir);
        request
    });
    (socket, handle)
}

fn global_for(socket: PathBuf) -> GlobalArgs {
    GlobalArgs { app_socket: Some(socket), output: OutputMode::Quiet, ..GlobalArgs::default() }
}

#[test]
fn cloud_machines_join_the_daemon_rows_marked_kind_cloud() {
    let (merged, note) = merge_rows(json!([local_row()]), Ok(app_rows()));
    assert_eq!(note, None);
    let rows = merged.as_array().unwrap();
    assert_eq!(rows.len(), 3, "{merged}");
    // The daemon's row is unchanged: no `kind` or any other new field.
    assert_eq!(rows[0], local_row());
    assert_eq!(
        rows[1],
        json!({"id": "vm-brave-otter", "name": "brave-otter", "origin": "cloud", "kind": "cloud",
               "status": "running", "connectable": true, "deleted": false, "recoverable": false,
               "target": "machine:vm-brave-otter", "daemon": "connected"})
    );
    // An untitled machine is named by its id; a paused one is not connectable.
    assert_eq!(rows[2]["name"], "vm-calm-heron");
    assert_eq!(rows[2]["status"], "paused");
    assert_eq!(rows[2]["connectable"], false);
    assert_eq!(rows[2]["kind"], "cloud");
}

/// The connected brave-otter's daemon, as `machine list --catalog` lists it
/// (`MachineRegistry.catalogRecords`: its `machine_<hex>` id, origin cloud).
const OTTER_MACHINE: &str = "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn otter_catalog_row() -> Value {
    json!({"id": OTTER_MACHINE, "name": "brave-otter", "origin": "cloud", "status": "running",
           "platform": null, "capabilities": []})
}

#[test]
fn an_items_list_gets_the_rows_too_and_listed_ids_are_not_repeated() {
    let result = json!({"items": [local_row(), otter_catalog_row()], "next_cursor": null});
    let mut rows = app_rows();
    rows[0]["machine_id"] = json!(OTTER_MACHINE);
    rows.push(json!({"title": "no id"}));
    let (merged, note) = merge_rows(result, Ok(rows));
    assert_eq!(note, None);
    let items = merged["items"].as_array().unwrap();
    assert_eq!(items.len(), 3, "{merged}");
    assert_eq!(items[1], otter_catalog_row(), "a machine the catalog lists stays the daemon's row");
    assert_eq!(items[2]["id"], "vm-calm-heron");
    assert_eq!(merged["next_cursor"], Value::Null);
}

#[test]
fn a_cloud_machine_the_daemon_does_not_list_is_added_with_its_machine_id() {
    // The catalog lists another machine; brave-otter's daemon is not in it
    // (not connected yet, or blocked), so its Cloud row is added.
    let other = json!({"id": "machine_cccccccccccccccccccccccccccccccc", "origin": "ssh"});
    let mut rows = app_rows();
    rows[0]["machine_id"] = json!(OTTER_MACHINE);
    let (merged, note) = merge_rows(json!([local_row(), other]), Ok(rows));
    assert_eq!(note, None);
    let ids: Vec<_> = merged.as_array().unwrap().iter().map(|row| row["id"].clone()).collect();
    assert_eq!(ids[2..], [json!("vm-brave-otter"), json!("vm-calm-heron")], "{merged}");
    assert_eq!(merged[2]["machine_id"], OTTER_MACHINE);
    assert_eq!(merged[3].get("machine_id"), None, "a machine with no daemon id has none");
}

#[test]
fn without_the_app_the_daemon_rows_print_alone_with_a_note() {
    let (merged, note) = merge_rows(json!([local_row()]), Err("no app".into()));
    assert_eq!(merged, json!([local_row()]));
    assert_eq!(note.as_deref(), Some("no app"));
    // A named app socket that nothing listens on: the same, through `merge`.
    let dir = cmux_unix_socket::short_test_dir("cmux-cloud");
    let missing = dir.path().join("missing.sock");
    assert_eq!(merge(&global_for(missing), json!([local_row()])), json!([local_row()]));
}

#[test]
fn merge_asks_the_apps_cloud_machines_and_adds_its_rows() {
    let (socket, app) =
        fake_app(json!({"ok": true, "result": {"machines": app_rows(), "creations": []}}));
    let merged = merge(&global_for(socket), json!([local_row()]));
    let request = app.join().unwrap();
    assert_eq!(request["method"], "cloud.machines");
    let ids: Vec<_> = merged.as_array().unwrap().iter().map(|row| row["id"].clone()).collect();
    assert_eq!(ids, vec![json!(LOCAL), json!("vm-brave-otter"), json!("vm-calm-heron")]);
}

#[test]
fn a_refusal_is_the_notes_reason() {
    let refusal = json!({"ok": false, "error": {"code": "policy.disabled",
                                                "message": "Cloud is turned off"}});
    let (socket, app) = fake_app(refusal);
    let mut stream = super::super::app::connect(&socket).unwrap();
    assert_eq!(cloud_machines(&mut stream), Err("Cloud is turned off".to_owned()));
    app.join().unwrap();
}

#[test]
fn a_reply_with_no_machines_list_is_a_failed_read_not_an_empty_one() {
    for result in [json!({}), json!({"machines": null}), json!({"machines": "vm-brave-otter"})] {
        let (socket, app) = fake_app(json!({"ok": true, "result": result}));
        let mut stream = super::super::app::connect(&socket).unwrap();
        let read = cloud_machines(&mut stream);
        let messages = &crate::localization::catalog().app_control;
        assert_eq!(read, Err(messages.cloud_machines_malformed.to_owned()), "{result}");
        app.join().unwrap();
    }
}

#[test]
fn an_app_that_trickles_its_reply_costs_machine_list_at_most_the_deadline() {
    let dir = cmux_unix_socket::short_test_dir("cmux-cloud");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    // Each byte comes well inside the per-read timeout, so only the whole
    // read's deadline stops the wait for a line that never ends.
    std::thread::spawn(move || {
        let Ok((mut stream, _)) = listener.accept() else { return };
        for _ in 0..40 {
            std::thread::sleep(Duration::from_millis(100));
            if stream.write_all(b" ").is_err() {
                return;
            }
        }
        drop(dir);
    });
    let started = std::time::Instant::now();
    let merged = merge(&global_for(socket), json!([local_row()]));
    let waited = started.elapsed();
    assert_eq!(merged, json!([local_row()]));
    assert!(waited < CLOUD_READ_TIMEOUT * 2, "machine list waited {waited:?}");
}
