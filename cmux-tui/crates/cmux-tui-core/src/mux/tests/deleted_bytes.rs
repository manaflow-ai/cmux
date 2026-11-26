//! What a person deletes leaves no readable bytes on disk.
//!
//! A SQLite delete only unlinks a row: without `secure_delete` its bytes
//! stay in the freed cell or free page until something reuses it, and in
//! WAL mode every committed page version, the deleted text included, stays
//! in the `-wal` file until the WAL is reset (a passive checkpoint copies
//! the pages back and leaves the old frames). A copy of the state directory
//! (a backup, a support bundle, a stolen disk) would still hold a deleted
//! command line, credential or app value.
//!
//! Each test writes a unique marker through a user-facing write, checks the
//! scan finds it (control), deletes it through the user-facing delete path
//! and scans, byte for byte, the database file, its free pages and its WAL.
//! Every count must be 0.
//!
//! Not covered here, and known to keep the bytes by design: the session and
//! resource journals (append-only, sealed into segments) keep what a closed
//! tab or workspace recorded until their own retention (closed.delete's
//! module doc), and a deleted Chief's create stays in its op ledger for
//! replay (chief_registry.rs `LEDGER_KEYS_PER_ACTOR`).

use super::*;

use crate::shell_history::FinishedCommand;
use crate::state::command_history_store::CommandDeletion;

/// Where a marker was found.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Residue {
    /// Anywhere in the database file (live rows, freed cells, free pages).
    file: usize,
    /// Within the database file's free pages.
    free_pages: usize,
    /// Anywhere in the `-wal` file.
    wal: usize,
}

fn count(haystack: &[u8], needle: &[u8]) -> usize {
    haystack.windows(needle.len()).filter(|window| *window == needle).count()
}

fn be32(bytes: &[u8], at: usize) -> u64 {
    u64::from(u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()))
}

/// The page numbers on the database file's freelist (trunks and leaves),
/// read from the file itself (file format section 1.4).
fn free_pages(file: &[u8]) -> Vec<u64> {
    if file.len() < 100 {
        return Vec::new();
    }
    let page_size = match u16::from_be_bytes([file[16], file[17]]) {
        1 => 65_536,
        size => usize::from(size),
    };
    let pages = (file.len() / page_size) as u64;
    let page = |number: u64| -> Option<&[u8]> {
        let start = usize::try_from(number.checked_sub(1)?).ok()? * page_size;
        file.get(start..start + page_size)
    };
    let mut free = Vec::new();
    let mut trunk = be32(file, 32);
    while trunk != 0 && (free.len() as u64) < pages {
        let Some(bytes) = page(trunk) else { break };
        free.push(trunk);
        let leaves = be32(bytes, 4).min((page_size as u64 - 8) / 4);
        for leaf in 0..leaves {
            free.push(be32(bytes, 8 + 4 * leaf as usize));
        }
        trunk = be32(bytes, 0);
    }
    free.retain(|number| page(*number).is_some());
    free
}

fn residue(database: &Path, marker: &[u8]) -> Residue {
    let file = std::fs::read(database).unwrap_or_default();
    let mut wal_path = database.as_os_str().to_owned();
    wal_path.push("-wal");
    let wal = std::fs::read(Path::new(&wal_path)).unwrap_or_default();
    let page_size = if file.len() >= 100 {
        match u16::from_be_bytes([file[16], file[17]]) {
            1 => 65_536,
            size => usize::from(size),
        }
    } else {
        1
    };
    let free_pages = free_pages(&file)
        .into_iter()
        .map(|number| {
            let start = (number as usize - 1) * page_size;
            count(&file[start..start + page_size], marker)
        })
        .sum();
    Residue { file: count(&file, marker), free_pages, wal: count(&wal, marker) }
}

fn marker(path: &str) -> String {
    format!("cmux-deleted-marker-{path}-{}", crate::workspace_registry::new_uuid_v4())
}

fn state_root(name: &str) -> std::path::PathBuf {
    std::env::temp_dir()
        .join(format!("cmux-deleted-bytes-{name}-{}", crate::workspace_registry::new_uuid_v4()))
}

/// Copies the WAL into the database file (a passive checkpoint, as SQLite's
/// auto-checkpoint does), so the marker sits in the file's pages too and the
/// delete has to scrub the file, not only the WAL; then checks the marker is
/// in both (control).
fn assert_written(path: &str, database: &Path, marker: &[u8]) {
    let connection = rusqlite::Connection::open(database).unwrap();
    connection.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |_| Ok(())).unwrap();
    drop(connection);
    let before = residue(database, marker);
    eprintln!("deleted_bytes: path={path} before_delete={before:?}");
    assert!(before.file > 0, "{path}: control: the marker must be in the database file");
    assert!(before.wal > 0, "{path}: control: the marker must be in the WAL");
}

fn assert_gone(path: &str, after: Residue) {
    eprintln!("deleted_bytes: path={path} after_delete={after:?}");
    assert_eq!(after, Residue::default(), "{path}: deleted bytes are still readable on disk");
}

/// `delete-terminal-commands` (Settings > History, the command palette's
/// clear): the command line was in the registry.
#[cfg(unix)]
#[test]
fn a_deleted_terminal_command_leaves_no_bytes() {
    let root = state_root("command");
    let mux = open_persistent_test_mux("deleted-bytes-command", &root);
    let database = mux.workspace_registry.lock().unwrap().session_journal_database_path().unwrap();
    let marker = marker("terminal-command");
    let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap();
    let command = FinishedCommand {
        command: Some(format!("export TOKEN={marker}")),
        cwd: None,
        exit_code: Some(0),
        started_at_ms: now_ms - 1_000,
        duration_ms: 1,
    };
    mux.workspace_registry
        .lock()
        .unwrap()
        .append_terminal_commands(&[("term_a".to_owned(), command)], now_ms)
        .unwrap();
    assert_written("terminal-command", &database, marker.as_bytes());

    mux.delete_terminal_commands(CommandDeletion::All).unwrap();
    // A reader can block the WAL reset; the worker retries it. Run its
    // retry here instead of waiting for the worker's timer.
    let reset = (0..50).any(|_| {
        let done =
            mux.workspace_registry.lock().unwrap().checkpoint_terminal_command_deletes().unwrap();
        if !done {
            std::thread::sleep(Duration::from_millis(20));
        }
        done
    });
    assert!(reset, "the registry WAL was never reset after the delete");
    assert_gone("terminal-command", residue(&database, marker.as_bytes()));
}

/// `chief.profile.adopt` revokes a participant's credential: its digest
/// was in `conversations.sqlite3`.
#[cfg(unix)]
#[test]
fn a_revoked_agent_token_leaves_no_bytes() {
    let root = state_root("token");
    let mux = open_persistent_test_mux("deleted-bytes-token", &root);
    let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap();
    let participant = cmux_conversation::encode_id("agent_", now_ms, [7_u8; 10]);
    mux.with_conversations(|store| store.mint_agent_token(&participant)).unwrap();
    let database = mux.session_state_directory().unwrap().join("conversations.sqlite3");
    let digest: String = {
        let reader =
            crate::workspace_registry::open_registry_database_read_only(&database).unwrap();
        reader
            .query_row(
                "SELECT token_hash FROM agent_token WHERE participant = ?1",
                [&participant],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert_written("agent-token", &database, digest.as_bytes());

    assert!(mux.claim_unbound_participant(&participant).unwrap());
    assert_gone("agent-token", residue(&database, digest.as_bytes()));
}

/// `app.storage.delete` and an app's uninstall (`clear`): the value was in
/// `apps-storage.sqlite`.
#[cfg(unix)]
#[test]
fn a_deleted_app_storage_value_leaves_no_bytes() {
    use crate::apps::storage::Storage;
    let root = state_root("app-storage");
    std::fs::create_dir_all(&root).unwrap();
    let database = root.join("apps-storage.sqlite");
    let storage = Storage::open(Some(&database)).unwrap();

    let deleted = marker("app-storage-delete");
    storage
        .call("app.a", "app.storage.set", &serde_json::json!({ "key": "secret", "value": deleted }))
        .unwrap();
    storage
        .call(
            "app.a",
            "app.storage.set",
            &serde_json::json!({ "key": "kept", "value": "still here" }),
        )
        .unwrap();
    assert_written("app-storage-delete", &database, deleted.as_bytes());
    storage.call("app.a", "app.storage.delete", &serde_json::json!({ "key": "secret" })).unwrap();
    assert_gone("app-storage-delete", residue(&database, deleted.as_bytes()));
    assert_eq!(
        storage.call("app.a", "app.storage.get", &serde_json::json!({ "key": "kept" })).unwrap(),
        serde_json::json!("still here"),
        "the delete took only the key it named"
    );

    let uninstalled = marker("app-storage-clear");
    storage
        .call(
            "app.b",
            "app.storage.set",
            &serde_json::json!({ "key": "secret", "value": uninstalled }),
        )
        .unwrap();
    assert_written("app-storage-clear", &database, uninstalled.as_bytes());
    storage.clear("app.b").unwrap();
    assert_gone("app-storage-clear", residue(&database, uninstalled.as_bytes()));
}
