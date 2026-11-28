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

/// Over its bound, the snapshot leaves out the largest projections first,
/// only as many as it must, and names them.
#[test]
fn an_oversized_snapshot_drops_the_largest_projections_first() {
    let projection = |subject: &str, bytes: usize| crate::workspace_registry::FrontendProjection {
        frontend: "cmux-next".into(),
        scope: "personal".into(),
        subject_key: subject.into(),
        schema_version: 1,
        projection_revision: 1,
        projection: json!({"pad":"x".repeat(bytes)}),
    };
    let big = MAX_LAUNCH_SNAPSHOT_BYTES / 2;
    let projections =
        vec![projection("windows", 1000), projection("history", big), projection("bookmarks", big)];
    let size = |keep: &[bool]| {
        let kept: Vec<_> = projections
            .iter()
            .zip(keep)
            .filter(|(_, keep)| **keep)
            .map(|(projection, _)| SortedProjection::from(projection))
            .collect();
        serde_json::to_vec(&json!({"tree":{},"frontend_projections":kept})).unwrap().len()
    };
    let mut keep = vec![true; projections.len()];
    let bytes = size(&keep);
    assert!(bytes > MAX_LAUNCH_SNAPSHOT_BYTES);
    let dropped = drop_largest_projections(&projections, &mut keep, bytes);
    assert_eq!(dropped.len(), 1, "only as many as needed: {dropped:?}");
    assert!(dropped[0].ends_with("/history") || dropped[0].ends_with("/bookmarks"));
    assert!(size(&keep) <= MAX_LAUNCH_SNAPSHOT_BYTES);
    assert!(keep[0], "the small window state is kept: {keep:?}");
}

/// The snapshot as it was built before it streamed: one `serde_json::Value`
/// for the whole file. The streamed bytes must be these bytes.
fn launch_snapshot_value_reference(mux: &Mux, include_projections: bool) -> Value {
    let tree = list_workspaces_reply(mux).unwrap();
    let (registry_id, generation) = mux.registry_identity();
    let personal = match mux.personal_snapshot() {
        Ok(personal) => {
            let mut personal = serde_json::to_value(personal).unwrap();
            for profile in
                personal.get_mut("profiles").and_then(Value::as_array_mut).into_iter().flatten()
            {
                if let Some(defaults) = profile.get_mut("defaults").and_then(Value::as_object_mut) {
                    defaults.remove("env");
                }
            }
            for session in
                personal.get_mut("sessions").and_then(Value::as_array_mut).into_iter().flatten()
            {
                if let Some(session) = session.as_object_mut() {
                    session.remove("capabilities");
                }
            }
            personal
        }
        Err(_) => Value::Null,
    };
    let projections = if include_projections {
        serde_json::to_value(mux.launch_snapshot_frontend_projections().unwrap()).unwrap()
    } else {
        json!([])
    };
    let sidebar_doc = if include_projections { launch_sidebar_doc(mux) } else { Value::Null };
    json!({
        "schema_version": LAUNCH_SNAPSHOT_SCHEMA_VERSION,
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "session": mux.session,
        "registry_id": registry_id,
        "generation": generation,
        "written_at_ms": 1_764_000_000_000u64,
        "tree": tree,
        "personal": personal,
        "frontend_projections": projections,
        "sidebar_doc": sidebar_doc,
    })
}

/// The streamed snapshot is byte for byte the `Value` form it replaced, with
/// personal state, a room env, session capabilities and projections in it,
/// and the file compares equal to it apart from its write time.
#[test]
fn the_streamed_launch_snapshot_matches_the_value_form_byte_for_byte() {
    let root = temp_root("bytes");
    let mux =
        Mux::open_persistent("launch-snapshot-bytes", SurfaceOptions::default(), &root).unwrap();
    mux.create_empty_workspace(Some("one".into()), None, None).unwrap();
    mux.create_empty_workspace(Some("two \"quoted\" \u{e9}".into()), None, None).unwrap();
    run_command(
        &mux,
        json!({"cmd":"create-profile","profile":"prof_work","name":"Work",
               "defaults":{"cwd":"/tmp","env":{"TOKEN":"secret"}}}),
    );
    run_command(
        &mux,
        json!({"cmd":"put-session","session_id":"remote-1","transport":{"kind":"ssh"},
               "capabilities":["profiles-v1"]}),
    );
    run_command(
        &mux,
        json!({"cmd":"put-frontend-projection","frontend":"cmux-next","scope":"personal",
               "subject_key":"windows","schema_version":1,
               "projection":{"windows":[{"id":"w1","z":1.5,"b":[true,null]}]},
               "origin":"test","mutation_id":"bytes-1"}),
    );
    for include_projections in [true, false] {
        let parts = launch_snapshot_parts(&mux, include_projections).unwrap();
        let keep = vec![true; parts.projections.len()];
        let mut streamed = launch_snapshot_body(&mux, &parts, &keep).unwrap();
        streamed.extend_from_slice(b"1764000000000}");
        let reference =
            serde_json::to_vec(&launch_snapshot_value_reference(&mux, include_projections))
                .unwrap();
        assert_eq!(
            String::from_utf8(streamed).unwrap(),
            String::from_utf8(reference).unwrap(),
            "include_projections={include_projections}"
        );
    }
    let path = root.join(LAUNCH_SNAPSHOT_FILE);
    let (_, written) = write_launch_snapshot(&mux, &path).unwrap();
    assert!(written > 0);
    let (_, again) = write_launch_snapshot(&mux, &path).unwrap();
    assert_eq!(again, 0, "the same contents are not written again");
    let parts = launch_snapshot_parts(&mux, true).unwrap();
    let keep = vec![true; parts.projections.len()];
    let body = launch_snapshot_body(&mux, &parts, &keep).unwrap();
    assert!(same_snapshot_on_disk(&path, &body));
    assert!(!same_snapshot_on_disk(&path, &body[..body.len() - 1]));
    let mut other = body.clone();
    other[1] = b' ';
    assert!(!same_snapshot_on_disk(&path, &other));
    mux.create_empty_workspace(Some("three".into()), None, None).unwrap();
    let (_, changed) = write_launch_snapshot(&mux, &path).unwrap();
    assert!(changed > 0, "a change is written");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
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
            max_bytes_per_second: u64::MAX,
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
    wait_for_snapshot(&path, |snapshot| workspace_names(snapshot) == vec!["renamed".to_string()]);

    // Written atomically: no temporary file is left next to it.
    let leftovers = std::fs::read_dir(path.parent().unwrap())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("launch-snapshot.json."))
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

/// The app draws the Pinned band from the snapshot before it connects
/// (Lawrence 2026-10-29: pins came back minutes after an update), so the
/// snapshot holds the sidebar document as `sidebar.get` returns it, and a
/// pin rewrites it.
#[test]
fn cmux_next_launch_snapshot_carries_the_sidebar_document() {
    let root = temp_root("sidebar-doc");
    let mux = Mux::open_persistent("launch-snapshot-sidebar-doc", SurfaceOptions::default(), &root)
        .unwrap();
    let writer = start_launch_snapshot_writer_with(
        &mux,
        LaunchSnapshotTiming {
            settle: Duration::from_millis(50),
            max_delay: Duration::from_millis(500),
            max_bytes_per_second: u64::MAX,
        },
    )
    .unwrap()
    .unwrap();
    let request = |operation: &str, params: Value, key: Option<&str>| {
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                                  "operation":operation,"params":params});
        if let Some(key) = key {
            envelope["idempotency_key"] = json!(key);
        }
        let response =
            crate::resource_router::handle_resource_message(&mux, &envelope.to_string()).unwrap();
        assert_eq!(response["ok"], true, "{operation}: {response}");
        response["result"].clone()
    };
    mux.create_empty_workspace(Some("pinned-one".into()), None, None).unwrap();
    let doc = request("sidebar.get", json!({}), None);
    let item = doc["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["body"]["type"] == "workspace")
        .map(|item| item["id"].clone());
    let item = match item {
        Some(item) => item,
        None => {
            let (registry_id, _) = mux.registry_identity();
            let listed = run_command(&mux, json!({"cmd":"list-workspaces"}));
            let workspace = listed["workspaces"][0]["resource_id"].clone();
            request(
                "sidebar.adopt",
                json!({"refs":[{"session_id":registry_id,"workspace_id":workspace}]}),
                Some("launch-snapshot-adopt"),
            );
            let doc = request("sidebar.get", json!({}), None);
            doc["items"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|item| item["body"]["type"] == "workspace")
                .map(|item| item["id"].clone())
                .expect("the adopted workspace has an item")
        }
    };
    request("sidebar.pin", json!({"items":[item]}), Some("launch-snapshot-pin"));
    let expected = request("sidebar.get", json!({}), None);
    let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
        snapshot["sidebar_doc"]["items"].as_array().is_some_and(|items| {
            items.iter().any(|entry| entry["id"] == item && entry["section"] == "sec_pinned")
        })
    });
    assert_eq!(snapshot["sidebar_doc"], expected, "the snapshot's document is sidebar.get's");

    drop(writer);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_launch_snapshot_carries_frontend_projections() {
    let root = temp_root("projection");
    let mux = Mux::open_persistent("launch-snapshot-projection", SurfaceOptions::default(), &root)
        .unwrap();
    let writer = start_launch_snapshot_writer_with(
        &mux,
        LaunchSnapshotTiming {
            settle: Duration::from_millis(50),
            max_delay: Duration::from_millis(500),
            max_bytes_per_second: u64::MAX,
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
fn cmux_next_launch_snapshot_carries_personal_state() {
    let root = temp_root("personal");
    let mux =
        Mux::open_persistent("launch-snapshot-personal", SurfaceOptions::default(), &root).unwrap();
    let writer = start_launch_snapshot_writer_with(
        &mux,
        LaunchSnapshotTiming {
            settle: Duration::from_millis(50),
            max_delay: Duration::from_millis(500),
            max_bytes_per_second: u64::MAX,
        },
    )
    .unwrap()
    .unwrap();
    wait_for_snapshot(writer.path(), |snapshot| snapshot["personal"].is_object());
    // A personal change alone (no tree change) rewrites the snapshot.
    run_command(
        &mux,
        json!({"cmd":"create-profile","profile":"prof_work","name":"Work",
               "defaults":{"cwd":"/tmp","env":{"TOKEN":"secret"}}}),
    );
    let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
        snapshot["personal"]["profiles"]
            .as_array()
            .is_some_and(|profiles| profiles.iter().any(|profile| profile["id"] == "prof_work"))
    });
    let work = snapshot["personal"]["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .find(|profile| profile["id"] == "prof_work")
        .unwrap();
    assert_eq!(work["defaults"]["cwd"], "/tmp");
    assert!(work["defaults"].get("env").is_none(), "room env stays out of the file");
    // A session's capability list stays out of the file too.
    run_command(
        &mux,
        json!({"cmd":"put-session","session_id":"remote-1","transport":{"kind":"ssh"},
               "capabilities":["profiles-v1"]}),
    );
    let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
        snapshot["personal"]["sessions"].as_array().is_some_and(|sessions| {
            sessions.iter().any(|session| session["session_id"] == "remote-1")
        })
    });
    assert!(
        snapshot["personal"]["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|session| session.get("capabilities").is_none()),
        "session capabilities stay out of the file"
    );
    assert_eq!(
        snapshot["personal"]["personal_revision"],
        run_command(&mux, json!({"cmd":"list-personal"}))["personal_revision"]
    );

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
        // A settle window well above one rename keeps the burst inside it
        // on a loaded runner.
        LaunchSnapshotTiming {
            settle: Duration::from_millis(250),
            max_delay: Duration::from_secs(2),
            max_bytes_per_second: u64::MAX,
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
    // 21 changes settle into a few writes, never one per change. The
    // bound leaves room for a slow runner splitting the burst.
    let burst = writer.writes() - settled;
    assert!(burst <= 5, "writes: {burst} for 21 changes");

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

/// A quit's last save asks for the file at once (`flush-launch-snapshot`):
/// with a settle, delay and byte budget far past the wait, only that request
/// writes the moved window in time, and its answer says it landed. A quick
/// relaunch then draws the move, not the write before it.
#[test]
fn cmux_next_launch_snapshot_flush_writes_at_once_without_waiting_to_settle() {
    let root = temp_root("flush");
    let mux =
        Mux::open_persistent("launch-snapshot-flush", SurfaceOptions::default(), &root).unwrap();
    let writer = start_launch_snapshot_writer_with(
        &mux,
        LaunchSnapshotTiming {
            settle: Duration::from_secs(10),
            max_delay: Duration::from_secs(30),
            max_bytes_per_second: 1,
        },
    )
    .unwrap()
    .unwrap();
    let identify = run_command(&mux, json!({"cmd":"identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == LAUNCH_SNAPSHOT_FLUSH_CAPABILITY)
    );
    // The start write: from here the byte budget alone holds the next one
    // back for (its size / 1) seconds.
    let start = run_command(&mux, json!({"cmd":"flush-launch-snapshot"}));
    assert_eq!(start["flushed"], json!(true));
    let started = read_snapshot(writer.path()).expect("the start write");
    assert!(!workspace_names(&started).contains(&"moved".to_string()));

    let save = |name: &str| {
        run_command(
            &mux,
            json!({
                "cmd":"put-frontend-projection",
                "frontend":"cmux-next",
                "scope":"personal",
                "subject_key":"windows",
                "schema_version":1,
                "projection":{"windows":[{"id":"w1","frame":name}]},
                "origin":"test",
                "mutation_id":format!("launch-snapshot-flush-{name}"),
            }),
        );
    };
    let frame = |snapshot: &Value| {
        snapshot["frontend_projections"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|projection| projection["subject_key"] == "windows")
            .map(|projection| projection["projection"]["windows"][0]["frame"].clone())
    };
    mux.create_empty_workspace(Some("moved".into()), None, None).unwrap();
    save("moved");
    // The normal path waits out its 10 s settle.
    std::thread::sleep(Duration::from_millis(300));
    let lagging = read_snapshot(writer.path()).unwrap();
    assert_eq!(frame(&lagging), frame(&started), "the settle holds the normal write back");

    let asked = Instant::now();
    let reply = run_command(&mux, json!({"cmd":"flush-launch-snapshot"}));
    let took = asked.elapsed();
    assert_eq!(reply["flushed"], json!(true));
    assert!(took < Duration::from_secs(1), "the flush took {took:?}");
    // The file holds the save when the answer comes, with no wait.
    let flushed = read_snapshot(writer.path()).unwrap();
    assert_eq!(frame(&flushed), Some(json!("moved")));
    assert!(workspace_names(&flushed).contains(&"moved".to_string()));
    // One write a request: a second one with nothing new writes no bytes.
    let bytes = writer.bytes_written();
    assert_eq!(run_command(&mux, json!({"cmd":"flush-launch-snapshot"}))["flushed"], json!(true));
    assert_eq!(writer.bytes_written(), bytes);

    drop(writer);
    // With no writer, the request answers at once.
    assert_eq!(run_command(&mux, json!({"cmd":"flush-launch-snapshot"}))["flushed"], json!(false));
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// The app quits, is force quit, crashes or is killed right after a window
/// record save, and sends nothing more: its socket closes. That close
/// writes the snapshot at once, so a relaunch draws the save. The close of
/// a connection that wrote no native projection (a CLI call) waits as before.
#[test]
fn cmux_next_launch_snapshot_writes_at_once_when_the_app_connection_closes() {
    let root = temp_root("app-close");
    let mux = Mux::open_persistent("launch-snapshot-app-close", SurfaceOptions::default(), &root)
        .unwrap();
    let writer = start_launch_snapshot_writer_with(
        &mux,
        LaunchSnapshotTiming {
            settle: Duration::from_secs(10),
            max_delay: Duration::from_secs(30),
            max_bytes_per_second: 1,
        },
    )
    .unwrap()
    .unwrap();
    // The start write; the byte budget alone then holds the next one back.
    assert_eq!(run_command(&mux, json!({"cmd":"flush-launch-snapshot"}))["flushed"], json!(true));
    let frame = |snapshot: &Value| {
        snapshot["frontend_projections"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|projection| projection["subject_key"] == "windows")
            .map(|projection| projection["projection"]["windows"][0]["frame"].clone())
    };
    let started = frame(&read_snapshot(writer.path()).unwrap());
    assert_eq!(started, None);

    const APP: u64 = 41;
    const CLI: u64 = 42;
    run_command_as(
        &mux,
        APP,
        json!({
            "cmd":"put-frontend-projection",
            "frontend":"cmux-next",
            "scope":"personal",
            "subject_key":"windows",
            "schema_version":1,
            "projection":{"windows":[{"id":"w1","frame":"moved"}]},
            "origin":"test",
            "mutation_id":"launch-snapshot-app-close",
        }),
    );
    run_command_as(&mux, CLI, json!({"cmd":"ping"}));
    // Another connection's close writes nothing early.
    assert!(disconnect_client(&mux, CLI, false));
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(frame(&read_snapshot(writer.path()).unwrap()), started);

    let closed = Instant::now();
    assert!(disconnect_client(&mux, APP, false));
    let deadline = closed + Duration::from_secs(1);
    loop {
        if frame(&read_snapshot(writer.path()).unwrap()) == Some(json!("moved")) {
            break;
        }
        assert!(Instant::now() < deadline, "the app's close did not write the snapshot in 1 s");
        std::thread::sleep(Duration::from_millis(10));
    }

    drop(writer);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

fn run_command(mux: &Arc<Mux>, request: Value) -> Value {
    run_command_as(mux, 0, request)
}

fn run_command_as(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(client), command, &writer).unwrap()
}
