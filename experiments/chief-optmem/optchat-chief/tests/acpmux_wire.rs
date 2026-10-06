//! The real acpmux port against a fake acpmux daemon on a Unix socket: the
//! link connects, routes notifications, and one turn runs over the wire.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort, Preset, SessionSpec};
use optchat_chief::prompt::turn_blocks;
use optchat_chief::turn::{self, Interrupt, TurnStart};
use serde_json::{Value, json};

/// The events one prompt records, in the shapes acpmux stores them.
fn turn_events(prompt_id: &str) -> Vec<Value> {
    let update = |kind: &str, mut u: Value| {
        u["sessionUpdate"] = json!(kind);
        (
            kind.to_owned(),
            "in",
            json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "agent-1", "update": u}}),
        )
    };
    let raw = vec![
        (
            "user_message".to_owned(),
            "mux",
            json!({"promptId": prompt_id, "text": "..."}),
        ),
        (
            "turn_started".to_owned(),
            "mux",
            json!({"promptId": prompt_id}),
        ),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Reading."}}),
        ),
        update(
            "agent_thought_chunk",
            json!({"content": {"type": "text", "text": "hmm"}}),
        ),
        update(
            "tool_call",
            json!({"toolCallId": "tc1", "title": "Read x", "status": "in_progress", "rawInput": {"path": "x"}, "_meta": {"claude": {"tool": "Read"}}}),
        ),
        update(
            "tool_call_update",
            json!({"toolCallId": "tc1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "x holds 1"}}]}),
        ),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "x is 1."}}),
        ),
        (
            "turn_end".to_owned(),
            "mux",
            json!({"stopReason": "end_turn"}),
        ),
    ];
    raw.into_iter()
        .enumerate()
        .map(|(i, (kind, dir, msg))| json!({"seq": i + 1, "at": 1, "dir": dir, "kind": kind, "msg": msg}))
        .collect()
}

fn serve(listener: UnixListener, requests: Arc<Mutex<Vec<Value>>>, fail_presets: bool) {
    serve_with(listener, requests, fail_presets, &[]);
}

/// The first of `set`'s keys (in acpmux's order: sorted) that a daemon
/// knowing none of `unknown` refuses.
fn refused_key(set: &Value, unknown: &[&str]) -> Option<String> {
    let mut keys: Vec<&String> = set.as_object()?.keys().collect();
    keys.sort();
    keys.into_iter()
        .find(|k| unknown.contains(&k.as_str()))
        .cloned()
}

/// `unknown`: preset keys this acpmux does not know (`args` before #17283,
/// `systemPrompt` before the preset system prompt), refused as its
/// `_acpmux/presets` handler does ("unknown preset key").
fn serve_with(
    listener: UnixListener,
    requests: Arc<Mutex<Vec<Value>>>,
    fail_presets: bool,
    unknown: &'static [&'static str],
) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let requests = requests.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                let mut events: Vec<Value> = Vec::new();
                let mut send = |v: Value| writeln!(out, "{v}").unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    let id = req["id"].clone();
                    let reply =
                        |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
                    match req["method"].as_str().unwrap() {
                        "_acpmux/watch" => {
                            send(reply(json!({})));
                            send(
                                json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": {"sessionId": "c9", "session": {"sessionId": "c9", "name": "kid", "status": "running", "tags": {"mux.parent": "optchat-chief"}}}}),
                            );
                        }
                        "_acpmux/sessions" => send(reply(
                            json!({"sessions": [{"sessionId": "old", "name": "x", "status": "idle"}]}),
                        )),
                        "session/new" => send(reply(json!({"sessionId": "s-1"}))),
                        "_acpmux/presets"
                            if refused_key(&req["params"]["set"], unknown).is_some() =>
                        {
                            let key = refused_key(&req["params"]["set"], unknown).unwrap();
                            send(
                                json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": format!("unknown preset key {key:?}; use harness, model, effort, policy, env, args, description")}}),
                            )
                        }
                        "_acpmux/presets" if fail_presets => send(
                            json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found: _acpmux/presets"}}),
                        ),
                        "session/prompt" => {
                            let prompt_id = req["params"]["_meta"]["acpmux"]["promptId"]
                                .as_str()
                                .unwrap()
                                .to_owned();
                            events = turn_events(&prompt_id);
                            for e in &events {
                                if e["dir"] == "in" {
                                    let mut params = e["msg"]["params"].clone();
                                    params["sessionId"] = json!("s-1");
                                    params["_meta"] =
                                        json!({"acpmux": {"seq": e["seq"], "kind": e["kind"]}});
                                    send(
                                        json!({"jsonrpc": "2.0", "method": "session/update", "params": params}),
                                    );
                                } else {
                                    let mut ev = e.clone();
                                    ev["sessionId"] = json!("s-1");
                                    send(
                                        json!({"jsonrpc": "2.0", "method": "_acpmux/event", "params": ev}),
                                    );
                                }
                            }
                            send(reply(json!({"stopReason": "end_turn"})));
                        }
                        "_acpmux/events" => {
                            let after = req["params"]["afterSeq"].as_u64().unwrap();
                            let page: Vec<Value> = events
                                .iter()
                                .filter(|e| e["seq"].as_u64().unwrap() > after)
                                .cloned()
                                .collect();
                            send(reply(json!({"events": page})));
                        }
                        _ => send(reply(json!({}))),
                    }
                }
            });
        }
    });
}

#[test]
fn a_turn_over_the_acpmux_wire() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        false,
    );

    let acpmux = Acpmux::new(socket, None, Vec::new());
    let (tx, rx) = channel();
    let sink_tx = Mutex::new(tx);
    acpmux.spawn_link(
        Arc::new(move |e| sink_tx.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    let mut seen = Vec::new();
    while !seen.iter().any(|e| matches!(e, AgentEvent::Up(_))) {
        seen.push(rx.recv_timeout(common::WAIT).unwrap());
    }
    assert!(
        seen.iter()
            .any(|e| matches!(e, AgentEvent::SessionChanged(s) if s.session_id == "c9")),
        "session_changed reaches the brain"
    );
    assert!(seen.iter().any(
        |e| matches!(e, AgentEvent::Up(list) if list.len() == 1 && list[0].session_id == "old")
    ));

    let chat = common::open_chat(&dir.path().join("chat"));
    let start = TurnStart {
        system_prompt: None,
        key: "turn:optchat:0".into(),
        prompt_id: "optchat:0".into(),
        session: SessionSpec {
            name: "optchat-0".into(),
            cwd: dir.path().join("session"),
            harness: "claude-sr".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: None,
            tags: Default::default(),
        },
        blocks: turn_blocks("<chat>\n</chat>", &["what is x?".into()]),
        limit: None,
    };
    let outcome = turn::run(
        &*acpmux,
        &chat,
        &start,
        &Interrupt::new(),
        &|_| {},
        &|_, _| {},
        &optchat_chief::trace::Trace::off(),
    );
    assert_eq!(outcome.reply.as_deref(), Some("x is 1."));
    assert_eq!(outcome.error, None);
    let log: Vec<(String, String)> = (0..chat.status().messages)
        .map(|i| {
            let (k, t) = chat.message(i).unwrap();
            (k.as_str().to_owned(), t)
        })
        .collect();
    assert_eq!(
        log,
        vec![
            ("talk".to_string(), "Reading.".to_string()),
            ("tool".to_string(), "Read {\"path\":\"x\"}".to_string()),
            ("echo".to_string(), "x holds 1".to_string()),
            ("talk".to_string(), "x is 1.".to_string()),
        ]
    );
    let requests = requests.lock().unwrap();
    let find = |m: &str| requests.iter().find(|r| r["method"] == m).cloned().unwrap();
    let new = find("session/new");
    assert_eq!(new["params"]["cwd"], json!(dir.path().join("session")));
    assert_eq!(
        new["params"]["_meta"]["acpmux"],
        json!({"name": "optchat-0", "harness": "claude-sr", "policy": "approve-all"})
    );
    let prompt = find("session/prompt");
    assert_eq!(prompt["params"]["sessionId"], "s-1");
    assert_eq!(prompt["params"]["_meta"]["acpmux"]["promptId"], "optchat:0");
    assert_eq!(prompt["params"]["prompt"][1]["text"], "what is x?");
    assert_eq!(
        find("_acpmux/kill")["params"],
        json!({"sessionId": "s-1", "purge": true})
    );
}

fn connect(acpmux: &Arc<Acpmux>) {
    let (tx, rx) = channel();
    let sink_tx = Mutex::new(tx);
    acpmux.spawn_link(
        Arc::new(move |e| {
            let _ = sink_tx.lock().unwrap().send(e);
        }),
        Arc::new(|_: &str| {}),
    );
    loop {
        if matches!(rx.recv_timeout(common::WAIT).unwrap(), AgentEvent::Up(_)) {
            return;
        }
    }
}

fn compactor_preset() -> Preset {
    Preset {
        name: "optchat-compact-1a2b3c4d".into(),
        harness: "claude-sr".into(),
        env: [(
            "CLAUDE_CONFIG_DIR".to_owned(),
            "/h/optchat/compactor-claude".to_owned(),
        )]
        .into(),
        args: vec!["--tools".into(), "".into()],
        system_prompt: None,
    }
}

fn compactor_session(dir: &std::path::Path) -> SessionSpec {
    SessionSpec {
        name: "optchat-compact-1a2b3c4d-0-0".into(),
        cwd: dir.to_owned(),
        harness: "claude-sr".into(),
        policy: "deny-all".into(),
        model: Some("claude-sonnet-5-5".into()),
        effort: None,
        preset: Some("optchat-compact-1a2b3c4d".into()),
        tags: Default::default(),
    }
}

// Audit round 3, M1: a session that names a preset never starts without it
// (no fallback to the user's ~/.claude).
#[test]
fn a_session_that_requires_a_preset_refuses_to_start_without_it() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(UnixListener::bind(&socket).unwrap(), requests.clone(), true);
    let acpmux = Acpmux::new(socket, None, vec![compactor_preset()]);
    connect(&acpmux);
    let error = acpmux
        .new_session(&compactor_session(dir.path()))
        .unwrap_err();
    assert!(error.contains("preset"), "{error}");
    assert!(
        !requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r["method"] == "session/new"),
        "no session/new without the preset"
    );
}

#[test]
fn a_required_preset_is_installed_and_named_in_session_new() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        false,
    );
    let acpmux = Acpmux::new(socket, None, vec![compactor_preset()]);
    connect(&acpmux);
    assert_eq!(
        acpmux.new_session(&compactor_session(dir.path())),
        Ok("s-1".into())
    );
    let requests = requests.lock().unwrap();
    let preset = requests
        .iter()
        .find(|r| r["method"] == "_acpmux/presets")
        .unwrap();
    assert_eq!(preset["params"]["name"], "optchat-compact-1a2b3c4d");
    assert_eq!(
        preset["params"]["set"]["env"]["CLAUDE_CONFIG_DIR"],
        "/h/optchat/compactor-claude"
    );
    let new = requests
        .iter()
        .find(|r| r["method"] == "session/new")
        .unwrap();
    assert_eq!(
        new["params"]["_meta"]["acpmux"]["preset"],
        "optchat-compact-1a2b3c4d"
    );
    assert!(new["params"]["_meta"]["acpmux"].get("effort").is_none());
}

// The compactor's cached layout needs preset args: a daemon that refuses the
// key still gets the preset (without args), and the port says args are off,
// so the compactor keeps the old layout.
#[test]
fn preset_args_are_sent_and_feature_detected() {
    for old in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("acpmux.sock");
        let requests = Arc::new(Mutex::new(Vec::new()));
        serve_with(
            UnixListener::bind(&socket).unwrap(),
            requests.clone(),
            false,
            if old { &["args"] } else { &[] },
        );
        let acpmux = Acpmux::new(socket, None, vec![compactor_preset()]);
        connect(&acpmux);
        assert_eq!(acpmux.preset_args("optchat-compact-1a2b3c4d"), !old);
        assert_eq!(
            acpmux.new_session(&compactor_session(dir.path())),
            Ok("s-1".into()),
            "the preset is installed either way"
        );
        let requests = requests.lock().unwrap();
        let sets: Vec<&Value> = requests
            .iter()
            .filter(|r| r["method"] == "_acpmux/presets")
            .collect();
        assert_eq!(sets[0]["params"]["set"]["args"], json!(["--tools", ""]));
        if old {
            assert_eq!(sets.len(), 2, "installed again without args");
            assert!(sets[1]["params"]["set"].get("args").is_none());
        } else {
            assert_eq!(sets.len(), 1);
        }
    }
}

// The cached layout needs the preset `systemPrompt` (acpmux writes the text
// into its own preset directory and checks its sha256 at every session
// start): it is sent at install and replaced by `set_system_prompt`; a
// daemon that refuses the key still gets the preset (without it), and the
// port says so, so the turns and the compactor keep the old layout.
#[test]
fn a_preset_system_prompt_is_installed_replaced_and_feature_detected() {
    let cases: [(&'static [&'static str], bool, bool); 3] = [
        (&[], true, true),
        (&["systemPrompt"], false, true),
        (&["args", "systemPrompt"], false, false),
    ];
    for (unknown, prompt, args) in cases {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("acpmux.sock");
        let requests = Arc::new(Mutex::new(Vec::new()));
        serve_with(
            UnixListener::bind(&socket).unwrap(),
            requests.clone(),
            false,
            unknown,
        );
        let preset = Preset {
            system_prompt: Some("seed".into()),
            ..compactor_preset()
        };
        let acpmux = Acpmux::new(socket, None, vec![preset]);
        connect(&acpmux);
        let name = "optchat-compact-1a2b3c4d";
        assert_eq!(acpmux.system_prompt(name), prompt, "{unknown:?}");
        assert_eq!(acpmux.preset_args(name), args, "{unknown:?}");
        {
            let requests = requests.lock().unwrap();
            let first = requests
                .iter()
                .find(|r| r["method"] == "_acpmux/presets")
                .unwrap();
            assert_eq!(first["params"]["set"]["systemPrompt"], "seed");
        }
        let set = acpmux.set_system_prompt(name, "HEAD of the view");
        if prompt {
            assert_eq!(set, Ok(()));
            let requests = requests.lock().unwrap();
            let last = requests
                .iter()
                .rfind(|r| r["method"] == "_acpmux/presets")
                .unwrap();
            assert_eq!(
                last["params"],
                json!({"name": name, "set": {"systemPrompt": "HEAD of the view"}})
            );
        } else {
            assert!(set.is_err(), "{unknown:?}");
        }
        assert_eq!(
            acpmux.new_session(&compactor_session(dir.path())),
            Ok("s-1".into()),
            "the preset is installed either way"
        );
    }
}

// The durable-sessions lead excludes the Chief's own sessions by tag: a
// session with tags gets them right after session/new (`_acpmux/tag`); a
// session without (a child) sends none.
#[test]
fn session_tags_are_set_right_after_session_new() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        false,
    );
    let acpmux = Acpmux::new(socket, None, vec![compactor_preset()]);
    connect(&acpmux);
    let tags = optchat_chief::acpmux::chief_tags("1a2b3c4d", "compactor");
    let spec = SessionSpec {
        tags: tags.clone(),
        ..compactor_session(dir.path())
    };
    assert_eq!(acpmux.new_session(&spec), Ok("s-1".into()));
    assert_eq!(
        acpmux.new_session(&compactor_session(dir.path())),
        Ok("s-1".into())
    );
    let requests = requests.lock().unwrap();
    let methods: Vec<&str> = requests
        .iter()
        .map(|r| r["method"].as_str().unwrap())
        .filter(|m| *m == "session/new" || *m == "_acpmux/tag")
        .collect();
    assert_eq!(methods, vec!["session/new", "_acpmux/tag", "session/new"]);
    let tag = requests
        .iter()
        .find(|r| r["method"] == "_acpmux/tag")
        .unwrap();
    assert_eq!(
        tag["params"],
        json!({"sessionId": "s-1", "set": {"cmux.chief": "1a2b3c4d", "cmux.chief.role": "compactor"}})
    );
}

/// At start the host reads acpmux's harness metadata on a connection of its
/// own (`_acpmux/harnesses`), the source of every harness family.
#[test]
fn query_harnesses_reads_the_daemons_harness_metadata() {
    use optchat_chief::acpmux::{Family, harness_family, query_harnesses};
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let methods = Arc::new(Mutex::new(Vec::<String>::new()));
    let seen = methods.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let mut out = conn.try_clone().unwrap();
            for line in BufReader::new(conn).lines() {
                let Ok(line) = line else { break };
                let req: Value = serde_json::from_str(&line).unwrap();
                let method = req["method"].as_str().unwrap().to_owned();
                seen.lock().unwrap().push(method.clone());
                let result = match method.as_str() {
                    "_acpmux/harnesses" => json!({"harnesses": {
                        "claude-sr": {"kind": "claude-stdio", "argv": ["sr", "claude", "proxy"], "family": "claude"},
                        "codex": {"argv": ["/x/codex-acp"], "family": "codex"},
                    }, "defaultHarness": "claude-sr"}),
                    _ => json!({}),
                };
                writeln!(
                    out,
                    "{}",
                    json!({"jsonrpc": "2.0", "id": req["id"], "result": result})
                )
                .unwrap();
            }
        }
    });
    let answer = query_harnesses(&socket, &|_: &str| {}).unwrap();
    assert_eq!(harness_family(&answer, "codex"), Ok(Family::Codex));
    assert_eq!(harness_family(&answer, "claude-sr"), Ok(Family::Claude));
    assert_eq!(
        *methods.lock().unwrap(),
        vec!["initialize".to_owned(), "_acpmux/harnesses".to_owned()]
    );
}
