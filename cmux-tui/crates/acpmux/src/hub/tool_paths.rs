//! Part of `Hub`; see `hub/mod.rs`. Each tool call path a record names gets
//! its canonical form beside it (`crate::path_canon`), so a client compares
//! files by one spelling: the edited-files card lists a failed call and its
//! retry at another spelling once.

#[cfg(test)]
mod tests {
    use super::super::*;

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
        assert_eq!(stored, [rec.msg.clone()]);

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
}
