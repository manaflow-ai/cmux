//! The lock-scope lints of `[workspace.lints.clippy]` (cmux-tui/Cargo.toml) fire on the shapes
//! of past daemon fixes where a lock was held across slow work, so a reintroduced one shows up in
//! the clippy run that already lints this workspace.
//!
//! Each `*_pre_fix` function below is the shape before a fix, reduced to std. Its
//! `#[expect(clippy::...)]` is the proof: if the lint stopped firing on that shape (a clippy
//! upgrade, a lint dropped from the workspace table), `unfulfilled_lint_expectations` makes the
//! `-D warnings` clippy run red. The `*_fixed` twin is the shape after the fix and must stay clean.

use std::collections::HashMap;
use std::io::{self, Write};
use std::sync::Mutex;

#[derive(Default)]
struct Session {
    catalog: HashMap<String, String>,
    revision: u64,
}

/// The registry write the lock was held across: in the daemon a SQLite commit with its WAL
/// write, here any write.
fn commit_to_registry(out: &mut impl Write, value: &str) -> io::Result<u64> {
    out.write_all(value.as_bytes())?;
    out.flush()?;
    Ok(value.len() as u64)
}

/// #32326 (TUL-F7) terminal progress before the fix: the session lock taken for one catalog
/// read, then held across the registry commit and dropped only after the revision write.
fn progress_pre_fix(session: &Mutex<Session>, out: &mut impl Write, id: &str) -> io::Result<()> {
    let mut state = session.lock().unwrap();
    let Some(current) = state.catalog.get(id).cloned() else { return Ok(()) };
    let revision = commit_to_registry(out, &current)?;
    state.revision = revision;
    drop(state);
    Ok(())
}

/// The same lookup held to the end of its scope with no later use: the general "held only for
/// the read" shape.
fn read_then_write_pre_fix(session: &Mutex<Session>, out: &mut impl Write, id: &str) -> io::Result<u64> {
    let state = session.lock().unwrap();
    let current = state.catalog.get(id).cloned().unwrap_or_default();
    commit_to_registry(out, &current)
}

/// After the fix: the guard lives only for the read.
fn read_then_write_fixed(session: &Mutex<Session>, out: &mut impl Write, id: &str) -> io::Result<u64> {
    let current = session.lock().unwrap().catalog.get(id).cloned().unwrap_or_default();
    commit_to_registry(out, &current)
}

/// A `match` on a locked read: the guard is a temporary of the scrutinee and lives through
/// every arm, so the write in the arm runs under the lock.
fn match_on_locked_pre_fix(session: &Mutex<Session>, out: &mut impl Write, id: &str) -> io::Result<u64> {
    match session.lock().unwrap().catalog.get(id) {
        Some(current) => commit_to_registry(out, current),
        None => Ok(0),
    }
}

/// An async handler awaiting with a std guard alive: every other locker blocks its thread
/// until the future is polled again.
async fn await_holding_pre_fix(session: &Mutex<Session>, id: &str) -> usize {
    let state = session.lock().unwrap();
    let len = state.catalog.get(id).map_or(0, String::len);
    std::future::ready(()).await;
    len + state.catalog.len()
}

#[test]
fn lock_scope_shapes_still_run() {
    let session = Mutex::new(Session::default());
    session.lock().unwrap().catalog.insert("t1".into(), "value".into());
    let mut out = Vec::new();
    progress_pre_fix(&session, &mut out, "t1").unwrap();
    assert_eq!(session.lock().unwrap().revision, 5);
    assert_eq!(read_then_write_pre_fix(&session, &mut out, "t1").unwrap(), 5);
    assert_eq!(read_then_write_fixed(&session, &mut out, "t1").unwrap(), 5);
    assert_eq!(match_on_locked_pre_fix(&session, &mut out, "t1").unwrap(), 5);
    let _ = await_holding_pre_fix(&session, "t1");
}
