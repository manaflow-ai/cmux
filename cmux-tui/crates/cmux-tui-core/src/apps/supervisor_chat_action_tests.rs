//! Supervisor tests of message actions (`cmux.chat.action/1`,
//! `chat_actions.rs`): the menu rows the daemon lists for a message, and the
//! catalog op a picked row runs.

use super::super::chat_actions::{ChatActionRequest, ChatMessage};
use super::super::supervisor::ApiError;
use super::*;

/// Gives the app in `dir` the message actions `actions` and, when `version`
/// is set, that version.
fn save_actions(dir: &Path, actions: Value, version: Option<&str>) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.chat.action/1"] = json!({ "options": { "actions": actions } });
    if let Some(version) = version {
        manifest["version"] = json!(version);
    }
    std::fs::write(&path, manifest.to_string()).unwrap();
}

fn spy_dir(f: &Fixture) -> PathBuf {
    f.state.join("apps/local/spy")
}

/// The spy's two rows: an issue from any message, a doc from a reply only.
fn spy_actions() -> Value {
    json!([
        { "id": "issue", "title": "Make an issue from this", "symbol": "ladybug", "op": "local.spy.go" },
        { "id": "doc", "title": "Send this reply to a doc", "op": "local.spy.go", "roles": ["assistant"] }
    ])
}

fn list(f: &Fixture, role: Option<&str>) -> Result<Value, ApiError> {
    let args = role.map_or_else(|| json!({}), |role| json!({ "role": role }));
    f.supervisor.store_call(CLIENT, "apps.chat_actions.list", args, Origin::User)
}

/// The listed `(app, id)` rows for a message of `role`.
fn rows(f: &Fixture, role: &str) -> Vec<(String, String)> {
    list(f, Some(role)).unwrap()["actions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| (a["app"].as_str().unwrap().into(), a["id"].as_str().unwrap().into()))
        .collect()
}

fn message(role: &str) -> ChatMessage {
    ChatMessage {
        id: "m1".into(),
        role: role.into(),
        text: "The build fails on arm64.".into(),
        session: Some("s1".into()),
    }
}

/// `apps-chat-action` for the spy's `action` on a message of `role`, answered.
fn pick(f: &Fixture, action: &str, role: &str) -> Result<Value, ApiError> {
    let (tx, rx) = channel();
    let request = ChatActionRequest {
        app: "local/spy".into(),
        action: action.into(),
        message: message(role),
        origin: Origin::User,
        gesture: None,
        caller: None,
    };
    f.supervisor.chat_action(request, Box::new(move |r| tx.send(r).unwrap()));
    rx.recv_timeout(Duration::from_secs(10)).unwrap()
}

/// The args each message action run of `app` got, in order.
fn runs(f: &Fixture, app: &str) -> Vec<Value> {
    f.supervisor.logs(CLIENT, app, false)["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|l| l["message"].as_str()?.strip_prefix("chat-action "))
        .map(|args| serde_json::from_str(args).unwrap())
        .collect()
}

/// An installed extension's rows are listed for the messages they name,
/// with title, symbol and the extension's name; an uninstalled or hidden
/// extension adds none.
#[test]
fn an_installed_extensions_message_actions_are_listed_by_role() {
    let f = fixture();
    save_actions(&spy_dir(&f), spy_actions(), None);
    f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(list(&f, None).unwrap()["actions"], json!([]), "not installed yet");

    f.install("local/spy");
    assert_eq!(
        list(&f, Some("user")).unwrap()["actions"],
        json!([{
            "app": "local/spy", "extension": "Demo", "id": "issue",
            "title": "Make an issue from this", "symbol": "ladybug"
        }])
    );
    let spy = |id: &str| ("local/spy".to_string(), id.to_string());
    assert_eq!(rows(&f, "assistant"), [spy("issue"), spy("doc")]);
    assert_eq!(list(&f, None).unwrap()["actions"].as_array().unwrap().len(), 2);
    assert_eq!(list(&f, Some("system")).unwrap_err().code, "apps.chat_action.role");

    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert_eq!(rows(&f, "assistant"), [], "a hidden extension adds nothing");
}

/// Picking a row runs its catalog op with the action and the message, and
/// answers the op's answer.
#[test]
fn a_picked_message_action_runs_its_op_with_the_message() {
    let f = fixture();
    save_actions(&spy_dir(&f), spy_actions(), None);
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");

    assert_eq!(pick(&f, "doc", "assistant").unwrap(), json!({ "value": "go" }));
    assert_eq!(
        runs(&f, "local/spy"),
        [json!({
            "action": "doc",
            "message": {
                "id": "m1", "role": "assistant", "text": "The build fails on arm64.", "session": "s1"
            }
        })]
    );
}

/// A row the app does not list for the message is refused before any op
/// runs: an unknown id, a row for the other role, or a role no message has.
#[test]
fn an_action_the_menu_did_not_offer_runs_nothing() {
    let f = fixture();
    save_actions(&spy_dir(&f), spy_actions(), None);
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");

    assert_eq!(pick(&f, "nope", "user").unwrap_err().code, "apps.chat_action.unknown");
    assert_eq!(pick(&f, "doc", "user").unwrap_err().code, "apps.chat_action.unknown");
    assert_eq!(pick(&f, "issue", "system").unwrap_err().code, "apps.chat_action.role");
    assert_eq!(runs(&f, "local/spy"), Vec::<Value>::new());
}

/// A save of the installed extension's manifest changes the menu with no
/// restart, and a removed row can no longer run.
#[test]
fn a_save_of_the_manifest_updates_the_menu_live() {
    let f = fixture();
    save_actions(&spy_dir(&f), spy_actions(), None);
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");

    let only_doc = json!([{ "id": "doc", "title": "To a doc", "op": "local.spy.go" }]);
    save_actions(&spy_dir(&f), only_doc, Some("1.0.1"));
    f.supervisor.reload_local_apps(&prints);
    f.wait("the reload's apps-changed", |e| {
        e["event"] == "apps-changed"
            && e["transaction"] == "local-reload"
            && e["app"] == "local/spy"
    });
    assert_eq!(rows(&f, "user"), [("local/spy".to_string(), "doc".to_string())]);
    assert_eq!(pick(&f, "issue", "user").unwrap_err().code, "apps.chat_action.unknown");
}

/// Safe mode turns every extension off: no rows.
#[test]
fn safe_mode_lists_no_message_actions() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({}));
    let actions = json!([{ "id": "issue", "title": "Issue", "op": "demo.go" }]);
    save_actions(&root.0.join("bundled/demo"), actions, None);
    let f = fixture_safe(&[], Duration::from_secs(60), root, true);
    f.install("cmux/demo");
    assert_eq!(list(&f, None).unwrap()["actions"], json!([]));
}
