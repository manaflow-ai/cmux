//! Supervisor tests of chat widget routing (`chat_widgets.rs`): which installed extension's
//! `cmux.chat.widget/1` answers a tool call or a widget part, the context its render gets, and a
//! save of a local widget reaching the open widget and the next route without a restart.

use super::*;

/// Writes a local app `local/<name>` whose `cmux.chat.widget/1` draws with `export` and answers
/// `tools`.
fn write_widget(state: &Path, name: &str, export: &str, tools: Value) {
    let id = format!("local/{name}");
    write_app(&state.join("apps/local"), name, &id, json!({}));
    save_widget(state, name, export, tools);
}

/// Rewrites `local/<name>`'s widget entry (and bumps its version, as a save does).
fn save_widget(state: &Path, name: &str, export: &str, tools: Value) {
    let path = state.join("apps/local").join(name).join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let mut entry = json!({ "export": export, "title": "Card", "symbol": "star" });
    if !tools.is_null() {
        entry["options"] = json!({ "tools": tools });
    }
    manifest["implements"]["cmux.chat.widget/1"] = entry;
    let patch = manifest["version"]
        .as_str()
        .and_then(|v| v.rsplit('.').next())
        .and_then(|p| p.parse::<u32>().ok())
        .unwrap_or(0);
    manifest["version"] = json!(format!("1.0.{}", patch + 1));
    std::fs::write(&path, manifest.to_string()).unwrap();
}

fn route(f: &Fixture, args: Value) -> Value {
    f.supervisor
        .store_call(CLIENT, "apps.chat_widgets.route", args, Origin::Script)
        .unwrap()["widget"]
        .clone()
}

fn tool_call(name: &str) -> Value {
    json!({
        "key": "chat_1#call_7",
        "tool": {
            "name": name, "title": "Get pull request", "status": "completed",
            "input": { "owner": "manaflow-ai", "repo": "cmux", "pullNumber": 42 },
            "output": "{\"title\":\"Chat widgets\"}"
        }
    })
}

/// An agent's tool result renders a widget: the installed extension whose `options.tools`
/// matches the call answers, with the context its render gets, and mounting that answer draws
/// the extension's scene.
#[test]
fn a_tool_result_routes_to_the_matching_extension_and_its_scene_draws() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_widget(&f.state, "prcard", "renderCard", json!(["mcp__github__*pull_request*"]));
    f.supervisor.reload_local_apps(&prints);

    // Not installed: nothing answers, so the chat shows the call as it always did.
    assert_eq!(route(&f, tool_call("mcp__github__get_pull_request")), Value::Null);

    f.install("local/prcard");
    let widget = route(&f, tool_call("mcp__github__get_pull_request"));
    assert_eq!(widget["app"], "local/prcard", "{widget}");
    assert_eq!(widget["interface"], "cmux.chat.widget/1");
    assert_eq!(widget["title"], "Card");
    assert_eq!(widget["symbol"], "star");
    assert_eq!(
        widget["context"],
        json!({
            "surface": "chatWidget",
            "widget": { "key": "chat_1#call_7" },
            "tool": {
                "name": "mcp__github__get_pull_request", "title": "Get pull request",
                "status": "completed",
                "input": { "owner": "manaflow-ai", "repo": "cmux", "pullNumber": 42 },
                "output": "{\"title\":\"Chat widgets\"}"
            }
        })
    );
    // Another tool: no widget.
    assert_eq!(route(&f, tool_call("mcp__linear__get_issue")), Value::Null);

    // The page mounts exactly what the route answered, and the extension's scene comes back.
    let app = widget["app"].as_str().unwrap();
    f.mount("w1", app, "cmux.chat.widget/1", widget["context"].clone());

    // Hidden: it no longer answers.
    f.set("hide", "local/prcard", Origin::User, |op| op.hidden = Some(true)).unwrap();
    assert_eq!(route(&f, tool_call("mcp__github__get_pull_request")), Value::Null);
}

/// Two extensions that match: the more specific pattern wins, then the lower app id, whatever
/// the install order. (A bare `*`, which would answer every call, is refused by the interface
/// schema and scores 0 in `specificity`.)
#[test]
fn the_most_specific_pattern_wins_whatever_the_install_order() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_widget(&f.state, "broad", "renderBroad", json!(["mcp__github__*"]));
    write_widget(&f.state, "exact", "renderExact", json!(["mcp__github__get_pull_request"]));
    f.supervisor.reload_local_apps(&prints);
    for app in ["local/exact", "local/broad"] {
        f.install(app);
    }
    assert_eq!(route(&f, tool_call("mcp__github__get_pull_request"))["app"], "local/exact");
    assert_eq!(route(&f, tool_call("mcp__github__list_issues"))["app"], "local/broad");
    assert_eq!(route(&f, tool_call("shell")), Value::Null, "no pattern matches");
}

/// A widget part an agent sent names its extension: that one answers with the part's props,
/// whether or not it lists tools; a missing one answers nothing (the part's fallback text shows).
#[test]
fn a_widget_part_routes_to_the_extension_it_names() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_widget(&f.state, "prcard", "renderCard", Value::Null);
    f.supervisor.reload_local_apps(&prints);
    f.install("local/prcard");
    let part =
        json!({ "key": "msg_9#0", "app": "local/prcard", "props": { "repo": "o/r", "number": 7 } });
    let widget = route(&f, part);
    assert_eq!(
        widget["context"],
        json!({ "surface": "chatWidget", "widget": { "key": "msg_9#0" }, "props": { "repo": "o/r", "number": 7 } })
    );
    assert_eq!(route(&f, json!({ "key": "k", "app": "local/nobody", "props": {} })), Value::Null);
    // A tool call never reaches a widget that lists no tools.
    assert_eq!(route(&f, tool_call("mcp__github__get_pull_request")), Value::Null);
    // Malformed asks are refused, not guessed at.
    for bad in [
        json!({ "key": "", "app": "local/prcard" }),
        json!({ "key": "k" }),
        json!({ "key": "k", "app": "local/prcard", "props": [1] }),
        json!({ "key": "k", "tool": { "name": "t" }, "props": {} }),
    ] {
        let refused = f
            .supervisor
            .store_call(CLIENT, "apps.chat_widgets.route", bad.clone(), Origin::Script)
            .unwrap_err();
        assert_eq!(refused.code, "bad-request", "{bad}");
    }
}

/// Hot reload: a save of the installed widget extension redraws the open widget with the new
/// script's export and moves the route to its new tools, with no restart.
#[test]
fn a_save_of_the_widget_extension_reaches_the_open_widget_and_the_route() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_widget(&f.state, "prcard", "renderCard", json!(["mcp__github__get_pull_request"]));
    let prints = f.supervisor.reload_local_apps(&prints);
    f.install("local/prcard");
    let widget = route(&f, tool_call("mcp__github__get_pull_request"));
    f.mount("w1", "local/prcard", "cmux.chat.widget/1", widget["context"].clone());

    save_widget(&f.state, "prcard", "renderCardAgain", json!(["mcp__linear__*"]));
    f.supervisor.reload_local_apps(&prints);
    let scene = f.wait("the open widget's new scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "w1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(scene["ops"][0]["props"]["text"], "renderCardAgain", "{scene}");
    assert_eq!(route(&f, tool_call("mcp__github__get_pull_request")), Value::Null);
    assert_eq!(route(&f, tool_call("mcp__linear__get_issue"))["app"], "local/prcard");
}
