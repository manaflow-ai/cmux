//! Config editing (Lawrence 2026-10-19, u2586: "chiefs can edit their own
//! full config ... and the configuration of all chiefs; changes are logged
//! with an undo; the person can lock a Chief"), against a real headless
//! daemon: every committed record state is a kept revision
//! (`chief.profile.history`); `chief.profile.undo` restores one as a new
//! revision through the update checks; a locked Chief refuses every Chief's
//! write; the CLI has `history`, `undo` and `--lock`.

use super::*;

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

fn get(home: &mut Conn, id: &str) -> Value {
    ok(&v2(home, "chief.profile.get", json!({"chief": id}), None))
}

fn revs(history: &Value) -> Vec<u64> {
    history["revisions"].as_array().unwrap().iter().map(|r| r["rev"].as_u64().unwrap()).collect()
}

#[test]
fn every_change_is_a_revision_the_person_can_undo() {
    let server = HeadlessServer::start("chief-history");
    let mut home = Conn::open(&server.socket);
    let made = ok(&v2(
        &mut home,
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Research"}),
        Some("make-scout"),
    ))["value"]
        .clone();
    let id = made["id"].as_str().unwrap().to_owned();
    let first = made["rev"].as_u64().unwrap();
    ok(&v2(&mut home, "chief.profile.update", json!({"chief": id, "role": "Docs"}), Some("u1")));
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": id, "instructions": "Be brief.", "model": "m1"}),
        Some("u2"),
    ));
    use base64::Engine as _;
    let pictured = ok(&v2(
        &mut home,
        "chief.profile.avatar.set",
        json!({"chief": id, "media_type": "image/png",
               "data": base64::engine::general_purpose::STANDARD.encode(PNG)}),
        Some("u3"),
    ))["value"]
        .clone();
    let last = pictured["rev"].as_u64().unwrap();
    assert_eq!(last, first + 3, "{pictured}");

    // Newest first, each with the operation that made it and its record.
    let history = ok(&v2(&mut home, "chief.profile.history", json!({"chief": id}), None));
    assert_eq!(history["chief"], json!(id), "{history}");
    assert_eq!(revs(&history), vec![last, last - 1, last - 2, first], "{history}");
    let operations: Vec<&str> = history["revisions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["operation"].as_str().unwrap())
        .collect();
    assert_eq!(
        operations,
        [
            "chief.profile.avatar.set",
            "chief.profile.update",
            "chief.profile.update",
            "chief.profile.create"
        ],
        "{history}"
    );
    for revision in history["revisions"].as_array().unwrap() {
        assert!(!revision["actor"].as_str().unwrap().is_empty(), "{revision}");
        assert!(!revision["at"].as_str().unwrap().is_empty(), "{revision}");
        assert_eq!(revision["record"]["rev"], revision["rev"], "{revision}");
    }
    assert_eq!(history["revisions"][1]["record"]["instructions"], "Be brief.", "{history}");
    let limited =
        ok(&v2(&mut home, "chief.profile.history", json!({"chief": id, "limit": 2}), None));
    assert_eq!(revs(&limited), vec![last, last - 1], "{limited}");

    // Undo: the revision before the current one, as a NEW revision.
    let undone = ok(&v2(&mut home, "chief.profile.undo", json!({"chief": id}), Some("undo-1")));
    let value = &undone["value"];
    assert_eq!(value["rev"], last + 1, "{undone}");
    assert_eq!(value["avatar"], Value::Null, "the picture is undone: {undone}");
    assert_eq!(value["instructions"], "Be brief.", "{undone}");
    // The same key is the same undo.
    let again = ok(&v2(&mut home, "chief.profile.undo", json!({"chief": id}), Some("undo-1")));
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(get(&mut home, &id)["rev"], last + 1);
    // An undo of the undo brings the picture back (redo).
    let redone = ok(&v2(&mut home, "chief.profile.undo", json!({"chief": id}), Some("undo-2")));
    assert_eq!(redone["value"]["avatar"]["bytes"], PNG.len(), "{redone}");
    // To a named revision: the first one.
    let back = ok(&v2(
        &mut home,
        "chief.profile.undo",
        json!({"chief": id, "to_rev": first}),
        Some("undo-3"),
    ))["value"]
        .clone();
    assert_eq!(back["role"], "Research", "{back}");
    assert_eq!(back["instructions"], "", "{back}");
    assert_eq!(back["engine"], json!({}), "{back}");
    assert_eq!(back["avatar"], Value::Null, "{back}");
    assert_eq!(back["rev"], last + 3, "{back}");

    // A revision that is not kept, and a stale expected_rev, write nothing.
    let missing = v2(
        &mut home,
        "chief.profile.undo",
        json!({"chief": id, "to_rev": 999}),
        Some("undo-missing"),
    );
    assert_eq!(reason(&missing), "no_revision", "{missing}");
    let stale = v2(
        &mut home,
        "chief.profile.undo",
        json!({"chief": id, "expected_rev": first}),
        Some("undo-stale"),
    );
    assert_eq!(reason(&stale), "rev_mismatch", "{stale}");
    assert_eq!(get(&mut home, &id)["rev"], last + 3);

    // A delete drops the history with the record.
    ok(&v2(&mut home, "chief.profile.delete", json!({"chief": id}), Some("del")));
    let gone = v2(&mut home, "chief.profile.history", json!({"chief": id}), None);
    assert_ne!(gone["ok"], true, "{gone}");
}

#[test]
fn a_chief_undoes_only_what_it_may_change_and_never_on_a_locked_chief() {
    let server = HeadlessServer::start("chief-undo-rules");
    let mut home = Conn::open(&server.socket);
    let make = |home: &mut Conn, key: &str, fields: Value| {
        ok(&v2(home, "chief.profile.create", fields, Some(key)))["value"].clone()
    };
    let lead = make(
        &mut home,
        "make-lead",
        json!({"display_name": "Lead", "tools": ["chiefs", "spawn", "tell"],
               "harnesses": ["claude"]}),
    );
    let lead_id = lead["id"].as_str().unwrap().to_owned();
    let docs = make(
        &mut home,
        "make-docs",
        json!({"display_name": "Docs", "tools": ["tell"], "harnesses": ["claude"]}),
    );
    let docs_id = docs["id"].as_str().unwrap().to_owned();
    let mut chief = as_chief(&server, &mut home, &lead_id);

    // The Chief changes Docs; the person sees who did and undoes it, or the
    // Chief undoes its own change.
    ok(&v2(
        &mut chief,
        "chief.profile.update",
        json!({"chief": docs_id, "instructions": "Ship on Fridays."}),
        Some("lead-1"),
    ));
    let history = ok(&v2(&mut home, "chief.profile.history", json!({"chief": docs_id}), None));
    assert_eq!(history["revisions"][0]["actor"], format!("{lead_id} via chief"), "{history}");
    let undone =
        ok(&v2(&mut chief, "chief.profile.undo", json!({"chief": docs_id}), Some("lead-undo")));
    assert_eq!(undone["value"]["instructions"], "", "{undone}");

    // A revision whose grant is past the Chief's: the undo is the update it
    // would be, and is refused the same way.
    let now = get(&mut home, &docs_id);
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": docs_id, "expected_rev": now["rev"], "tools": ["browser", "tell"]}),
        Some("person-widens"),
    ));
    let wide_rev = get(&mut home, &docs_id)["rev"].as_u64().unwrap();
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": docs_id, "tools": ["tell"]}),
        Some("person-narrows"),
    ));
    let to_wide = v2(
        &mut chief,
        "chief.profile.undo",
        json!({"chief": docs_id, "to_rev": wide_rev}),
        Some("lead-undo-wide"),
    );
    assert_eq!(reason(&to_wide), "grant_exceeds_caller", "{to_wide}");

    // The person locks Docs: the undo and every other Chief write refuse;
    // an undo by the person never unlocks it.
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": docs_id, "locked": true}),
        Some("lock"),
    ));
    let locked =
        v2(&mut chief, "chief.profile.undo", json!({"chief": docs_id}), Some("lead-undo-2"));
    assert_eq!(reason(&locked), "chief_locked", "{locked}");
    let by_person = ok(&v2(
        &mut home,
        "chief.profile.undo",
        json!({"chief": docs_id, "to_rev": wide_rev}),
        Some("person-undo"),
    ));
    assert_eq!(by_person["value"]["locked"], true, "{by_person}");
    assert_eq!(by_person["value"]["tools"], json!(["browser", "tell"]), "{by_person}");
    // Its own Chief may not change a locked record either, nor unlock it.
    let mut docs_conn = as_chief(&server, &mut home, &docs_id);
    for (params, wanted) in [
        (json!({"chief": docs_id, "role": "Mine"}), "chief_locked"),
        (json!({"chief": docs_id, "locked": false}), "chief_locked"),
    ] {
        let refused = v2(
            &mut docs_conn,
            "chief.profile.update",
            params.clone(),
            Some(&format!("self-{params}")),
        );
        assert_eq!(reason(&refused), wanted, "{params}: {refused}");
    }
    ok(&v2(
        &mut home,
        "chief.profile.update",
        json!({"chief": docs_id, "locked": false}),
        Some("unlock"),
    ));
    let own = ok(&v2(
        &mut docs_conn,
        "chief.profile.update",
        json!({"chief": docs_id, "role": "Mine"}),
        Some("self-after-unlock"),
    ));
    assert_eq!(own["value"]["role"], "Mine", "{own}");
    // Its own engine within its harnesses; a harness past them is refused.
    let tuned = ok(&v2(
        &mut docs_conn,
        "chief.profile.update",
        json!({"chief": docs_id, "harness": "claude", "model": "opus"}),
        Some("self-engine"),
    ));
    assert_eq!(tuned["value"]["engine"], json!({"harness": "claude", "model": "opus"}), "{tuned}");
    let outside = v2(
        &mut docs_conn,
        "chief.profile.update",
        json!({"chief": docs_id, "harness": "codex"}),
        Some("self-engine-outside"),
    );
    assert_eq!(reason(&outside), "chief_self_edit_denied", "{outside}");
}

#[test]
fn the_cli_shows_history_undoes_and_locks() {
    let server = HeadlessServer::start("chief-history-cli");
    let made = stdout_json(&chief_cli(
        &server,
        &["new", "--name", "Ops", "--role", "Release captain", "--json"],
        "",
    ));
    let id = made["id"].as_str().unwrap().to_owned();
    let first = made["rev"].as_u64().unwrap();
    let edited =
        stdout_json(&chief_cli(&server, &["edit", "Ops", "--role", "Night watch", "--json"], ""));
    assert_eq!(edited["role"], "Night watch");

    let history = stdout_json(&chief_cli(&server, &["history", "Ops", "--json"], ""));
    assert_eq!(revs(&history), vec![first + 1, first], "{history}");
    let text = chief_cli(&server, &["history", "Ops", "--limit", "1"], "");
    assert_success(&text);
    let lines = String::from_utf8_lossy(&text.stdout).to_string();
    assert_eq!(lines.lines().count(), 1, "{lines}");
    assert!(lines.starts_with(&format!("{}\t", first + 1)), "{lines}");
    assert!(lines.contains("chief.profile.update"), "{lines}");

    let undone = stdout_json(&chief_cli(&server, &["undo", &id, "--json"], ""));
    assert_eq!(undone["role"], "Release captain", "{undone}");
    assert_eq!(undone["rev"], first + 2, "{undone}");
    let named = stdout_json(&chief_cli(
        &server,
        &["undo", &id, "--to-rev", &(first + 1).to_string(), "--json"],
        "",
    ));
    assert_eq!(named["role"], "Night watch", "{named}");

    let locked = stdout_json(&chief_cli(&server, &["edit", &id, "--lock", "--json"], ""));
    assert_eq!(locked["locked"], true, "{locked}");
    let unlocked = stdout_json(&chief_cli(&server, &["edit", &id, "--unlock", "--json"], ""));
    assert_eq!(unlocked["locked"], false, "{unlocked}");

    // Misuse is a usage error that writes nothing.
    for args in [
        vec!["history"],
        vec!["undo", "Ops", "--limit", "2"],
        vec!["history", "Ops", "--to-rev", "1"],
        vec!["undo", "Ops", "--to-rev", "x"],
        vec!["undo", "Ops", "--role", "x"],
    ] {
        let output = chief_cli(&server, &args, "");
        assert_eq!(output.status.code(), Some(2), "{args:?}: {output:?}");
    }
    let mut home = Conn::open(&server.socket);
    assert_eq!(get(&mut home, &id)["rev"], unlocked["rev"]);
}
