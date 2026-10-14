//! The Chief registry against a real headless daemon (cx-ebm.60.1, .2): the
//! person makes, edits and deletes Chiefs with `cmux chief new|list|edit|
//! delete`; a Chief, on its own bound connection, changes its own picture and
//! only the fields the person allowed; other agents are refused.

use super::*;
use serde_json::{Value, json};

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
    assert_eq!(made["value"]["self_edit"], json!(["avatar"]), "the default self_edit");

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

    // Everything outside self_edit is the person's.
    for (operation, params) in [
        ("chief.profile.update", json!({"chief": scout, "display_name": "Boss"})),
        ("chief.profile.update", json!({"chief": scout, "tools": ["browser", "cloud_vms"]})),
        ("chief.profile.update", json!({"chief": scout, "self_edit": ["avatar", "instructions"]})),
        ("chief.profile.update", json!({"chief": scout, "harness": "codex"})),
        ("chief.profile.update", json!({"chief": "agent_mux", "role": "x"})),
        ("chief.profile.avatar.set", json!({"chief": "agent_mux", "clear": true})),
        ("chief.profile.delete", json!({"chief": scout})),
        ("chief.profile.create", json!({"display_name": "Stronger", "tools": ["browser"]})),
    ] {
        let key = format!("deny-{operation}-{params}");
        let refused = v2(&mut chief, operation, params.clone(), Some(&key));
        assert_eq!(reason(&refused), "chief_self_edit_denied", "{operation} {params}: {refused}");
    }
    let unchanged = ok(&v2(&mut home, "chief.profile.get", json!({"chief": scout}), None));
    assert_eq!(unchanged["display_name"], "Scout");
    assert_eq!(unchanged["tools"], json!(["spawn", "tell", "workspaces"]));
    assert_eq!(unchanged["self_edit"], json!(["avatar"]));

    // The person allows the role; then the Chief may change it.
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
