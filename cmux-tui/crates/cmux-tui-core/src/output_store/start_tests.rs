//! The start of the output store in a real start of a mux on a file registry: the entries that the start log
//! gets from it. Counts only: no time is compared, and the test waits for nothing.

use std::fs;
use std::io::Write as _;

use super::*;
use crate::mux::ProviderWorkspaceState;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

const SESSION: &str = "store-start-counts";

fn open(root: &Path) -> Arc<Mux> {
    let registry = WorkspaceRegistry::open(root, SESSION).unwrap();
    Mux::from_workspace_registry(
        SESSION.to_owned(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

/// A snapshot file of `terminal` with a header and no replay. Its `written_at_ms` is the largest number, so the
/// file has the age 0 at each clock and the trim leaves it as it is.
fn write_header(directory: &Path, terminal: &TerminalPublicId, stream_end: u64) {
    let header = serde_json::json!({
        "generation": "g", "stream_end": stream_end, "cols": 40, "rows": 5, "written_at_ms": u64::MAX,
    });
    let mut file = fs::File::create(snapshot::path(directory, terminal)).unwrap();
    file.write_all(snapshot::MAGIC).unwrap();
    serde_json::to_writer(&mut file, &header).unwrap();
    file.write_all(b"\n").unwrap();
}

/// A start with parked terminals and snapshot files on disk. The start log gets, in this order: the count of the
/// directory's entries before the scan's entry, the count of the headers that the one scan read, the count of the
/// parked terminals before the trim's entry, and the count of the trim's rewrites. The 4 numbers are different
/// here, so an entry with the number of another entry fails.
#[test]
fn a_start_with_parked_terminals_records_each_count_of_the_output_store() {
    let root = std::env::temp_dir()
        .join(format!("cmux-store-start-counts-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open(&root);
    let tabs: Vec<_> = (0..4)
        .map(|index| mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap().id)
        .collect();
    assert_eq!(mux.park_terminal_tabs(&tabs).unwrap().len(), 4, "setup: each tab is parked");
    let terminals = mux.workspace_registry.lock().unwrap().live_terminal_public_ids().unwrap();
    assert_eq!(terminals.len(), 4, "setup: one terminal of the session for each tab");
    let directory =
        mux.output_store.directory().expect("a file registry has a store").to_path_buf();
    mux.shutdown();
    drop(mux);

    // Only the files of this test are in the store's directory at the second start: 3 snapshot files of parked
    // terminals, and 2 files that are no snapshot file (the list gives them, the scan reads no header of them,
    // and the removal of the files that no terminal owns leaves them: their names are not of a terminal).
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir_all(&directory).unwrap();
    for (stream_end, terminal) in (1_u64..).zip(terminals.iter().take(3)) {
        write_header(&directory, terminal, stream_end);
    }
    fs::write(directory.join("first.note"), b"x").unwrap();
    fs::write(directory.join("second.note"), b"x").unwrap();

    let reopened = open(&root);
    assert!(
        PersistencePolicy::current(&reopened).mode != PersistenceMode::Memory,
        "setup: the store keeps files on disk in this run"
    );
    let laps = reopened.take_startup_timings().expect("a start from a registry has its laps");
    let line = laps.to_line(0, 0);
    let store_entries: Vec<(&str, Option<u64>)> = line["steps"]
        .as_array()
        .expect("the start line has its steps")
        .iter()
        .filter_map(|step| {
            let name = step["step"].as_str()?.strip_prefix("mux.build.output_store.")?;
            Some((name, step["rows"].as_u64()))
        })
        .collect();
    let wanted: [(&str, Option<u64>); 6] = [
        ("prune", None),
        ("directory_entries", Some(5)),
        ("snapshot_scan", Some(3)),
        ("parked_terminals", Some(4)),
        ("parked_trim", Some(0)),
        ("stream_ends", None),
    ];
    assert_eq!(
        store_entries, wanted,
        "(entry, count) of the store's start in the start log, each one time and in this order, for 3 snapshot \
         files and 2 other files on disk and 4 parked terminals with no rewrite"
    );
    reopened.shutdown();
    drop(reopened);
    let _ = fs::remove_dir_all(root);
}
