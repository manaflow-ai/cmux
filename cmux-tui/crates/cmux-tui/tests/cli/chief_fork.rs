//! `chief.profile.create` with `fork` against a real headless daemon and a
//! stub brain: the person forks a Chief at one of its messages, a Chief forks
//! itself now, and every way a fork must be refused. The stub stands in for
//! `optchat-chief`: as a brain it records whether its memory was in place
//! when it started; as `memory fork` it records its argv, writes the new
//! memory file and answers what the real one answers (`--json`).

use super::*;
use serde_json::{Value, json};

const STUB: &str = r#"#!/bin/sh
if [ "$1" = memory ] && [ "$2" = fork ]; then
  to=""; name=""
  prev=""
  for a in "$@"; do
    case "$prev" in --to-home) to="$a" ;; --name) name="$a" ;; esac
    prev="$a"
  done
  if [ -e "$(dirname "$(dirname "$to")")/fail-fork" ]; then echo "optchat-chief memory: memory fork: disk full" >&2; exit 1; fi
  echo copy >> "$(dirname "$(dirname "$to")")/copies"
  mkdir -p "$to/optchat"
  echo "$@" > "$to/fork-argv"
  echo forked > "$to/optchat/memory.sqlite3"
  echo '{"cut": 42, "source_messages": 50, "nodes": 7, "nodes_left_out": 3, "attachments": 0, "note": 42}'
  exit 0
fi
if [ "$1" = end-sessions ]; then exit 0; fi
if [ -e "$MUX_HOME/optchat/memory.sqlite3" ]; then cat "$MUX_HOME/optchat/memory.sqlite3" > "$MUX_HOME/memory-at-start"; else echo none > "$MUX_HOME/memory-at-start"; fi
exec sleep 600
"#;

/// One `cmux.protocol/2` request; the whole response. A mutation passes its key.
fn v2(conn: &mut Conn, operation: &str, params: Value, key: Option<&str>) -> Value {
    let id = format!("fork-{}", conn.next);
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

fn create(conn: &mut Conn, key: &str, fields: Value) -> Value {
    v2(conn, "chief.profile.create", fields, Some(key))
}

fn wait_file(path: &std::path::Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Ok(text) = fs::read_to_string(path)
            && !text.trim().is_empty()
        {
            return text.trim().to_owned();
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("{} never appeared", path.display());
}

fn brain_dir(home: &std::path::Path, chief: &str) -> PathBuf {
    home.join("c").join(chief[chief.len() - 8..].to_ascii_lowercase())
}

/// A refusal's reason (`operation.failed`'s details.reason, else the error
/// code) and its message.
fn refusal(answer: &Value) -> (String, String) {
    assert_eq!(answer["ok"], false, "{answer}");
    let error = &answer["error"];
    let code = error["code"].as_str().unwrap_or("");
    let reason = match error["details"]["reason"].as_str() {
        Some(reason) if code == "operation.failed" => reason,
        _ => code,
    };
    let message = error["details"]["extra"]["message"].as_str().unwrap_or("");
    (reason.to_owned(), message.to_owned())
}

fn chief_count(conn: &mut Conn) -> usize {
    let list = v2(conn, "chief.profile.list", json!({}), None);
    list["result"]["chiefs"].as_array().map_or(0, Vec::len)
}

#[test]
fn the_person_forks_a_chief_at_a_message_and_a_chief_forks_itself() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cf");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let brains = json!({"executable": stub, "home": chief_home}).to_string();
    let server = HeadlessServer::start_with_options(
        "chief-fork",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let mut home = Conn::open(&server.socket);

    // Scout, with a role, instructions and an engine; its brain has a memory.
    let made = create(
        &mut home,
        "make-scout",
        json!({"display_name": "Scout", "role": "Researcher", "instructions": "Cite sources.",
               "harness": "codex"}),
    );
    assert_eq!(made["ok"], true, "{made}");
    let scout = made["result"]["value"]["id"].as_str().unwrap().to_owned();
    let scout_home = brain_dir(&chief_home, &scout);
    wait_file(&scout_home.join("memory-at-start"));
    fs::create_dir_all(scout_home.join("optchat")).unwrap();
    fs::write(scout_home.join("optchat/memory.sqlite3"), "scout").unwrap();
    // The person's DM with Scout, and a message in it.
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": "dm-scout", "actor": "user_local", "title": "Scout",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": scout, "kind": "agent", "display_name": "Scout"}]}),
    );
    let dm = created["conversation"]["id"].as_str().unwrap().to_owned();
    home.request(
        "conversation-op",
        json!({"conversation": dm, "idempotency_key": "m1",
               "op": {"kind": "message.send", "client_msg_id": "m1",
                      "parts": [{"type": "text", "text": "look into X"}]}}),
    );
    let snapshot = home.request("conversation-snapshot", json!({"conversation": dm, "tail": 5}));
    let first =
        snapshot["messages"].as_array().unwrap().iter().find(|m| m["seq"] == 1).unwrap().clone();

    // The person forks Scout at message #1: the new Chief has Scout's
    // profile under its own name, says where it came from, and its brain
    // finds the forked memory at its first start.
    let before = chief_count(&mut home);
    let forked = create(
        &mut home,
        "fork-scout",
        json!({"display_name": "Scout fork", "fork": {"chief": scout, "conversation": dm, "seq": 1}}),
    );
    assert_eq!(forked["ok"], true, "{forked}");
    let record = &forked["result"]["value"];
    let fork_id = record["id"].as_str().unwrap().to_owned();
    assert_ne!(fork_id, scout);
    assert_eq!(record["display_name"], "Scout fork");
    assert_eq!(record["role"], "Researcher");
    assert_eq!(record["instructions"], "Cite sources.");
    assert_eq!(record["engine"]["harness"], "codex");
    let origin = &record["forked_from"];
    assert_eq!(origin["chief"], json!(scout), "{record}");
    assert_eq!(origin["name"], "Scout");
    assert_eq!(origin["conversation"], json!(dm));
    assert_eq!(origin["seq"], 1);
    assert_eq!(origin["cut"], 42);
    assert_eq!(origin["by"], "person");
    assert_eq!(record["brain"]["state"], "started", "{record}");
    let fork_home = brain_dir(&chief_home, &fork_id);
    assert_eq!(wait_file(&fork_home.join("memory-at-start")), "forked");
    let argv = fs::read_to_string(fork_home.join("fork-argv")).unwrap();
    for part in [
        format!("--mux-home {}", scout_home.display()),
        format!("--to-home {}", fork_home.display()),
        format!("--chief {scout}"),
        "--name Scout".to_owned(),
        "--by person".to_owned(),
        format!("--key {dm}#1"),
        format!("--at {}", first["created_at"].as_str().unwrap()),
    ] {
        assert!(argv.contains(&part), "{part} not in {argv}");
    }
    // The source is untouched, and the record keeps its origin.
    assert_eq!(fs::read_to_string(scout_home.join("optchat/memory.sqlite3")).unwrap(), "scout");
    let got = v2(&mut home, "chief.profile.get", json!({"chief": fork_id}), None);
    assert_eq!(got["result"]["forked_from"], *origin, "{got}");
    assert_eq!(chief_count(&mut home), before + 1);

    // A replay of the same create answers the same Chief and copies nothing.
    let dirs = || fs::read_dir(chief_home.join("c")).unwrap().count();
    let dirs_before = dirs();
    let copies =
        || fs::read_to_string(chief_home.join("copies")).unwrap_or_default().lines().count();
    let copies_before = copies();
    let again = create(
        &mut home,
        "fork-scout",
        json!({"display_name": "Scout fork", "fork": {"chief": scout, "conversation": dm, "seq": 1}}),
    );
    assert_eq!(again["result"]["value"]["id"], json!(fork_id), "{again}");
    assert_eq!(again["result"]["replayed"], true);
    assert_eq!(dirs(), dirs_before, "a replay left a copy");
    assert_eq!(copies(), copies_before, "a replay copied the memory again");

    // Ops: a Chief whose brain ran but has no memory yet.
    let ops = create(&mut home, "make-ops", json!({"display_name": "Ops"}));
    let ops = ops["result"]["value"]["id"].as_str().unwrap().to_owned();
    wait_file(&brain_dir(&chief_home, &ops).join("memory-at-start"));

    // Refusals: nothing is written and no copy is left.
    let count = chief_count(&mut home);
    let dirs_before = dirs();
    let cases = [
        (json!({"chief": scout, "conversation": dm, "seq": 9}), "fork_refused", "no message #9"),
        (json!({"chief": "agent_nobody"}), "fork_refused", "no Chief"),
        (json!({"chief": scout, "conversation": dm}), "validation.invalid", ""),
        (json!({"chief": ops}), "fork_refused", "no memory"),
    ];
    for (n, (fork, reason, says)) in cases.into_iter().enumerate() {
        let answer =
            create(&mut home, &format!("bad-{n}"), json!({"display_name": "X", "fork": fork}));
        assert_eq!(answer["ok"], false, "{answer}");
        let (got, message) = refusal(&answer);
        assert_eq!(got, reason, "{answer}");
        assert!(message.contains(says), "{says:?} not in {answer}");
    }
    // A conversation Scout is not in.
    let other = home.request(
        "conversation-create",
        json!({"idempotency_key": "dm-other", "actor": "user_local", "title": "Other",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "mux"}]}),
    );
    let other = other["conversation"]["id"].as_str().unwrap().to_owned();
    let answer = create(
        &mut home,
        "bad-other",
        json!({"display_name": "X", "fork": {"chief": scout, "conversation": other, "seq": 1}}),
    );
    let (reason, message) = refusal(&answer);
    assert_eq!(reason, "fork_refused", "{answer}");
    assert!(message.contains("does not take part"), "{answer}");
    // A copy that fails (the stub fails while the Chief home has a
    // fail-fork file): refused with the copy's reason, and nothing stays.
    fs::write(chief_home.join("fail-fork"), "").unwrap();
    let answer =
        create(&mut home, "bad-copy", json!({"display_name": "X", "fork": {"chief": scout}}));
    let (reason, message) = refusal(&answer);
    assert_eq!(reason, "fork_refused", "{answer}");
    assert!(message.contains("disk full"), "{answer}");
    fs::remove_file(chief_home.join("fail-fork")).unwrap();
    assert_eq!(chief_count(&mut home), count);
    assert_eq!(dirs(), dirs_before, "a refused fork left a copy");

    // A Chief forks itself (now), and only itself.
    let token = fs::read_to_string(scout_home.join("agent-token")).unwrap();
    let mut as_scout = Conn::open(&server.socket);
    as_scout.request("conversation-bind", json!({"participant": scout, "token": token}));
    let own = create(
        &mut as_scout,
        "self-fork",
        json!({"display_name": "Scout II", "fork": {"chief": scout}}),
    );
    assert_eq!(own["ok"], true, "{own}");
    let own_record = &own["result"]["value"];
    assert_eq!(own_record["forked_from"]["by"], json!(scout));
    assert!(own_record["forked_from"].get("conversation").is_none(), "{own_record}");
    let own_home = brain_dir(&chief_home, own_record["id"].as_str().unwrap());
    let argv = fs::read_to_string(own_home.join("fork-argv")).unwrap();
    assert!(!argv.contains("--key"), "{argv}");
    assert!(argv.contains(&format!("--by {scout}")), "{argv}");
    let theirs = create(
        &mut as_scout,
        "fork-other",
        json!({"display_name": "Y", "fork": {"chief": fork_id}}),
    );
    let (reason, message) = refusal(&theirs);
    assert_eq!(reason, "fork_refused", "{theirs}");
    assert!(message.contains("only itself"), "{theirs}");
}

#[test]
fn a_daemon_without_brains_refuses_a_fork_and_still_makes_blank_chiefs() {
    let server = HeadlessServer::start("chief-fork-nobrains");
    let mut home = Conn::open(&server.socket);
    let blank = create(&mut home, "blank", json!({"display_name": "Blank"}));
    assert_eq!(blank["ok"], true, "{blank}");
    assert!(blank["result"]["value"].get("forked_from").is_none(), "{blank}");
    let answer =
        create(&mut home, "fork", json!({"display_name": "F", "fork": {"chief": "agent_mux"}}));
    let (reason, message) = refusal(&answer);
    assert_eq!(reason, "fork_refused", "{answer}");
    assert!(message.contains("no Chief brains"), "{answer}");
}
