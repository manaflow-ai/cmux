//! The Chief registry against a real headless daemon (cx-ebm.60.1, .2): the
//! person makes, edits and deletes Chiefs with `cmux chief new|list|edit|
//! delete`; a Chief, on its own bound connection, changes its own picture and
//! only the fields the person allowed; other agents are refused.

use super::super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;
use serde_json::{Value, json};

#[path = "chief_manage.rs"]
mod manage;

#[path = "chief_config_edit.rs"]
mod config_edit;

/// A 1x1 PNG.
const PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0, 0,
    0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 10, b'I', b'D', b'A', b'T',
    0x78, 0x9c, 0x63, 0, 1, 0, 0, 5, 0, 1, 0x0d, 0x0a, 0x2d, 0xb4, 0, 0, 0, 0, b'I', b'E', b'N',
    b'D', 0xae, 0x42, 0x60, 0x82,
];

/// One `cmux.protocol/2` request on `conn`; the whole response.
fn v2(conn: &mut Conn, operation: &str, params: Value, key: Option<&str>) -> Value {
    let id = format!("reg-{}", conn.next);
    conn.next += 1;
    let mut params = params.as_object().cloned().unwrap_or_default();
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!("current"));
    let mut frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                           "operation": operation, "params": params});
    if let Some(key) = key {
        frame["idempotency_key"] = json!(key);
    }
    writeln!(conn.writer, "{frame}").unwrap();
    loop {
        let line = conn.line();
        if line["id"] == json!(id) && line["type"] == "response" {
            return line;
        }
    }
}

fn ok(response: &Value) -> Value {
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn reason(response: &Value) -> String {
    assert_eq!(response["ok"], false, "{response}");
    let code = response["error"]["code"].as_str().unwrap_or("").to_owned();
    match response["error"]["details"]["reason"].as_str() {
        Some(reason) if code == "operation.failed" => reason.to_owned(),
        _ => code,
    }
}

fn stdout_json(output: &Output) -> Value {
    assert_success(output);
    serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|e| panic!("not JSON ({e}): {}", String::from_utf8_lossy(&output.stdout)))
}

fn ids(list: &Value) -> Vec<String> {
    list["chiefs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_person_makes_edits_and_deletes_chiefs_with_the_cli() {
    let server = HeadlessServer::start("chief-registry-cli");
    let dir = unique_temp_dir("chief-registry-cli-files");
    fs::create_dir_all(&dir).unwrap();
    let picture = dir.join("ops.png");
    fs::write(&picture, PNG).unwrap();
    let instructions = dir.join("ops.md");
    fs::write(&instructions, "Watch the release train.\nAsk before any merge.").unwrap();

    // The default Chief is there before anything is made.
    let listed = stdout_json(&chief_cli(&server, &["list", "--json"], ""));
    assert_eq!(ids(&listed), vec!["agent_mux"], "{listed}");
    assert_eq!(listed["chiefs"][0]["is_default"], true);

    let made = stdout_json(&chief_cli(
        &server,
        &[
            "new",
            "--name",
            "Ops",
            "--role",
            "Release captain",
            "--personality",
            "Terse.",
            "--instructions-file",
            instructions.to_str().unwrap(),
            "--tools",
            "tell,spawn",
            "--self-edit",
            "avatar,role",
            "--avatar",
            picture.to_str().unwrap(),
            "--json",
        ],
        "",
    ));
    let id = made["id"].as_str().unwrap().to_owned();
    assert!(id.starts_with("agent_") && id.len() == "agent_".len() + 26, "{made}");
    assert_eq!(made["display_name"], "Ops");
    assert_eq!(made["role"], "Release captain");
    assert_eq!(made["instructions"], "Watch the release train.\nAsk before any merge.");
    assert_eq!(made["tools"], json!(["spawn", "tell"]));
    assert_eq!(made["self_edit"], json!(["avatar", "role"]));
    assert_eq!(made["avatar"]["media_type"], "image/png");
    assert_eq!(made["avatar"]["bytes"], PNG.len());

    // The text form names it; the default comes first.
    let text = chief_cli(&server, &["list"], "");
    assert_success(&text);
    let lines: Vec<String> =
        String::from_utf8_lossy(&text.stdout).lines().map(str::to_owned).collect();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert!(lines[0].starts_with("agent_mux\tChief"), "{lines:?}");
    assert_eq!(lines[1], format!("{id}\tOps\tRelease captain"));

    // Edit by name; the picture is still the same bytes.
    let edited =
        stdout_json(&chief_cli(&server, &["edit", "Ops", "--name", "Ops 2", "--json"], ""));
    assert_eq!(edited["id"], json!(id));
    assert_eq!(edited["display_name"], "Ops 2");
    assert!(edited["rev"].as_u64().unwrap() > made["rev"].as_u64().unwrap(), "{edited}");
    let mut home = Conn::open(&server.socket);
    let avatar = ok(&v2(&mut home, "chief.profile.avatar.get", json!({"chief": id}), None));
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(avatar["avatar"]["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(bytes, PNG);

    // An unknown tool is refused and changes nothing.
    let refused = chief_cli(&server, &["edit", &id, "--tools", "root_shell"], "");
    assert_eq!(refused.status.code(), Some(1), "{}", String::from_utf8_lossy(&refused.stderr));
    let after = ok(&v2(&mut home, "chief.profile.get", json!({"chief": id}), None));
    assert_eq!(after["tools"], json!(["spawn", "tell"]));

    // The default Chief cannot be deleted; the new one can, and its id is gone.
    let kept = chief_cli(&server, &["delete", "agent_mux"], "");
    assert_eq!(kept.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&kept.stderr).contains("chief_is_default"), "{kept:?}");
    let deleted = stdout_json(&chief_cli(&server, &["delete", "Ops 2", "--json"], ""));
    assert_eq!(deleted["id"], json!(id));
    let listed = stdout_json(&chief_cli(&server, &["list", "--json"], ""));
    assert_eq!(ids(&listed), vec!["agent_mux"]);
    assert_eq!(
        reason(&v2(&mut home, "chief.profile.get", json!({"chief": id}), None)),
        "chief_not_found"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_chief_changes_its_own_picture_and_only_the_fields_the_person_allowed() {
    let server = HeadlessServer::start("chief-registry-self");
    let mut home = Conn::open(&server.socket);
    let made = ok(&v2(
        &mut home,
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Research"}),
        Some("make-scout"),
    ));
    assert_eq!(made["replayed"], false);
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    // Every new Chief edits its whole profile and engine (u2586, 2026-10-19).
    let full = json!(["avatar", "display_name", "engine", "instructions", "personality", "role"]);
    assert_eq!(made["value"]["self_edit"], full, "the default self_edit");

    // A retry under the same key is the same Chief; other params under it are refused.
    let again = ok(&v2(
        &mut home,
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Research"}),
        Some("make-scout"),
    ));
    assert_eq!(again["replayed"], true);
    assert_eq!(again["value"]["id"], json!(scout));
    let clash =
        v2(&mut home, "chief.profile.create", json!({"display_name": "Other"}), Some("make-scout"));
    assert_eq!(reason(&clash), "idempotency.conflict");

    // The Chief on its own bound connection.
    let token = home.request("conversation-agent-token", json!({"participant": scout}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut chief = Conn::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": scout, "token": token}));
    let data = {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(PNG)
    };
    let set = ok(&v2(
        &mut chief,
        "chief.profile.avatar.set",
        json!({"chief": scout, "media_type": "image/png", "data": data}),
        Some("pic-1"),
    ));
    assert_eq!(set["value"]["avatar"]["bytes"], PNG.len());

    // Everything of itself outside self_edit is the person's; its `chiefs`
    // grant (on by default) never reaches past its own grant
    // (chief_manage.rs; the cases are in chief_manage.rs's tests).
    for (operation, params, expected) in [
        (
            "chief.profile.update",
            json!({"chief": scout, "tools": ["browser", "cloud_vms"]}),
            "chief_self_edit_denied",
        ),
        (
            "chief.profile.update",
            json!({"chief": scout, "self_edit": ["avatar", "instructions"]}),
            "chief_self_edit_denied",
        ),
        ("chief.profile.update", json!({"chief": scout, "locked": true}), "chief_self_edit_denied"),
        (
            "chief.profile.update",
            json!({"chief": "agent_mux", "role": "x"}),
            "target_exceeds_caller",
        ),
        (
            "chief.profile.avatar.set",
            json!({"chief": "agent_mux", "clear": true}),
            "target_exceeds_caller",
        ),
        ("chief.profile.delete", json!({"chief": scout}), "chief_delete_denied"),
        (
            "chief.profile.create",
            json!({"display_name": "Stronger", "tools": ["browser"]}),
            "grant_exceeds_caller",
        ),
    ] {
        let key = format!("deny-{operation}-{params}");
        let refused = v2(&mut chief, operation, params.clone(), Some(&key));
        assert_eq!(reason(&refused), expected, "{operation} {params}: {refused}");
    }
    let unchanged = ok(&v2(&mut home, "chief.profile.get", json!({"chief": scout}), None));
    assert_eq!(unchanged["display_name"], "Scout");
    assert_eq!(unchanged["tools"], json!(["chiefs", "spawn", "tell", "workspaces"]));
    assert_eq!(unchanged["self_edit"], full);

    // Its engine is its own to change: any harness when its list is empty.
    let tuned = ok(&v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": scout, "harness": "codex", "model": "gpt-5", "effort": "high"}),
        Some("engine-1"),
    ));
    assert_eq!(
        tuned["value"]["engine"],
        json!({"harness": "codex", "model": "gpt-5", "effort": "high"}),
        "{tuned}"
    );
    let unchanged = ok(&v2(&mut home, "chief.profile.get", json!({"chief": scout}), None));

    // The person narrows it to the picture and the role; then the Chief may
    // change only those.
    let rev = unchanged["rev"].as_u64().unwrap();
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": scout, "expected_rev": rev, "self_edit": ["avatar", "role"]}),
        Some("allow-role"),
    ));
    let stale = v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": scout, "expected_rev": rev, "role": "x"}),
        Some("stale"),
    );
    assert_eq!(reason(&stale), "rev_mismatch");
    let renamed = ok(&v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": scout, "role": "Lead researcher"}),
        Some("role-1"),
    ));
    assert_eq!(renamed["value"]["role"], "Lead researcher");
    for params in [
        json!({"chief": scout, "display_name": "Boss"}),
        json!({"chief": scout, "harness": "claude"}),
    ] {
        let refused = v2(
            &mut chief,
            "chief.profile.update",
            params.clone(),
            Some(&format!("narrow-{params}")),
        );
        assert_eq!(reason(&refused), "chief_self_edit_denied", "{params}: {refused}");
    }

    // A picture whose bytes are not its type is refused.
    let fake = v2(
        &mut chief,
        "chief.profile.avatar.set",
        json!({"chief": scout, "media_type": "image/png", "data": "R0lGODlhAQABAAAAACw="}),
        Some("pic-bad"),
    );
    assert_eq!(reason(&fake), "validation.invalid", "{fake}");

    // A Chief reads every record.
    let listed = ok(&v2(&mut chief, "chief.profile.list", json!({}), None));
    assert_eq!(ids(&listed), vec!["agent_mux".to_owned(), scout]);

    // An agent that is not a Chief reads nothing.
    let other_token = home
        .request("conversation-agent-token", json!({"participant": "agent_helper"}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut helper = Conn::open(&server.socket);
    helper
        .request("conversation-bind", json!({"participant": "agent_helper", "token": other_token}));
    assert_eq!(reason(&v2(&mut helper, "chief.profile.list", json!({}), None)), "origin.forbidden");
}

/// A person-authorized agent caller may use the owner CLI for Chief writes.
/// The daemon still enforces the durable lock, while the history records an
/// ACP session actor instead of collapsing the change into `user_local`.
#[test]
fn an_agent_caller_can_write_unlocked_chiefs_and_history_names_the_agent() {
    let server = HeadlessServer::start("chief-registry-agent");
    let made = stdout_json(&chief_cli_as(
        &server,
        &["new", "--name", "Ops", "--role", "Ops lead", "--json"],
        "",
        &[("ACPMUX_SESSION_ID", "s_agent_1")],
    ));
    let id = made["id"].as_str().unwrap().to_owned();

    let edited = stdout_json(&chief_cli_as(
        &server,
        &["edit", &id, "--role", "Night watch", "--json"],
        "",
        &[("ACPMUX_SESSION_ID", "s_agent_1")],
    ));
    assert_eq!(edited["id"], id);
    assert_eq!(edited["role"], "Night watch");

    let history = stdout_json(&chief_cli_as(
        &server,
        &["history", &id, "--json"],
        "",
        &[("ACPMUX_SESSION_ID", "s_agent_1")],
    ));
    let revisions = history["revisions"].as_array().unwrap();
    assert!(revisions.iter().all(|revision| revision["actor"] == "agent"), "{history}");

    let agent_lock = chief_cli_as(
        &server,
        &["edit", &id, "--lock", "--json"],
        "",
        &[("ACPMUX_SESSION_ID", "s_agent_1")],
    );
    assert_eq!(agent_lock.status.code(), Some(1), "{agent_lock:?}");
    assert!(
        String::from_utf8_lossy(&agent_lock.stderr).contains("chief_lock_person_only"),
        "{agent_lock:?}"
    );

    let locked = stdout_json(&chief_cli(&server, &["edit", &id, "--lock", "--json"], ""));
    assert_eq!(locked["locked"], true);
    let refused = chief_cli_as(
        &server,
        &["edit", &id, "--role", "Blocked", "--json"],
        "",
        &[("ACPMUX_SESSION_ID", "s_agent_1")],
    );
    assert_eq!(refused.status.code(), Some(1), "{refused:?}");
    assert!(String::from_utf8_lossy(&refused.stderr).contains("chief_locked"), "{refused:?}");

    let delete_refused = chief_cli_as(
        &server,
        &["delete", &id, "--json"],
        "",
        &[("ACPMUX_SESSION_ID", "s_agent_1")],
    );
    assert_eq!(delete_refused.status.code(), Some(1), "{delete_refused:?}");
    assert!(
        String::from_utf8_lossy(&delete_refused.stderr).contains("chief_locked"),
        "{delete_refused:?}"
    );
    let deleted = stdout_json(&chief_cli(&server, &["delete", &id, "--json"], ""));
    assert_eq!(deleted["id"], id);
}

/// `cmux ARGS` (global flags first) as a person plus `env`: the agent caller
/// markers are removed, then `env` names the one the test means.
fn cmux_as(server: &HeadlessServer, args: &[&str], env: &[(&str, &str)]) -> Output {
    cmux_at(&server.socket, args, env)
}

/// [`cmux_as`] on the socket `socket`.
fn cmux_at(socket: &std::path::Path, args: &[&str], env: &[(&str, &str)]) -> Output {
    let mut command = Command::new(bin());
    command.arg("--socket").arg(socket).args(args).env("LC_ALL", "C");
    command.env_remove("CMUX_TUI_SOCKET");
    for key in [
        "ACPMUX_ENV",
        "ACPMUX_SESSION_ID",
        "ACPMUX_SESSION_NAME",
        "CMUX_CHIEF_OWNER_SOCKET",
        "CMUX_AGENT_PRINCIPAL",
        "CMUX_AGENT_CLASS",
        "CMUX_AGENT_HARNESS",
    ] {
        command.env_remove(key);
    }
    command.envs(env.iter().copied());
    command.stdin(Stdio::null()).output().unwrap()
}

/// The other paths to a Chief control (cx-ebm.60.9 layer 1, hq-6d 2026-10-14):
/// `cmux chief engine` with a change, `cmux chief stop`, `cmux chief
/// shutdown`, every raw path to a `chief.*` write (`cmux raw operation`,
/// `cmux raw command`) and the app actions that stop or archive a Chief refuse
/// an agent caller with the same `origin.forbidden` / `agent_caller` / marker
/// shape as the control command, before they connect to anything. New Chief is
/// an owner action available to a person-authorized agent. The reads
/// (`chief engine` with no change, `chief.engine.get`,
/// `chief.profile.list|get|avatar.get`) stay open.
#[test]
fn an_agent_caller_cannot_control_or_raw_write_a_chief() {
    let server = HeadlessServer::start("chief-registry-agent-raw");
    let made = stdout_json(&chief_cli(&server, &["new", "--name", "Ops", "--json"], ""));
    let id = made["id"].as_str().unwrap().to_owned();
    let mut home = Conn::open(&server.socket);
    let default_before =
        ok(&v2(&mut home, "chief.profile.get", json!({"chief": "agent_mux"}), None));
    let params = |mut value: Value| {
        value["machine"] = json!("current");
        value["session"] = json!("current");
        value.to_string()
    };
    let update = params(json!({"chief": id, "role": "Boss", "tools": ["tell", "browser"]}));
    let update_default = params(json!({"chief": "agent_mux", "instructions": "Merge all."}));
    let create = params(json!({"display_name": "Rogue"}));
    let delete = params(json!({"chief": id}));
    let avatar = params(json!({"chief": id, "clear": true}));
    let engine = params(json!({"model": "other-model"}));
    let stop = params(json!({}));
    let raw_update = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "raw-1",
        "operation": "chief.profile.update", "idempotency_key": "raw-update-1",
        "params": {"machine": "current", "session": "current", "chief": id, "role": "Boss"},
    })
    .to_string();
    let raw_op = |name: &str, params: &str| -> Vec<String> {
        ["--json", "raw", "operation", name, "--params-json", params]
            .iter()
            .map(|s| s.to_string())
            .collect()
    };
    let argv = |words: &[&str]| -> Vec<String> { words.iter().map(|s| s.to_string()).collect() };
    let refused_calls: Vec<(Vec<String>, &str)> = vec![
        (argv(&["--json", "chief", "engine", "--model", "m"]), "engine"),
        (argv(&["--json", "chief", "engine", "--effort", "high"]), "engine"),
        (argv(&["--json", "chief", "stop"]), "stop"),
        (argv(&["--json", "chief", "stop", "a3"]), "stop"),
        (raw_op("chief.profile.update", &update), "chief.profile.update"),
        (raw_op("chief.profile.update", &update_default), "chief.profile.update"),
        (raw_op("chief.profile.create", &create), "chief.profile.create"),
        (raw_op("chief.profile.delete", &delete), "chief.profile.delete"),
        (raw_op("chief.profile.avatar.set", &avatar), "chief.profile.avatar.set"),
        (raw_op("chief.engine.set", &engine), "chief.engine.set"),
        (raw_op("chief.stop", &stop), "chief.stop"),
        (
            argv(&["--json", "raw", "command", "--request-json", &raw_update]),
            "chief.profile.update",
        ),
        (argv(&["--json", "chief", "shutdown"]), "shutdown"),
        (argv(&["--json", "action", "run", "home.archiveChief"]), "home.archiveChief"),
        (argv(&["--json", "action", "run", "home.deleteChief"]), "home.deleteChief"),
        (argv(&["--json", "action", "run", "home.stopChief"]), "home.stopChief"),
        (argv(&["--json", "action", "run", "home.stopAllAgents"]), "home.stopAllAgents"),
        (argv(&["--json", "home", "archive-chief", "--chief", &id]), "home archive-chief"),
        (argv(&["--json", "home", "delete-chief", "--chief", &id]), "home delete-chief"),
    ];
    let nowhere = std::env::temp_dir().join(format!("no-such-chief-{}.sock", std::process::id()));
    for (key, value) in [
        ("ACPMUX_SESSION_ID", "s_chief_turn"),
        ("CMUX_AGENT_PRINCIPAL", id.as_str()),
        ("CMUX_CHIEF_OWNER_SOCKET", "/tmp/chief-owner.sock"),
    ] {
        for (args, refused) in &refused_calls {
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            let output = cmux_as(&server, &args, &[(key, value)]);
            assert_eq!(output.status.code(), Some(1), "{key} {args:?}: {output:?}");
            assert!(output.stdout.is_empty(), "{key} {args:?}: {output:?}");
            let error = json_error(&output);
            assert_eq!(error["code"], "origin.forbidden", "{key} {args:?}: {error}");
            assert_eq!(error["details"]["reason"], "agent_caller", "{key} {args:?}: {error}");
            assert_eq!(error["details"]["marker"], key, "{key} {args:?}: {error}");
            assert_eq!(error["details"]["refused"], *refused, "{key} {args:?}: {error}");
            // The refusal comes before any connection: with no socket at all
            // it is the same refusal, not a connect failure (exit 3).
            let output = cmux_at(&nowhere, &args, &[(key, value)]);
            assert_eq!(output.status.code(), Some(1), "{key} {args:?} (no socket): {output:?}");
            assert_eq!(json_error(&output)["details"]["reason"], "agent_caller", "{key} {args:?}");
        }
    }

    for args in [
        vec!["--json", "action", "run", "home.newChief"],
        vec!["--json", "home", "new-chief", "--name", "Rogue"],
    ] {
        let output =
            cmux_as(&server, &args, &[("CMUX_CHIEF_OWNER_SOCKET", "/tmp/chief-owner.sock")]);
        assert_eq!(output.status.code(), Some(1), "{args:?}: {output:?}");
        let error = json_error(&output);
        assert_eq!(error["code"], "origin.forbidden", "{args:?}: {error}");
        assert_eq!(error["details"]["reason"], "agent_caller", "{args:?}: {error}");
    }

    // Nothing was written.
    let listed = ok(&v2(&mut home, "chief.profile.list", json!({}), None));
    assert_eq!(ids(&listed), vec!["agent_mux".to_owned(), id.clone()], "{listed}");
    let after = ok(&v2(&mut home, "chief.profile.get", json!({"chief": id}), None));
    assert_eq!(after["rev"], made["rev"], "{after}");
    assert_eq!(after["role"], made["role"], "{after}");
    assert_eq!(after["tools"], made["tools"], "{after}");
    let default_after =
        ok(&v2(&mut home, "chief.profile.get", json!({"chief": "agent_mux"}), None));
    assert_eq!(default_after, default_before);

    // The reads stay open to an agent caller.
    let agent = [("ACPMUX_SESSION_ID", "s_chief_turn")];
    let listed = stdout_json(&cmux_as(
        &server,
        &["--json", "raw", "operation", "chief.profile.list", "--params-json", &stop],
        &agent,
    ));
    assert_eq!(ids(&listed), vec!["agent_mux".to_owned(), id.clone()], "{listed}");
    let get = params(json!({"chief": id}));
    let got = stdout_json(&cmux_as(
        &server,
        &["--json", "raw", "operation", "chief.profile.get", "--params-json", &get],
        &agent,
    ));
    assert_eq!(got["id"], json!(id), "{got}");
    let avatar = stdout_json(&cmux_as(
        &server,
        &["--json", "raw", "operation", "chief.profile.avatar.get", "--params-json", &get],
        &agent,
    ));
    assert_eq!(avatar["chief"], json!(id), "{avatar}");
    // `chief engine` with no change and `chief.engine.get` are reads: they
    // reach the daemon, which has no brain here and answers its own
    // not-configured refusal, not the agent one.
    let read = cmux_as(&server, &["chief", "engine"], &agent);
    assert_eq!(read.status.code(), Some(1), "{read:?}");
    assert!(String::from_utf8_lossy(&read.stderr).contains("not_configured"), "{read:?}");
    let read = cmux_as(
        &server,
        &["--json", "raw", "operation", "chief.engine.get", "--params-json", &stop],
        &agent,
    );
    let error = json_error(&read);
    assert_ne!(error["details"]["reason"], "agent_caller", "{error}");
    assert!(error.to_string().contains("not_configured"), "{error}");

    // The person still writes through the raw path.
    let person = stdout_json(&cmux_as(
        &server,
        &["--json", "raw", "operation", "chief.profile.update", "--params-json", &update],
        &[],
    ));
    assert_eq!(person["value"]["role"], "Boss", "{person}");
}

/// The Chief and the change of the next `chief-changed` event on the page's WebSocket.
fn next_chief_change(page: &mut Ws) -> (String, String) {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "chief-changed" {
            let field = |name: &str| event[name].as_str().unwrap_or_default().to_owned();
            return (field("chief"), field("change"));
        }
    }
}

#[test]
fn every_chief_change_reaches_the_subscribers_that_asked() {
    use base64::Engine as _;
    // cx-ebm.60.4: Home and the Channels page redraw their Chiefs on an
    // event, not by polling chief.profile.list.
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("chief-changed", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == "chief-events-v1"),
        "{identity}"
    );
    page.request("set-client-info", json!({"name": "page", "capabilities": ["chief-events-v1"]}));
    page.request("subscribe", json!({}));
    // A subscriber that did not ask hears none of it.
    let mut quiet = Conn::open(&server.socket);
    quiet.request("subscribe", json!({}));
    let mut home = Conn::open(&server.socket);

    let made = ok(&v2(
        &mut home,
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Research"}),
        Some("changed-make"),
    ));
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    assert_eq!(next_chief_change(&mut page), (scout.clone(), "created".to_owned()));

    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": scout, "display_name": "Boss"}),
        Some("changed-edit"),
    ));
    assert_eq!(next_chief_change(&mut page), (scout.clone(), "updated".to_owned()));

    ok(&v2(
        &mut home,
        "chief.profile.avatar.set",
        json!({"chief": scout, "media_type": "image/png",
               "data": base64::engine::general_purpose::STANDARD.encode(PNG)}),
        Some("changed-picture"),
    ));
    assert_eq!(next_chief_change(&mut page), (scout.clone(), "updated".to_owned()));

    // An edit that changes nothing, and a refused write, say nothing.
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": scout, "display_name": "Boss"}),
        Some("changed-same"),
    ));
    let refused = v2(&mut home, "chief.profile.delete", json!({"chief": "agent_mux"}), Some("x"));
    assert_eq!(refused["ok"], false, "{refused}");
    ok(&v2(&mut home, "chief.profile.delete", json!({"chief": scout}), Some("changed-delete")));
    assert_eq!(next_chief_change(&mut page), (scout.clone(), "deleted".to_owned()));
    // The list names the deleted Chief apart from the live ones (Home hides its direct message).
    let listed = ok(&v2(&mut home, "chief.profile.list", json!({}), None));
    assert!(
        !listed["chiefs"].as_array().unwrap().iter().any(|c| c["id"] == json!(scout)),
        "{listed}"
    );
    assert!(listed["deleted"].as_array().unwrap().contains(&json!(scout)), "{listed}");

    quiet.request("identify", json!({}));
    assert!(
        !quiet.events.iter().any(|event| event["event"] == "chief-changed"),
        "{:?}",
        quiet.events
    );
}
