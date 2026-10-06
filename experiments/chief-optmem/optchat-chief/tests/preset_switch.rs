//! An engine switch reuses the acpmux daemon of the Chief home, which saved
//! the presets of the last host (acpmux merges a `set` into the saved
//! preset). A Claude preset leaves `args` and `systemPrompt` behind, and a
//! codex host's set that does not clear them was refused: "args: only Claude
//! Code harnesses take preset args", so every compactor session failed to
//! start (cmux-lawrence-2 preflight, 2026-10-06).

mod common;

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort, Preset, SessionSpec};
use serde_json::{Value, json};

/// A fake acpmux that keeps presets and merges each `set` into the saved
/// one as acpmux does: a key that is absent keeps its saved value, `null`
/// clears it; preset args on a non-Claude harness are refused.
fn serve(listener: UnixListener, saved: Arc<Mutex<BTreeMap<String, Value>>>, sets: Arc<Mutex<Vec<Value>>>) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let saved = saved.clone();
            let sets = sets.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    let id = req["id"].clone();
                    let reply = match req["method"].as_str().unwrap_or("") {
                        "_acpmux/sessions" => json!({"jsonrpc": "2.0", "id": id, "result": {"sessions": []}}),
                        "_acpmux/presets" if req["params"].get("set").is_some() => {
                            sets.lock().unwrap().push(req["params"].clone());
                            let name = req["params"]["name"].as_str().unwrap().to_owned();
                            let mut map = saved.lock().unwrap();
                            let mut merged = map.get(&name).cloned().unwrap_or_else(|| json!({}));
                            for (k, v) in req["params"]["set"].as_object().unwrap() {
                                if v.is_null() {
                                    merged.as_object_mut().unwrap().remove(k);
                                } else {
                                    merged[k] = v.clone();
                                }
                            }
                            let claude = merged["harness"].as_str().is_some_and(|h| h.starts_with("claude"));
                            let args = merged.get("args").and_then(Value::as_array).is_some_and(|a| !a.is_empty());
                            let prompt = merged.get("systemPrompt").is_some();
                            if !claude && args {
                                json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "args: only Claude Code harnesses take preset args; this harness takes none"}})
                            } else if !claude && prompt {
                                json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "systemPrompt: only Claude Code harnesses take a system prompt file"}})
                            } else {
                                map.insert(name, merged);
                                json!({"jsonrpc": "2.0", "id": id, "result": {}})
                            }
                        }
                        _ => json!({"jsonrpc": "2.0", "id": id, "result": {}}),
                    };
                    writeln!(out, "{reply}").unwrap();
                }
            });
        }
    });
}

fn connect(acpmux: &Arc<Acpmux>) {
    let (tx, rx) = channel();
    let sink = Mutex::new(tx);
    acpmux.spawn_link(Arc::new(move |e| { let _ = sink.lock().unwrap().send(e); }), Arc::new(|_: &str| {}));
    loop {
        if matches!(rx.recv_timeout(common::WAIT).unwrap(), AgentEvent::Up(_)) {
            return;
        }
    }
}

fn preset(harness: &str, args: Vec<String>, prompt: Option<&str>) -> Preset {
    Preset {
        name: "optchat-compact-1a2b3c4d-slot-0".into(),
        harness: harness.into(),
        env: BTreeMap::new(),
        args,
        system_prompt: prompt.map(str::to_owned),
    }
}

#[test]
fn a_codex_host_installs_the_compactor_preset_a_claude_host_saved() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let saved = Arc::new(Mutex::new(BTreeMap::new()));
    let sets = Arc::new(Mutex::new(Vec::new()));
    serve(UnixListener::bind(&socket).unwrap(), saved.clone(), sets.clone());
    // The claude-sr host before the switch.
    let claude = Acpmux::new(socket.clone(), None, vec![preset("claude-sr", vec!["--tools".into(), String::new()], Some("seed"))]);
    connect(&claude);
    // The codex host after it, on the same daemon.
    let codex = Acpmux::new(socket, None, vec![preset("codex", Vec::new(), None)]);
    connect(&codex);
    let spec = SessionSpec {
        name: "optchat-compact-1a2b3c4d-0-0".into(),
        cwd: dir.path().to_owned(),
        harness: "codex".into(),
        policy: "deny-all".into(),
        model: None,
        effort: None,
        preset: Some("optchat-compact-1a2b3c4d-slot-0".into()),
        tags: Default::default(),
    };
    assert!(codex.new_session(&spec).is_ok(), "the compactor session starts on codex");
    let saved = saved.lock().unwrap();
    let kept = &saved["optchat-compact-1a2b3c4d-slot-0"];
    assert_eq!(kept["harness"], "codex");
    assert!(kept.get("args").is_none() && kept.get("systemPrompt").is_none(), "{kept}");
}
