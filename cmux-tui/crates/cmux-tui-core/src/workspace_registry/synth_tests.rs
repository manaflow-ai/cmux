use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-synth-{label}-{}", super::super::new_uuid_v4()))
}

fn roster_meta(registry: &Path) -> (u32, u64, Value) {
    let connection = Connection::open(registry).unwrap();
    let raw: String = connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}")],
            |row| row.get(0),
        )
        .unwrap();
    let value: Value = serde_json::from_str(&raw).unwrap();
    let snapshot: Value = serde_json::from_str(value["snapshot"].as_str().unwrap()).unwrap();
    (
        u32::try_from(value["version"].as_u64().unwrap()).unwrap(),
        value["cursor"].as_str().unwrap().parse().unwrap(),
        snapshot,
    )
}

/// A small registry of every kind, sealed and one roster version behind:
/// an owner opens it, decodes the sealed and live records, re-folds the
/// roster to the generator's own fold, and keeps the workspaces.
#[test]
fn a_small_synthetic_registry_opens_and_refolds_to_the_same_roster() {
    let root = temp_root("small");
    let options = SynthOptions {
        session: "synth-small".into(),
        session_puts: 300,
        agent_events: 60,
        output_bytes: 40 * OUTPUT_CHUNK_BYTES,
        workspaces: 3,
        seal: true,
        roster_version_bump: true,
        batch_rows: 64,
        ..SynthOptions::default()
    };
    let report = generate(&root, &options).unwrap();
    assert_eq!(report.workspaces.len(), 3);
    assert_eq!((report.session_puts, report.agent_events, report.output_rows), (300, 60, 40));
    assert!(report.segments > 0 && report.sealed_through > 0, "{:?}", report.to_json());
    assert_eq!(report.registry_path, registry_path(&root, "synth-small"));

    let connection = Connection::open(&report.registry_path).unwrap();
    let count = |kind: &str| -> i64 {
        connection
            .query_row("SELECT COUNT(*) FROM session_journal WHERE kind = ?1", [kind], |row| {
                row.get(0)
            })
            .unwrap()
    };
    // Half the rows were sealed, the rest stay live.
    assert!(count("personal.session.put") > 0 && count("personal.session.put") < 300);
    let sealed: i64 = connection
        .query_row("SELECT COALESCE(SUM(record_count), 0) FROM journal_segments", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert!(sealed > 0);
    // A personal.session.put payload is about the asked size.
    let payload: String = connection
        .query_row(
            "SELECT payload_json FROM session_journal WHERE kind = 'personal.session.put' LIMIT 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!((5 * 1024..8 * 1024).contains(&payload.len()), "{}", payload.len());
    drop(connection);

    let (version, cursor, generated) = roster_meta(&report.registry_path);
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION - 1);
    assert_eq!(cursor, report.journal_head);
    assert!(!generated["entries"].as_object().unwrap().is_empty(), "{generated}");

    let mux = crate::Mux::open_persistent("synth-small", crate::SurfaceOptions::default(), &root)
        .unwrap();
    let names = mux
        .workspace_registry
        .lock()
        .unwrap()
        .snapshot()
        .unwrap()
        .workspaces
        .into_iter()
        .filter(|workspace| workspace.name.starts_with("synth "))
        .count();
    mux.shutdown();
    drop(mux);
    assert_eq!(names, 3);
    let (version, cursor, refolded) = roster_meta(&report.registry_path);
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION);
    assert!(cursor >= report.journal_head);
    assert_eq!(refolded["entries"], generated["entries"]);
    assert_eq!(refolded["hook_fences"], generated["hook_fences"]);
    let _ = std::fs::remove_dir_all(root);
}

/// Bumping an existing registry sets only the roster version one behind,
/// as the generator's own bump writes it; a registry without a roster
/// snapshot is left alone.
#[test]
fn bumping_an_existing_registry_keeps_its_roster_cursor_and_snapshot() {
    let root = temp_root("bump");
    let options = SynthOptions {
        session: "synth-bump".into(),
        session_puts: 40,
        agent_events: 20,
        workspaces: 1,
        batch_rows: 16,
        ..SynthOptions::default()
    };
    let report = generate(&root, &options).unwrap();
    let (version, cursor, snapshot) = roster_meta(&report.registry_path);
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION);

    assert_eq!(bump_roster_version(&report.registry_path).unwrap(), Some(version));
    let (bumped, bumped_cursor, bumped_snapshot) = roster_meta(&report.registry_path);
    assert_eq!(bumped, AGENT_ROSTER_REDUCER_VERSION - 1);
    assert_eq!((bumped_cursor, bumped_snapshot), (cursor, snapshot));

    Connection::open(&report.registry_path)
        .unwrap()
        .execute(
            "DELETE FROM meta WHERE key = ?1",
            [format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}")],
        )
        .unwrap();
    assert_eq!(bump_roster_version(&report.registry_path).unwrap(), None);
    let _ = std::fs::remove_dir_all(root);
}

/// A registry copied without its state root's pepper does not open in a new
/// root; bound to a new pepper there, it opens with its workspaces.
#[test]
fn a_registry_copied_without_its_pepper_opens_once_rebound() {
    let root = temp_root("pepper-source");
    let options = SynthOptions {
        session: "synth-source".into(),
        session_puts: 20,
        agent_events: 10,
        workspaces: 2,
        batch_rows: 16,
        ..SynthOptions::default()
    };
    let report = generate(&root, &options).unwrap();
    let copy_root = temp_root("pepper-copy");
    let copy = registry_path(&copy_root, "synth-source");
    std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
    std::fs::copy(&report.registry_path, &copy).unwrap();
    let open = || {
        crate::Mux::open_persistent("synth-source", crate::SurfaceOptions::default(), &copy_root)
    };

    let refused = format!("{:#}", open().err().expect("a registry without its pepper opens"));
    assert!(refused.contains("pepper"), "{refused}");
    rebind_resource_pepper(&copy_root, &copy).unwrap();
    let mux = open().unwrap();
    let names = mux
        .workspace_registry
        .lock()
        .unwrap()
        .snapshot()
        .unwrap()
        .workspaces
        .into_iter()
        .filter(|workspace| workspace.name.starts_with("synth "))
        .count();
    mux.shutdown();
    drop(mux);
    assert_eq!(names, 2);
    let _ = std::fs::remove_dir_all(root);
    let _ = std::fs::remove_dir_all(copy_root);
}

/// A chosen number of sealed segments, as a long-lived registry has (about
/// 7,000 at 58.7 GB on 2026-11-09, where half of a synthetic journal of that
/// size seals into about 4,700): the generator seals that many full segments
/// and leaves the rest live.
#[test]
fn the_generator_seals_the_segments_asked_for() {
    let root = temp_root("seal-segments");
    let options = SynthOptions {
        session: "synth-segments".into(),
        session_puts: 4_000,
        agent_events: 100,
        workspaces: 1,
        payload_bytes: 256,
        batch_rows: 1_000,
        seal_segments: Some(3),
        ..SynthOptions::default()
    };
    let report = generate(&root, &options).unwrap();
    assert!((3..=4).contains(&report.segments), "sealed {} segments", report.segments);
    let live = Connection::open(&report.registry_path)
        .unwrap()
        .query_row("SELECT COUNT(*) FROM session_journal", [], |row| row.get::<_, i64>(0))
        .unwrap();
    assert!(live > 0, "the rest of the journal stays live");
    let _ = std::fs::remove_dir_all(root);
}
