#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "cmux-launch-snapshot-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ))
    }

    fn read_snapshot(path: &Path) -> Option<Value> {
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    /// Waits until the snapshot file satisfies `accept` (the writer settles
    /// on its own schedule; tests may wait).
    fn wait_for_snapshot(path: &Path, accept: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(snapshot) = read_snapshot(path)
                && accept(&snapshot)
            {
                return snapshot;
            }
            assert!(Instant::now() < deadline, "snapshot never matched: {:?}", read_snapshot(path));
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn workspace_names(snapshot: &Value) -> Vec<String> {
        snapshot["tree"]["workspaces"]
            .as_array()
            .map(|workspaces| {
                workspaces
                    .iter()
                    .filter_map(|workspace| workspace["name"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn cmux_next_launch_snapshot_follows_the_tree_after_it_settles() {
        let root = temp_root("tree");
        let mux =
            Mux::open_persistent("launch-snapshot-tree", SurfaceOptions::default(), &root).unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
            },
        )
        .unwrap()
        .expect("a persistent session has a snapshot path");
        let path = writer.path().to_path_buf();
        assert_eq!(path.file_name().unwrap(), "launch-snapshot.json");
        assert_eq!(mux.launch_snapshot_path().as_deref(), Some(path.as_path()));

        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert!(
            identify["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|capability| capability == LAUNCH_SNAPSHOT_CAPABILITY)
        );
        assert_eq!(identify["launch_snapshot_path"], json!(path.to_string_lossy()));

        let placement = mux.create_empty_workspace(Some("first".into()), None, None).unwrap();
        let snapshot = wait_for_snapshot(&path, |snapshot| {
            workspace_names(snapshot).contains(&"first".to_string())
        });
        assert_eq!(snapshot["schema_version"], json!(1));
        assert_eq!(snapshot["app"], json!("cmux-tui"));
        assert_eq!(snapshot["session"], json!("launch-snapshot-tree"));
        let (registry_id, generation) = mux.registry_identity();
        assert_eq!(snapshot["registry_id"], json!(registry_id));
        assert_eq!(snapshot["generation"], json!(generation));
        assert!(snapshot["written_at_ms"].as_u64().is_some());
        // The tree is the list-workspaces reply, so frontends decode it with
        // the decoder they already have.
        let listed = run_command(&mux, json!({"cmd":"list-workspaces"}));
        assert_eq!(snapshot["tree"]["workspaces"], listed["workspaces"]);

        assert!(mux.rename_workspace(placement.workspace, "renamed".into()));
        wait_for_snapshot(&path, |snapshot| {
            workspace_names(snapshot) == vec!["renamed".to_string()]
        });

        // Written atomically: no temporary file is left next to it.
        let leftovers = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry.file_name().to_string_lossy().starts_with("launch-snapshot.json.")
            })
            .count();
        assert_eq!(leftovers, 0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "tab titles and paths are private to the user");
        }

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_carries_frontend_projections() {
        let root = temp_root("projection");
        let mux =
            Mux::open_persistent("launch-snapshot-projection", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
            },
        )
        .unwrap()
        .unwrap();
        run_command(
            &mux,
            json!({
                "cmd":"put-frontend-projection",
                "frontend":"cmux-next",
                "scope":"personal",
                "subject_key":"windows",
                "schema_version":1,
                "projection":{"windows":[{"id":"w1","workspace_keys":[]}]},
                "origin":"test",
                "mutation_id":"launch-snapshot-projection",
            }),
        );
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["frontend_projections"].as_array().is_some_and(|projections| {
                projections.iter().any(|projection| projection["subject_key"] == "windows")
            })
        });
        let projection = snapshot["frontend_projections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|projection| projection["subject_key"] == "windows")
            .unwrap()
            .clone();
        assert_eq!(projection["frontend"], "cmux-next");
        assert_eq!(projection["scope"], "personal");
        assert_eq!(projection["projection"]["windows"][0]["id"], "w1");

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_writes_nothing_while_nothing_changes() {
        let root = temp_root("idle");
        let mux =
            Mux::open_persistent("launch-snapshot-idle", SurfaceOptions::default(), &root).unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(30),
                max_delay: Duration::from_millis(300),
            },
        )
        .unwrap()
        .unwrap();
        // The first write happens at start, so a relaunch finds a file.
        wait_for_snapshot(writer.path(), |_| true);
        let settled = writer.writes();
        assert!(settled >= 1);
        std::thread::sleep(Duration::from_millis(400));
        assert_eq!(writer.writes(), settled, "an idle session must not rewrite its snapshot");

        mux.create_empty_workspace(Some("burst".into()), None, None).unwrap();
        for index in 0..20 {
            let workspace = mux.with_state(|state| state.workspaces[0].id);
            mux.rename_workspace(workspace, format!("burst-{index}"));
        }
        wait_for_snapshot(writer.path(), |snapshot| {
            workspace_names(snapshot) == vec!["burst-19".to_string()]
        });
        // A burst of changes settles into a few writes, not one per change.
        assert!(writer.writes() - settled <= 3, "writes: {}", writer.writes() - settled);

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_has_no_path_without_a_persistent_registry() {
        let mux = Mux::new_for_test("launch-snapshot-memory", SurfaceOptions::default());
        assert!(start_launch_snapshot_writer(&mux).unwrap().is_none());
        assert_eq!(mux.launch_snapshot_path(), None);
        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert_eq!(identify["launch_snapshot_path"], Value::Null);
    }

    fn run_command(mux: &Arc<Mux>, request: Value) -> Value {
        let command: Command = serde_json::from_value(request).unwrap();
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        handle_command(mux, 0, command, &writer).unwrap()
    }
}
