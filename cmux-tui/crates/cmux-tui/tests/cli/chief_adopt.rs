//! `chief.profile.adopt` (`chief-profile-adopt-v1`) against a real headless
//! daemon: the person makes an agent that is already in a conversation a
//! Chief record under its own id with `cmux chief adopt`. The DM and its
//! history stay the agent's, its credential still works, and the record gets
//! a new Chief's defaults. Each refusal is one behavior: the default Chief, a
//! person, an unknown agent, a live Chief, a deleted Chief (its tombstone and
//! kept memory are never revived), an idempotency key reused for another
//! request, and an agent caller of the CLI. The adopt reaches the Chief brain
//! supervisor like a create.

use serde_json::{Value, json};

use super::*;

fn v2(conn: &mut Conn, operation: &str, params: Value, key: Option<&str>) -> Value {
    let id = format!("adopt-{}", conn.next);
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

/// A DM between the person and `agent` (display name `name`); its id.
fn dm_with(home: &mut Conn, agent: &str, name: &str) -> String {
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": format!("dm-{agent}"), "actor": "user_local", "title": name,
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": agent, "kind": "agent", "display_name": name, "agent_class": "mux",
                    "acp_session": agent}]}),
    );
    created["conversation"]["id"].as_str().unwrap().to_owned()
}

/// One v1 request; the whole reply, refused or not.
fn try_request(conn: &mut Conn, cmd: &str, params: Value) -> Value {
    let id = json!(format!("try-{}", conn.next));
    conn.next += 1;
    let mut body = params.as_object().cloned().unwrap_or_default();
    body.insert("id".into(), id.clone());
    body.insert("cmd".into(), json!(cmd));
    writeln!(conn.writer, "{}", Value::Object(body)).unwrap();
    loop {
        let value = conn.line();
        if value.get("event").is_none() && value["id"] == id {
            return value;
        }
    }
}

/// `chief.profile.adopt` on `home`, retried while the participant's old
/// connection is still being closed by the daemon (`participant_bound`).
fn adopt_once_unbound(home: &mut Conn, params: Value, key: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let response = v2(home, "chief.profile.adopt", params.clone(), Some(key));
        if response["ok"] == true || reason(&response) != "participant_bound" {
            return response;
        }
        assert!(Instant::now() < deadline, "the old connection never went away: {response}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn say(conn: &mut Conn, conversation: &str, key: &str, text: &str) {
    conn.request(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": key,
               "op": {"kind": "message.send", "client_msg_id": key,
                      "parts": [{"type": "text", "text": text}]}}),
    );
}

fn texts(home: &mut Conn, conversation: &str) -> Vec<(String, String)> {
    let snapshot =
        home.request("conversation-snapshot", json!({"conversation": conversation, "tail": 50}));
    snapshot["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            (
                m["author"].as_str().unwrap_or("").to_owned(),
                m["parts"][0]["text"].as_str().unwrap_or("").to_owned(),
            )
        })
        .collect()
}

#[test]
fn the_person_adopts_an_agent_and_it_keeps_its_dm_history_and_credential() {
    let server = HeadlessServer::start("chief-adopt");
    let mut home = Conn::open(&server.socket);
    let identity = home.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == "chief-profile-adopt-v1"),
        "{identity}"
    );
    let dm = dm_with(&mut home, "agent_release", "Release Chief");
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_release"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Conn::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_release", "token": token}));
    say(&mut home, &dm, "q1", "Is the train ready?");
    say(&mut home, &dm, "q2", "The 0.66 notes too, please.");
    let before = texts(&mut home, &dm);
    // A subscriber that asked for Chief changes hears the adopt as a create.
    let mut watcher = Conn::open(&server.socket);
    watcher.request(
        "set-client-info",
        json!({"name": "watcher", "capabilities": ["chief-events-v1"]}),
    );
    watcher.request("subscribe", json!({}));

    // While its agent session is bound, the adopt is refused with a hint:
    // two processes never speak as one participant.
    let output =
        chief_cli(&server, &["adopt", "agent_release", "--role", "Release trains", "--json"], "");
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("participant_bound"), "{output:?}");
    // The session stops; the adopt goes through.
    drop(agent);
    let record = adopt_once_unbound(
        &mut home,
        json!({"participant_id": "agent_release", "role": "Release trains"}),
        "adopt-release",
    );
    let record = ok(&record)["value"].clone();
    assert_eq!(record["id"], "agent_release", "{record}");
    assert_eq!(record["display_name"], "Release Chief");
    assert_eq!(record["role"], "Release trains");
    assert_eq!(
        record["self_edit"],
        json!(["avatar", "display_name", "engine", "instructions", "personality", "role"])
    );
    assert_eq!(record["tools"], json!(["chiefs", "spawn", "tell", "workspaces"]));
    assert_eq!(record["instructions"], "");
    assert_eq!(record["is_default"], false);

    let change = loop {
        let event = watcher.event();
        if event["event"] == "chief-changed" {
            break event;
        }
    };
    assert_eq!(change["chief"], "agent_release", "{change}");
    assert_eq!(change["change"], "created", "{change}");

    // The DM and its history are the same. The credential issued before the
    // adopt is revoked; the person mints the Chief's new one (no brain
    // supervisor here) and it posts in the same DM.
    assert_eq!(texts(&mut home, &dm), before);
    let mut old = Conn::open(&server.socket);
    let refused = try_request(
        &mut old,
        "conversation-bind",
        json!({"participant": "agent_release", "token": token}),
    );
    assert_eq!(refused["ok"], false, "a pre-adopt credential bound: {refused}");
    let fresh =
        home.request("conversation-agent-token", json!({"participant": "agent_release"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Conn::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_release", "token": fresh}));
    say(&mut agent, &dm, "a2", "Adopted and still here.");
    let after = texts(&mut home, &dm);
    assert_eq!(after.len(), before.len() + 1);
    assert_eq!(
        after.last().unwrap(),
        &("agent_release".to_owned(), "Adopted and still here.".to_owned())
    );
    let listed = ok(&v2(&mut home, "chief.profile.list", json!({}), None));
    let ids: Vec<&str> =
        listed["chiefs"].as_array().unwrap().iter().filter_map(|c| c["id"].as_str()).collect();
    assert_eq!(ids, vec!["agent_mux", "agent_release"], "{listed}");

    // Idempotent per key: a retry is the committed record; another request under the key is refused.
    let dm_infra = dm_with(&mut home, "agent_infra", "Infra Chief");
    let first = ok(&v2(
        &mut home,
        "chief.profile.adopt",
        json!({"participant_id": "agent_infra", "display_name": "Infra"}),
        Some("adopt-infra"),
    ));
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"]["display_name"], "Infra");
    let again = ok(&v2(
        &mut home,
        "chief.profile.adopt",
        json!({"participant_id": "agent_infra", "display_name": "Infra"}),
        Some("adopt-infra"),
    ));
    assert_eq!(again["replayed"], true);
    // The replay is the same record; only the first answer says what
    // happened to the brain (a replay starts nothing).
    let mut committed = first["value"].clone();
    assert_eq!(
        committed.as_object_mut().unwrap().remove("brain"),
        Some(json!({"state": "not_started", "reason": "no_supervisor"}))
    );
    assert_eq!(again["value"], committed);
    let clash = v2(
        &mut home,
        "chief.profile.adopt",
        json!({"participant_id": "agent_infra", "display_name": "Other"}),
        Some("adopt-infra"),
    );
    assert_eq!(reason(&clash), "idempotency.conflict");
    let _ = dm_infra;

    // Typed refusals.
    let refusal = |home: &mut Conn, participant: &str, key: &str| {
        reason(&v2(home, "chief.profile.adopt", json!({"participant_id": participant}), Some(key)))
    };
    let _ = dm_with(&mut home, "agent_mux", "mux");
    assert_eq!(refusal(&mut home, "agent_mux", "r-default"), "default_chief");
    assert_eq!(refusal(&mut home, "user_local", "r-person"), "not_an_agent_participant");
    assert_eq!(refusal(&mut home, "agent_nobody", "r-unknown"), "not_an_agent_participant");
    assert_eq!(refusal(&mut home, "agent_release", "r-live"), "already_chief");
    // Another agent whose brain directory (the last 8 characters) is agent_release's.
    let _ = dm_with(&mut home, "agent_x_release", "Twin");
    assert_eq!(refusal(&mut home, "agent_x_release", "r-twin"), "brain_home_taken");

    // A deleted Chief that was in a conversation: its id is never revived.
    let made =
        ok(&v2(&mut home, "chief.profile.create", json!({"display_name": "Gone"}), Some("mk")));
    let gone = made["value"]["id"].as_str().unwrap().to_owned();
    let _ = dm_with(&mut home, &gone, "Gone");
    ok(&v2(&mut home, "chief.profile.delete", json!({"chief": gone}), Some("rm")));
    assert_eq!(refusal(&mut home, &gone, "r-deleted"), "deleted_chief");

    // The CLI refuses a Chief's own turn (its owner socket marker) before it
    // connects; nothing is written. A person-authorized agent session
    // (ACPMUX_SESSION_ID alone) may manage Chiefs since #24634.
    let dm_design = dm_with(&mut home, "agent_design", "Design Chief");
    let output = chief_cli_as(
        &server,
        &["adopt", "agent_design", "--json"],
        "",
        &[("CMUX_CHIEF_OWNER_SOCKET", "/tmp/chief-owner.sock")],
    );
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    let error = json_error(&output);
    assert_eq!(error["code"], "origin.forbidden", "{error}");
    assert_eq!(error["details"]["reason"], "agent_caller", "{error}");
    assert_eq!(error["details"]["marker"], "CMUX_CHIEF_OWNER_SOCKET", "{error}");
    let listed = ok(&v2(&mut home, "chief.profile.list", json!({}), None));
    assert!(
        !listed["chiefs"].as_array().unwrap().iter().any(|c| c["id"] == "agent_design"),
        "{listed}"
    );
    let _ = dm_design;
}

#[test]
fn an_adopt_counts_toward_the_chief_limit() {
    let server = HeadlessServer::start("chief-adopt-limit");
    let mut home = Conn::open(&server.socket);
    let _ = dm_with(&mut home, "agent_release", "Release Chief");
    // The default Chief and 63 more: 64 live Chiefs, the limit.
    for n in 0..63 {
        ok(&v2(
            &mut home,
            "chief.profile.create",
            json!({"display_name": format!("Chief {n}")}),
            Some(&format!("fill-{n}")),
        ));
    }
    let refused = v2(
        &mut home,
        "chief.profile.adopt",
        json!({"participant_id": "agent_release"}),
        Some("adopt-full"),
    );
    assert_eq!(reason(&refused), "too_many_chiefs");
}

const BRAIN_STUB: &str = r#"#!/bin/sh
n=$(cat "$MUX_HOME/starts" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$MUX_HOME/starts"
exec sleep 600
"#;

/// An adopt is a committed Chief write like a create: the brain supervisor
/// starts the adopted Chief's brain.
#[test]
fn an_adopted_chief_reaches_the_brain_supervisor_like_a_create() {
    use std::os::unix::fs::PermissionsExt;
    let files = unique_temp_dir("adopt-b");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, BRAIN_STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("chief-home");
    fs::create_dir_all(&chief_home).unwrap();
    let brains = json!({"executable": stub, "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/opt/cmux-test/bin/acpmux"}})
    .to_string();
    let mut server = HeadlessServer::start_with_options(
        "chief-adopt-brains",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let mut home = Conn::open(&server.socket);
    let _ = dm_with(&mut home, "agent_release", "Release Chief");
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_release"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut session = Conn::open(&server.socket);
    session.request("conversation-bind", json!({"participant": "agent_release", "token": token}));
    let bound = v2(
        &mut home,
        "chief.profile.adopt",
        json!({"participant_id": "agent_release"}),
        Some("a0"),
    );
    assert_eq!(reason(&bound), "participant_bound");
    drop(session);
    ok(&adopt_once_unbound(&mut home, json!({"participant_id": "agent_release"}), "adopt-release"));
    // With a brain supervisor, only the brain holds the Chief's credential.
    let mint =
        try_request(&mut home, "conversation-agent-token", json!({"participant": "agent_release"}));
    assert_eq!(mint["ok"], false, "the person minted a supervised Chief's credential: {mint}");
    let id = "agent_release";
    let brain = chief_home.join("c").join(id[id.len() - 8..].to_ascii_lowercase());
    let starts = brain.join("starts");
    let deadline = Instant::now() + Duration::from_secs(20);
    while !starts.exists() {
        assert!(Instant::now() < deadline, "the adopted Chief's brain never started");
        std::thread::sleep(Duration::from_millis(25));
    }
    // The brain's credential (minted by the supervisor) binds; the old one does not.
    let brain_token = fs::read_to_string(brain.join("agent-token")).unwrap();
    let mut chief = Conn::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": id, "token": brain_token.trim()}));
    let mut old = Conn::open(&server.socket);
    let refused =
        try_request(&mut old, "conversation-bind", json!({"participant": id, "token": token}));
    assert_eq!(refused["ok"], false, "{refused}");
    let daemon = i32::try_from(server.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = server.child.wait();
    let _ = fs::remove_dir_all(&files);
}
