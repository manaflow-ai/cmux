//! `list-workspaces-known-v1` (hq#8813): a client that holds a tree sends its
//! identity and revisions as `known` and gets `{"unchanged": true}` while
//! nothing the tree shows changed. A client that sends no `known` gets the
//! reply it got before, byte for byte.

use super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

/// What a client keeps from a whole reply to send back as `known`.
fn known_of(reply: &Value) -> Value {
    assert!(reply["workspaces"].is_array(), "not a whole tree: {reply}");
    json!({
        "registry_id": reply["registry_id"],
        "generation": reply["generation"],
        "workspace_revision": reply["workspace_revision"],
        "pane_revision": reply["pane_revision"],
        "terminal_revision": reply["terminal_revision"],
        "tree_revision": reply["tree_revision"],
    })
}

fn list_since(mux: &Arc<Mux>, known: &Value) -> Value {
    run(mux, json!({"cmd": "list-workspaces", "known": known}))
}

fn assert_unchanged(reply: &Value, known: &Value) {
    assert_eq!(reply["unchanged"], json!(true), "{reply}");
    assert!(reply.get("workspaces").is_none(), "an unchanged reply carries no tree: {reply}");
    for field in [
        "registry_id",
        "generation",
        "workspace_revision",
        "pane_revision",
        "terminal_revision",
        "tree_revision",
    ] {
        assert_eq!(reply[field], known[field], "{field}");
    }
}

#[test]
fn a_list_without_known_is_the_reply_from_before_known_byte_for_byte() {
    let mux = Mux::new_for_test("known-absent", SurfaceOptions::default());
    mux.create_empty_workspace(Some("one".into()), None, None).unwrap();
    let listed = run(&mux, json!({"cmd": "list-workspaces"}));
    let mut expected = list_workspaces_reply(&mux).unwrap();
    expected.set("lines_written_before_read", json!(0));
    assert_eq!(listed.to_string(), expected.to_string());
    let mut keys: Vec<&str> = listed.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "generation",
            "groups",
            "lines_written_before_read",
            "pane_revision",
            "registry_id",
            "terminal_revision",
            "workspace_revision",
            "workspaces",
        ],
    );
    // `known: null` is no `known`.
    let null = run(&mux, json!({"cmd": "list-workspaces", "known": null}));
    assert_eq!(null.to_string(), expected.to_string());
    mux.shutdown();
}

#[test]
fn a_current_known_is_unchanged_until_something_the_tree_shows_changes() {
    let mux = Mux::new_for_test("known-current", SurfaceOptions::default());
    // Empty workspaces: a live shell would change its title on its own while the test reads.
    let workspace = mux.create_empty_workspace(Some("one".into()), None, None).unwrap().workspace;
    let surface: SurfaceId = 9_001;

    // A first `known` (empty: the phone has nothing yet) gets the whole tree and its revision.
    let first = list_since(&mux, &json!({}));
    assert!(first["tree_revision"].is_string(), "{first}");
    assert_eq!(first["workspaces"].as_array().unwrap().len(), 1);
    let known = known_of(&first);
    assert_unchanged(&list_since(&mux, &known), &known);

    // Terminal output and a scroll show nowhere in the tree.
    mux.emit(MuxEvent::SurfaceOutput(surface));
    mux.emit(MuxEvent::ScrollChanged { surface, offset: 3, at_bottom: false });
    assert_unchanged(&list_since(&mux, &known), &known);

    // A tab title changes no workspace, pane or terminal revision, and still counts (the event
    // is what every title change sends).
    mux.emit(MuxEvent::terminal_title(surface, Arc::from("vim")));
    let titled = list_since(&mux, &known);
    assert!(titled["workspaces"].is_array(), "a title change kept the old tree: {titled}");
    let known = known_of(&titled);
    assert_unchanged(&list_since(&mux, &known), &known);

    // A rename.
    assert!(mux.rename_workspace(workspace, "renamed".into()));
    let renamed = list_since(&mux, &known);
    assert_eq!(renamed["workspaces"][0]["name"], json!("renamed"), "{renamed}");
    let known = known_of(&renamed);

    // A new workspace.
    mux.create_empty_workspace(Some("two".into()), None, None).unwrap();
    let grown = list_since(&mux, &known);
    assert_eq!(grown["workspaces"].as_array().unwrap().len(), 2, "{grown}");
    let known = known_of(&grown);
    assert_unchanged(&list_since(&mux, &known), &known);
    mux.shutdown();
}

#[test]
fn a_partial_or_foreign_known_gets_the_whole_tree() {
    let mux = Mux::new_for_test("known-foreign", SurfaceOptions::default());
    mux.create_empty_workspace(Some("one".into()), None, None).unwrap();
    let known = known_of(&list_since(&mux, &json!({})));
    for field in [
        "registry_id",
        "generation",
        "workspace_revision",
        "pane_revision",
        "terminal_revision",
        "tree_revision",
    ] {
        let mut partial = known.clone();
        partial.as_object_mut().unwrap().remove(field);
        let reply = list_since(&mux, &partial);
        assert!(reply["workspaces"].is_array(), "without {field}: {reply}");
        let mut other = known.clone();
        other[field] = if known[field].is_string() { json!("other") } else { json!(999_999) };
        let reply = list_since(&mux, &other);
        assert!(reply["workspaces"].is_array(), "another {field}: {reply}");
    }
    // A tree revision from another daemon run (same count, other boot) is not this one.
    let mut restarted = known.clone();
    let count = known["tree_revision"].as_str().unwrap().rsplit_once('.').unwrap().1.to_string();
    restarted["tree_revision"] = json!(format!("0000000000000000.{count}"));
    assert!(list_since(&mux, &restarted)["workspaces"].is_array());
    mux.shutdown();
}

#[test]
fn known_is_advertised() {
    let mux = Mux::new_for_test("known-capability", SurfaceOptions::default());
    let identify = run(&mux, json!({"cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == LIST_WORKSPACES_KNOWN_CAPABILITY),
        "{identify}"
    );
    mux.shutdown();
}
