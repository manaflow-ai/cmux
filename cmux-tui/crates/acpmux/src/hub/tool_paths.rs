//! Part of `Hub`; see `hub/mod.rs`. Each tool call path a record names gets
//! its canonical form beside it (`crate::path_canon`), so a client compares
//! files by one spelling: the edited-files card lists a failed call and its
//! retry at another spelling once.

use super::*;

/// Sets `_meta.acpmux.canonicalPath` beside each path a `tool_call` or
/// `tool_call_update` record names: each of its `locations`, each `diff` in
/// its content, and the update itself for its input's `file_path`. Paths are
/// read from the session's cwd. A place that already carries one (a fork's copy
/// of its parent's record) keeps it, and nothing else in `_meta` changes.
/// Every record that passes here also gets a shell call's exit code and command
/// where clients read them (`tool_shell::add_shell_fields`). Each path is read
/// from the disk once per chat (`Session::canon_paths`), not on every streamed
/// update; the record still carries it when it is logged and sent, so a replay
/// reads the same record.
pub(super) fn add_canonical_paths(session: &Session, kind: &str, msg: &mut Value) {
    if !matches!(kind.strip_suffix(".replay").unwrap_or(kind), "tool_call" | "tool_call_update") {
        return;
    }
    // A shell call's exit code and command where clients read them (`tool_shell.rs`).
    super::tool_shell::add_shell_fields(kind, msg);
    // The packages it installs, while Usage Patterns is on (`tool_installs.rs`).
    super::tool_installs::count_installs(&session.id, kind, msg);
    let Some(update) = msg.pointer_mut("/params/update").filter(|u| u.is_object()) else {
        return;
    };
    let cwd = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).cwd.clone();
    let canonical = |path: Option<&str>| path.and_then(|p| session.canon_paths.canonical(p, &cwd));
    if let Some(locations) = update.get_mut("locations").and_then(Value::as_array_mut) {
        for location in locations {
            let path = location.get("path").and_then(Value::as_str).map(str::to_owned);
            note(location, || canonical(path.as_deref()));
        }
    }
    if let Some(content) = update.get_mut("content").and_then(Value::as_array_mut) {
        for diff in content.iter_mut().filter(|item| item["type"] == "diff") {
            let path = diff.get("path").and_then(Value::as_str).map(str::to_owned);
            note(diff, || canonical(path.as_deref()));
        }
    }
    let input = update.pointer("/rawInput/file_path").and_then(Value::as_str).map(str::to_owned);
    if input.is_some() {
        note(update, || canonical(input.as_deref()));
    }
    // A finished read of an image file that returned no image gets the file's image
    // (`tool_read_images.rs`): Codex's View of a PNG drew as its bare path.
    // Resolved afresh, not from the chat's cache: it reads the file's bytes, so a link
    // retargeted since the chat first named the path reads what it names now. Once per
    // finished read, not per streamed update.
    super::tool_read_images::add_read_image(kind, msg, &cwd);
}

/// `target._meta.acpmux.canonicalPath` = `canonical()`, unless it has one or
/// its `_meta` is not an object.
fn note(target: &mut Value, canonical: impl FnOnce() -> Option<String>) {
    let Some(fields) = target.as_object_mut() else { return };
    if fields.get("_meta").and_then(|meta| meta.pointer("/acpmux/canonicalPath")).is_some() {
        return;
    }
    let Some(path) = canonical() else { return };
    let Some(meta) = fields.entry("_meta").or_insert_with(|| json!({})).as_object_mut() else {
        return;
    };
    if let Some(acpmux) = meta.entry("acpmux").or_insert_with(|| json!({})).as_object_mut() {
        acpmux.insert("canonicalPath".into(), json!(path));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir).unwrap();
        Hub::new(cfg, store)
    }

    /// A session working in `cwd`.
    fn session_in(hub: &Hub, cwd: &std::path::Path) -> Arc<Session> {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA,
            "id": "s-tool-paths",
            "name": "tool-paths",
            "harness": "claude",
            "cwd": cwd,
            "status": "idle",
            "createdAt": 0,
            "updatedAt": 0,
        }))
        .unwrap();
        hub.make_session(meta)
    }

    fn update(fields: Value) -> Value {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": fields}})
    }

    #[cfg(unix)]
    #[test]
    fn a_tool_call_records_the_canonical_path_of_each_file_it_names() {
        let store = cmux_unix_socket::short_test_dir("acpmux-tp");
        let dir = std::env::temp_dir().join(format!("acpmux-tool-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("real")).unwrap();
        std::fs::write(dir.join("real/notes.txt"), "notes\n").unwrap();
        std::os::unix::fs::symlink(dir.join("real"), dir.join("link")).unwrap();
        let want = std::fs::canonicalize(dir.join("real/notes.txt")).unwrap();
        let want = json!(want.to_str().unwrap());
        let hub = hub_at(store.path());
        let session = session_in(&hub, &dir.join("link"));

        let (rec, _) = hub.append_logged(
            &session,
            "in",
            "tool_call",
            update(json!({
                "sessionUpdate": "tool_call", "toolCallId": "w1", "kind": "edit", "status": "pending",
                "rawInput": {"file_path": "./notes.txt", "content": "x"},
                "locations": [{"path": "./notes.txt", "line": 3}],
                "content": [
                    {"type": "diff", "path": "./notes.txt", "oldText": null, "newText": "x", "_meta": {"acpmux": {"fragment": true}}},
                    {"type": "content", "content": {"type": "text", "text": "./notes.txt"}},
                ],
            })),
            None,
        );
        let call = &rec.msg["params"]["update"];
        assert_eq!(call["locations"][0]["_meta"]["acpmux"]["canonicalPath"], want, "{call}");
        assert_eq!(call["locations"][0]["path"], "./notes.txt", "the agent's spelling stays");
        assert_eq!(call["locations"][0]["line"], 3);
        assert_eq!(call["content"][0]["_meta"]["acpmux"]["canonicalPath"], want);
        assert_eq!(call["content"][0]["_meta"]["acpmux"]["fragment"], true, "kept beside it");
        assert!(call["content"][1].get("_meta").is_none(), "{call}");
        assert_eq!(call["_meta"]["acpmux"]["canonicalPath"], want, "the input's file_path");
        // The store holds the same record.
        let mut stored = Vec::new();
        let _ = hub.store.scan_kinds(&session.id, &["tool_call"], &mut |e: EventRecord| {
            stored.push(e.msg);
            true
        });
        assert_eq!(stored, std::slice::from_ref(&rec.msg));

        // A settled update (no input), and a copy that already names one (a
        // fork's), keep theirs; other records are left as they are.
        let (done, _) = hub.append_logged(
            &session,
            "in",
            "tool_call_update",
            update(json!({
                "sessionUpdate": "tool_call_update", "toolCallId": "w1", "status": "completed",
                "content": [{"type": "diff", "path": "/elsewhere/notes.txt", "oldText": "a", "newText": "b", "_meta": {"acpmux": {"canonicalPath": "/kept/notes.txt"}}}],
                "locations": [{"path": dir.join("link/notes.txt")}],
            })),
            None,
        );
        let settled = &done.msg["params"]["update"];
        assert_eq!(settled["content"][0]["_meta"]["acpmux"]["canonicalPath"], "/kept/notes.txt");
        assert_eq!(settled["locations"][0]["_meta"]["acpmux"]["canonicalPath"], want);
        assert!(settled.get("_meta").is_none(), "{settled}");
        let chunk = update(
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "./notes.txt"}}),
        );
        let (said, _) =
            hub.append_logged(&session, "in", "agent_message_chunk", chunk.clone(), None);
        assert_eq!(said.msg, chunk);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A tool call streams many updates naming the same files: each distinct
    /// path is read from the disk once per chat, not once per update, however
    /// deep it is (acpmux audit finding 12). Prints, per depth, the resolutions
    /// of 200 logged updates, their time, and the time of the path pass alone
    /// over 200 more (`TOOL-PATHS` lines; nextest.toml keeps them on a pass), then
    /// checks the counts, so a red run still prints both depths.
    #[cfg(unix)]
    #[test]
    fn streamed_updates_naming_the_same_files_resolve_each_once() {
        let mut counts = Vec::new();
        for depth in [1usize, 40] {
            let store = cmux_unix_socket::short_test_dir("acpmux-tq");
            let dir = std::env::temp_dir()
                .join(format!("acpmux-tool-paths-once-{depth}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            let deep: std::path::PathBuf = (0..depth).map(|i| format!("d{i}")).collect();
            std::fs::create_dir_all(dir.join(&deep)).unwrap();
            let names: Vec<String> = (0..3)
                .map(|i| {
                    let rel = deep.join(format!("f{i}.rs"));
                    std::fs::write(dir.join(&rel), "x\n").unwrap();
                    rel.to_str().unwrap().to_owned()
                })
                .collect();
            let want: Vec<Value> = names
                .iter()
                .map(|n| json!(std::fs::canonicalize(dir.join(n)).unwrap().to_str().unwrap()))
                .collect();
            let edit = |n: usize| {
                let path = &names[n % 3];
                update(json!({
                    "sessionUpdate": "tool_call_update", "toolCallId": format!("e{}", n % 3),
                    "kind": "edit", "status": "in_progress",
                    "rawInput": {"file_path": path},
                    "locations": [{"path": path}],
                    "content": [{"type": "diff", "path": path, "oldText": "x", "newText": format!("{n}")}],
                }))
            };
            let hub = hub_at(store.path());
            let resolved = || crate::path_canon::RESOLUTIONS.with(std::cell::Cell::get);

            // 200 updates logged as an agent streams them.
            let session = session_in(&hub, &dir);
            let before = resolved();
            let started = std::time::Instant::now();
            let mut records = Vec::new();
            for n in 0..200 {
                let (rec, _) = hub.append_logged(&session, "in", "tool_call_update", edit(n), None);
                records.push((n % 3, rec.msg));
            }
            let appends = started.elapsed();
            let resolutions = resolved() - before;

            // The path pass alone, as the reader runs it before each append.
            let msgs: Vec<Value> = (0..200).map(edit).collect();
            let started = std::time::Instant::now();
            for mut msg in msgs {
                add_canonical_paths(&session, "tool_call_update", &mut msg);
                std::hint::black_box(&msg);
            }
            let pass = started.elapsed();
            eprintln!(
                "TOOL-PATHS depth={depth} updates=200 paths=3 resolutions={resolutions} appends={appends:?} path_pass_200={pass:?}"
            );
            // Every record still carries its file's canonical path, in each place.
            for (i, msg) in &records {
                let u = &msg["params"]["update"];
                assert_eq!(u["_meta"]["acpmux"]["canonicalPath"], want[*i], "{u}");
                assert_eq!(u["locations"][0]["_meta"]["acpmux"]["canonicalPath"], want[*i]);
                assert_eq!(u["content"][0]["_meta"]["acpmux"]["canonicalPath"], want[*i]);
            }
            counts.push((depth, resolutions));
            let _ = std::fs::remove_dir_all(&dir);
        }
        for (depth, resolutions) in counts {
            assert!(resolutions <= 3, "depth {depth}: {resolutions} resolutions for 3 paths");
        }
    }

    /// The log stores an OpenCode shell call's exit code where clients read it
    /// (`tool_shell.rs`), so a replay hears the same record.
    #[cfg(unix)]
    #[test]
    fn a_logged_shell_result_records_its_exit_code() {
        let store = cmux_unix_socket::short_test_dir("acpmux-ts");
        let hub = hub_at(store.path());
        let session = session_in(&hub, store.path());
        let (rec, _) = hub.append_logged(
            &session,
            "in",
            "tool_call_update",
            update(json!({
                "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
                "rawOutput": {"output": "boom", "metadata": {"exit": 1, "truncated": false}},
            })),
            None,
        );
        assert_eq!(rec.msg["params"]["update"]["rawOutput"]["exit_code"], 1, "{}", rec.msg);
        let mut stored = Vec::new();
        let _ = hub.store.scan_kinds(&session.id, &["tool_call_update"], &mut |e: EventRecord| {
            stored.push(e.msg);
            true
        });
        assert_eq!(stored, std::slice::from_ref(&rec.msg));
    }
}
