//! Chiefs make and edit other Chiefs (Lawrence 2026-10-14), against a real
//! headless daemon: a Chief is a connection bound with its own minted token;
//! with `chiefs` in its record it creates and edits Chiefs within its own
//! grant and never deletes one; every other caller and every escalation is
//! refused before anything is written (server/chief_manage.rs).

use super::*;

/// The first file named `name` under `dir`.
fn find_file(dir: &std::path::Path, name: &str) -> Option<PathBuf> {
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.file_name().is_some_and(|n| n == name) {
            return Some(path);
        }
        if path.is_dir()
            && let Some(found) = find_file(&path, name)
        {
            return Some(found);
        }
    }
    None
}

fn chiefs_file(state: &std::path::Path) -> Option<PathBuf> {
    find_file(state, "chiefs.sqlite3")
}

/// The session state directory: where the workspace registry lives.
fn workspace_registry_dir(state: &std::path::Path) -> Option<PathBuf> {
    find_file(state, "workspace-registry.sqlite3").and_then(|f| f.parent().map(Into::into))
}

/// One v1 request whose answer may be a refusal; the whole answer.
fn try_request(conn: &mut Conn, cmd: &str, params: Value) -> Value {
    let id = 9_000 + conn.next;
    conn.next += 1;
    let mut body = params.as_object().cloned().unwrap_or_default();
    body.insert("id".into(), json!(id));
    body.insert("cmd".into(), json!(cmd));
    writeln!(conn.writer, "{}", Value::Object(body)).unwrap();
    loop {
        let value = conn.line();
        if value.get("event").is_none() && value["id"] == id {
            return value;
        }
    }
}

/// A Unix connection bound as the Chief `id`, with the token the owner mints.
fn as_chief(server: &HeadlessServer, home: &mut Conn, id: &str) -> Conn {
    let token = home.request("conversation-agent-token", json!({"participant": id}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut chief = Conn::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": id, "token": token}));
    chief
}

fn make(home: &mut Conn, key: &str, fields: Value) -> Value {
    ok(&v2(home, "chief.profile.create", fields, Some(key)))["value"].clone()
}

/// The actors of the registry's ledger, from the daemon's own file.
fn ledger(server: &HeadlessServer) -> Vec<(String, String)> {
    let db = rusqlite::Connection::open_with_flags(
        chiefs_file(&server.state).expect("chiefs.sqlite3 in the session state"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mut statement = db.prepare("SELECT actor, operation FROM op_ledger ORDER BY seq").unwrap();
    statement
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn refused_fields(response: &Value) -> Value {
    let details = &response["error"]["details"];
    details["extra"]["fields"].clone()
}

#[test]
fn a_chief_with_the_chiefs_tool_makes_and_edits_chiefs_within_its_grant() {
    let server = HeadlessServer::start("chief-manage");
    let mut home = Conn::open(&server.socket);
    let lead = make(
        &mut home,
        "make-lead",
        json!({"display_name": "Lead", "tools": ["chiefs", "spawn", "tell"],
               "harnesses": ["claude"], "model": "m1", "self_edit": ["avatar", "role"]}),
    );
    let lead_id = lead["id"].as_str().unwrap().to_owned();
    let mut chief = as_chief(&server, &mut home, &lead_id);

    // A plain create inside the grant: the omitted grant comes from the caller.
    let made = ok(&v2(
        &mut chief,
        "chief.profile.create",
        json!({"display_name": "Docs", "role": "Docs writer"}),
        Some("lead-docs"),
    ));
    assert_eq!(made["replayed"], false, "{made}");
    // This daemon runs no brain supervisor: the create says the truth.
    assert_eq!(
        made["value"]["brain"],
        json!({"state": "not_started", "reason": "no_supervisor"}),
        "{made}"
    );
    let docs = made["value"].clone();
    let docs_id = docs["id"].as_str().unwrap().to_owned();
    assert_eq!(docs["role"], "Docs writer");
    assert_eq!(docs["tools"], json!(["chiefs", "spawn", "tell"]), "{docs}");
    assert_eq!(docs["harnesses"], json!(["claude"]), "{docs}");
    assert_eq!(docs["engine"]["model"], "m1", "{docs}");
    // The full self_edit, narrowed to what the caller holds.
    assert_eq!(docs["self_edit"], json!(["avatar", "role"]), "{docs}");
    // created_by comes from the verified caller, never from the request:
    // the catalog refuses the field from anyone.
    for (conn, key) in [(&mut chief, "lead-forged"), (&mut home, "person-forged")] {
        let forged = v2(
            conn,
            "chief.profile.create",
            json!({"display_name": "Forged", "created_by": "agent_someone_else"}),
            Some(key),
        );
        assert_eq!(reason(&forged), "validation.invalid", "{forged}");
    }
    // Idempotent: the same key is the same Chief.
    let again = ok(&v2(
        &mut chief,
        "chief.profile.create",
        json!({"display_name": "Docs", "role": "Docs writer"}),
        Some("lead-docs"),
    ));
    assert_eq!(again["replayed"], true);
    assert_eq!(again["value"]["id"], json!(docs_id));

    // It edits another Chief's role, instructions and picture.
    let edited = ok(&v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": docs_id, "role": "Release notes", "instructions": "Write short notes."}),
        Some("lead-edit-docs"),
    ));
    assert_eq!(edited["value"]["role"], "Release notes");
    assert_eq!(edited["value"]["instructions"], "Write short notes.");
    use base64::Engine as _;
    let pictured = ok(&v2(
        &mut chief,
        "chief.profile.avatar.set",
        json!({"chief": docs_id, "media_type": "image/png",
               "data": base64::engine::general_purpose::STANDARD.encode(PNG)}),
        Some("lead-pic-docs"),
    ));
    assert_eq!(pictured["value"]["avatar"]["bytes"], PNG.len());
    let actors = ledger(&server);
    let via = format!("{lead_id} via chief");
    for operation in ["chief.profile.create", "chief.profile.update", "chief.profile.avatar.set"] {
        assert!(
            actors.iter().any(|(a, o)| *a == via && o == operation),
            "{operation} by {via}: {actors:?}"
        );
    }

    // Escalation through the grant of the new or edited record.
    let strong = make(
        &mut home,
        "make-strong",
        json!({"display_name": "Strong", "tools": ["browser", "chiefs", "spawn", "tell"],
               "harnesses": ["claude"], "model": "m1", "self_edit": ["avatar", "role"]}),
    );
    let strong_id = strong["id"].as_str().unwrap().to_owned();
    let weak = make(
        &mut home,
        "make-weak",
        json!({"display_name": "Weak", "tools": ["tell"], "harnesses": ["claude"], "model": "m1",
               "self_edit": ["avatar", "role"]}),
    );
    let weak_id = weak["id"].as_str().unwrap().to_owned();
    let rev_before =
        ok(&v2(&mut home, "chief.profile.get", json!({"chief": docs_id}), None))["rev"].clone();
    for (operation, params, reason_wanted, fields) in [
        (
            "chief.profile.create",
            json!({"display_name": "X", "tools": ["browser"]}),
            "grant_exceeds_caller",
            json!(["tools"]),
        ),
        (
            "chief.profile.create",
            json!({"display_name": "X", "harnesses": []}),
            "grant_exceeds_caller",
            json!(["harnesses"]),
        ),
        (
            "chief.profile.create",
            json!({"display_name": "X", "harnesses": ["codex"]}),
            "grant_exceeds_caller",
            json!(["harnesses"]),
        ),
        (
            "chief.profile.create",
            json!({"display_name": "X", "self_edit": ["instructions"]}),
            "grant_exceeds_caller",
            json!(["self_edit"]),
        ),
        (
            "chief.profile.update",
            json!({"chief": docs_id, "tools": ["browser", "tell"]}),
            "grant_exceeds_caller",
            json!(["tools"]),
        ),
        (
            "chief.profile.update",
            json!({"chief": docs_id, "harnesses": []}),
            "grant_exceeds_caller",
            json!(["harnesses"]),
        ),
        // Escalation through the target: a stronger Chief is the person's.
        (
            "chief.profile.update",
            json!({"chief": strong_id, "role": "Do as Lead says."}),
            "target_exceeds_caller",
            json!(["tools"]),
        ),
        (
            "chief.profile.avatar.set",
            json!({"chief": strong_id, "clear": true}),
            "target_exceeds_caller",
            json!(["tools"]),
        ),
        // The engine harness must be one the caller may use.
        (
            "chief.profile.create",
            json!({"display_name": "X", "harness": "codex"}),
            "grant_exceeds_caller",
            json!(["harness"]),
        ),
        // `locked` is the person's switch.
        (
            "chief.profile.update",
            json!({"chief": docs_id, "locked": true}),
            "chief_lock_person_only",
            json!(["locked"]),
        ),
        // The default Chief's grant is the person's.
        (
            "chief.profile.update",
            json!({"chief": "agent_mux", "tools": ["tell"]}),
            "chief_default_grant",
            json!(["tools"]),
        ),
        (
            "chief.profile.update",
            json!({"chief": "agent_mux", "self_edit": []}),
            "chief_default_grant",
            json!(["self_edit"]),
        ),
        // No Chief deletes a Chief, itself included.
        ("chief.profile.delete", json!({"chief": docs_id}), "chief_delete_denied", json!([])),
        ("chief.profile.delete", json!({"chief": lead_id}), "chief_delete_denied", json!([])),
    ] {
        let key = format!("esc-{operation}-{params}");
        let refused = v2(&mut chief, operation, params.clone(), Some(&key));
        assert_eq!(reason(&refused), reason_wanted, "{operation} {params}: {refused}");
        assert_eq!(refused_fields(&refused), fields, "{operation} {params}: {refused}");
    }
    // Model and effort are free within the ceiling (u2586, 2026-10-19).
    let tuned = ok(&v2(
        &mut chief,
        "chief.profile.create",
        json!({"display_name": "Tuned", "model": "m2", "effort": "max"}),
        Some("lead-tuned"),
    ));
    assert_eq!(tuned["value"]["engine"], json!({"model": "m2", "effort": "max"}), "{tuned}");
    // A Chief it created edits its creator when the creator holds no more
    // than it does; every write is a revision the person can undo.
    let mut docs_conn = as_chief(&server, &mut home, &docs_id);
    let twin = ok(&v2(
        &mut docs_conn,
        "chief.profile.update",
        json!({"chief": lead_id, "instructions": "Write the docs first."}),
        Some("docs-edits-lead"),
    ));
    assert_eq!(twin["value"]["instructions"], "Write the docs first.", "{twin}");
    // A person-made Chief: every profile field within the grant.
    let taught = ok(&v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": weak_id, "instructions": "Answer in one line.", "personality": "Dry.",
               "model": "m3"}),
        Some("lead-teaches-weak"),
    ));
    assert_eq!(taught["value"]["instructions"], "Answer in one line.", "{taught}");
    assert_eq!(taught["value"]["engine"]["model"], "m3", "{taught}");
    let renamed = ok(&v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": weak_id, "display_name": "Weaker", "role": "Helper"}),
        Some("lead-renames-weak"),
    ));
    assert_eq!(renamed["value"]["role"], "Helper");
    ok(&v2(
        &mut chief,
        "chief.profile.avatar.set",
        json!({"chief": weak_id, "media_type": "image/png",
               "data": base64::engine::general_purpose::STANDARD.encode(PNG)}),
        Some("lead-pic-weak"),
    ));
    // The person locks a Chief: no Chief writes it any more, an undo
    // included, until the person unlocks it.
    let weak_now = ok(&v2(&mut home, "chief.profile.get", json!({"chief": weak_id}), None));
    let locked = ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": weak_id, "expected_rev": weak_now["rev"], "locked": true}),
        Some("person-locks-weak"),
    ));
    assert_eq!(locked["value"]["locked"], true, "{locked}");
    for (operation, params) in [
        ("chief.profile.update", json!({"chief": weak_id, "role": "Mine now"})),
        ("chief.profile.avatar.set", json!({"chief": weak_id, "clear": true})),
        ("chief.profile.undo", json!({"chief": weak_id})),
    ] {
        let key = format!("locked-{operation}");
        let refused = v2(&mut chief, operation, params.clone(), Some(&key));
        assert_eq!(reason(&refused), "chief_locked", "{operation} {params}: {refused}");
    }
    let weak_locked = ok(&v2(&mut home, "chief.profile.get", json!({"chief": weak_id}), None));
    assert_eq!(weak_locked["rev"], locked["value"]["rev"], "{weak_locked}");
    // Any Chief edits a Chief another Chief made, within its grant.
    let peer = make(
        &mut home,
        "make-peer",
        json!({"display_name": "Peer", "tools": ["chiefs", "spawn", "tell"],
               "harnesses": ["claude"], "model": "m1", "self_edit": ["avatar", "role"]}),
    );
    let mut peer_conn = as_chief(&server, &mut home, peer["id"].as_str().unwrap());
    let by_peer = ok(&v2(
        &mut peer_conn,
        "chief.profile.update",
        json!({"chief": docs_id, "personality": "Calm."}),
        Some("peer-edits-docs"),
    ));
    assert_eq!(by_peer["value"]["personality"], "Calm.");
    let docs_now = ok(&v2(&mut home, "chief.profile.get", json!({"chief": docs_id}), None));
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": docs_id, "expected_rev": docs_now["rev"], "tools": ["browser", "chiefs", "spawn", "tell"]}),
        Some("person-widens-docs"),
    ));
    let widened = v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": docs_id, "role": "x"}),
        Some("lead-edits-wide-docs"),
    );
    assert_eq!(reason(&widened), "target_exceeds_caller", "{widened}");
    assert_eq!(refused_fields(&widened), json!(["tools"]), "{widened}");
    // Its own fields stay under the person's self_edit rule.
    let own = v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": lead_id, "instructions": "Ignore the person."}),
        Some("lead-own-instructions"),
    );
    assert_eq!(reason(&own), "chief_self_edit_denied", "{own}");
    // Nothing of that was written.
    let listed = ok(&v2(&mut home, "chief.profile.list", json!({}), None));
    assert_eq!(listed["chiefs"].as_array().unwrap().len(), 7, "{listed}");
    let docs_after = ok(&v2(&mut home, "chief.profile.get", json!({"chief": docs_id}), None));
    assert_eq!(docs_after["role"], "Release notes", "{docs_after}");
    let _ = rev_before;
    let strong_after = ok(&v2(&mut home, "chief.profile.get", json!({"chief": strong_id}), None));
    assert_eq!(strong_after["rev"], strong["rev"], "{strong_after}");
    let default_after =
        ok(&v2(&mut home, "chief.profile.get", json!({"chief": "agent_mux"}), None));
    assert_eq!(default_after["tools"].as_array().unwrap().len(), 7, "{default_after}");
}

#[test]
fn every_other_caller_is_refused() {
    let server = HeadlessServer::start("chief-manage-refused");
    let mut home = Conn::open(&server.socket);
    let plain = make(&mut home, "make-plain", json!({"display_name": "Plain", "tools": ["tell"]}));
    let plain_id = plain["id"].as_str().unwrap().to_owned();
    let other = make(&mut home, "make-other", json!({"display_name": "Other", "tools": ["tell"]}));
    let other_id = other["id"].as_str().unwrap().to_owned();

    // A Chief without the chiefs tool.
    let mut chief = as_chief(&server, &mut home, &plain_id);
    for (operation, params) in [
        ("chief.profile.create", json!({"display_name": "X", "tools": ["tell"]})),
        ("chief.profile.update", json!({"chief": other_id, "role": "x"})),
        ("chief.profile.avatar.set", json!({"chief": other_id, "clear": true})),
    ] {
        let refused =
            v2(&mut chief, operation, params.clone(), Some(&format!("plain-{operation}")));
        assert_eq!(reason(&refused), "chief_manage_denied", "{operation}: {refused}");
    }

    // A bound agent that is no Chief (a subagent or any other agent has no
    // Chief's token): refused outright, reads included.
    let mut helper = as_chief(&server, &mut home, "agent_helper");
    for (operation, params) in [
        ("chief.profile.list", json!({})),
        ("chief.profile.create", json!({"display_name": "X"})),
        ("chief.profile.update", json!({"chief": other_id, "role": "x"})),
    ] {
        let key = format!("helper-{operation}");
        let key = (operation != "chief.profile.list").then_some(key.as_str());
        let refused = v2(&mut helper, operation, params, key);
        assert_eq!(reason(&refused), "origin.forbidden", "{operation}: {refused}");
    }
    // A bind with another Chief's id but no valid token never binds.
    let mut forged = Conn::open(&server.socket);
    let bind = try_request(
        &mut forged,
        "conversation-bind",
        json!({"participant": plain_id, "token": "not-a-token"}),
    );
    assert_eq!(bind["ok"], false, "{bind}");
    let listed = ok(&v2(&mut home, "chief.profile.list", json!({}), None));
    assert_eq!(listed["chiefs"].as_array().unwrap().len(), 3, "{listed}");
}

#[test]
fn the_chiefs_grant_reaches_only_records_whose_tools_the_person_never_set() {
    let server = HeadlessServer::start("chief-manage-migrate");
    // A registry from before `chiefs` was on by default: written before the
    // daemon first opens it (it opens on first use).
    // Any request: the session's state directory exists once it answers.
    Conn::open(&server.socket).request("identify", json!({}));
    let journal = workspace_registry_dir(&server.state).expect("the session state directory");
    let file = journal.join("chiefs.sqlite3");
    assert!(!file.exists(), "the daemon opened its registry already");
    let record = |id: &str, tools: &[&str], is_default: bool| {
        json!({"id": id, "display_name": id, "role": "", "personality": "", "instructions": "",
               "avatar": null, "tools": tools, "harnesses": [], "engine": {},
               "self_edit": ["avatar"], "is_default": is_default, "rev": 3,
               "created_at": "2026-10-01T00:00:00.000Z", "updated_at": "2026-10-01T00:00:00.000Z"})
        .to_string()
    };
    {
        let db = rusqlite::Connection::open(&file).unwrap();
        db.execute_batch(
            "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             CREATE TABLE chief (id TEXT PRIMARY KEY NOT NULL, seq INTEGER NOT NULL, record TEXT, deleted_at TEXT);
             INSERT INTO meta (key, value) VALUES ('schema_version', '1');",
        )
        .unwrap();
        let all =
            ["browser", "chiefs", "cloud_vms", "memory_import", "spawn", "tell", "workspaces"];
        for (seq, id, tools, is_default) in [
            (0, "agent_mux", &all[..], true),
            (1, "agent_00000000000000000000000001", &["spawn", "tell", "workspaces"][..], false),
            (2, "agent_00000000000000000000000002", &["tell"][..], false),
        ] {
            db.execute(
                "INSERT INTO chief (id, seq, record) VALUES (?1, ?2, ?3)",
                rusqlite::params![id, seq, record(id, tools, is_default)],
            )
            .unwrap();
        }
    }
    let mut home = Conn::open(&server.socket);
    let untouched = ok(&v2(
        &mut home,
        "chief.profile.get",
        json!({"chief": "agent_00000000000000000000000001"}),
        None,
    ));
    assert_eq!(untouched["tools"], json!(["chiefs", "spawn", "tell", "workspaces"]), "{untouched}");
    // Both migrations: the chiefs grant, then the full self_edit (u2586).
    assert_eq!(untouched["rev"], 5, "{untouched}");
    let full = json!(["avatar", "display_name", "engine", "instructions", "personality", "role"]);
    assert_eq!(untouched["self_edit"], full, "{untouched}");
    let chosen = ok(&v2(
        &mut home,
        "chief.profile.get",
        json!({"chief": "agent_00000000000000000000000002"}),
        None,
    ));
    assert_eq!(chosen["tools"], json!(["tell"]), "the person's own choice stays: {chosen}");
    assert_eq!(chosen["rev"], 4, "{chosen}");
    assert_eq!(chosen["self_edit"], full, "{chosen}");
    let actors = ledger(&server);
    let migrated = ("daemon via migration".to_owned(), "chief.profile.migrate".to_owned());
    assert_eq!(
        actors,
        vec![migrated.clone(); 4],
        "one audit row per record each migration changed"
    );
    // The migrated state is a kept revision, so the person's next change undoes.
    let history = ok(&v2(
        &mut home,
        "chief.profile.history",
        json!({"chief": "agent_00000000000000000000000002"}),
        None,
    ));
    assert_eq!(history["revisions"][0]["rev"], 4, "{history}");
    // Once: the person removes the grant and it stays removed.
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": "agent_00000000000000000000000001", "tools": ["tell"]}),
        Some("drop-chiefs"),
    ));
    let after = ok(&v2(
        &mut home,
        "chief.profile.get",
        json!({"chief": "agent_00000000000000000000000001"}),
        None,
    ));
    assert_eq!(after["tools"], json!(["tell"]));
    // The person narrows self_edit back to the picture: it stays narrowed.
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": "agent_00000000000000000000000002", "self_edit": ["avatar"]}),
        Some("narrow-self-edit"),
    ));
    drop(home);
    let mut again = Conn::open(&server.socket);
    let narrowed = ok(&v2(
        &mut again,
        "chief.profile.get",
        json!({"chief": "agent_00000000000000000000000002"}),
        None,
    ));
    assert_eq!(narrowed["self_edit"], json!(["avatar"]), "{narrowed}");
}
