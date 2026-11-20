//! The lock-scope lints of `[workspace.lints.clippy]` (cmux-tui/Cargo.toml) fire on a guard held
//! across slow work, so a reintroduced one shows up in the clippy run that already lints this
//! workspace (`-D warnings`).
//!
//! Each `*_pre_fix` function is a held-across-await shape reduced to std: the async form of
//! #32326 (TUL-F7), where a status commit held the session lock 452 ms across its registry write
//! and a person's key waited. Its `expect` is the proof: if the lint stopped firing on that shape
//! (a clippy upgrade or rename), `unfulfilled_lint_expectations` turns the clippy run red (plain
//! rustc does not judge clippy's expectations). The `*_fixed` twins are the shapes after the fix
//! and must stay clean.

use std::cell::RefCell;
use std::collections::HashMap;
use std::future::Future;
use std::pin::pin;
use std::sync::Mutex;
use std::task::{Context, Waker};

#[derive(Default)]
struct Session {
    catalog: HashMap<String, String>,
    revision: u64,
}

/// The registry commit the lock was held across: in the daemon a SQLite commit and its WAL
/// write, here any await.
async fn commit_to_registry(value: &str) -> u64 {
    std::future::ready(()).await;
    value.len() as u64
}

#[expect(
    clippy::await_holding_lock,
    reason = "the pre-fix shape this test proves the lint catches"
)]
async fn progress_pre_fix(session: &Mutex<Session>, id: &str) {
    let mut state = session.lock().unwrap();
    let Some(current) = state.catalog.get(id).cloned() else { return };
    let revision = commit_to_registry(&current).await;
    state.revision = revision;
}

/// After the fix: the lock for the read, the commit with no lock, a short second lock for the
/// revision.
async fn progress_fixed(session: &Mutex<Session>, id: &str) {
    let Some(current) = session.lock().unwrap().catalog.get(id).cloned() else { return };
    let revision = commit_to_registry(&current).await;
    session.lock().unwrap().revision = revision;
}

#[expect(
    clippy::await_holding_refcell_ref,
    reason = "the pre-fix shape this test proves the lint catches"
)]
async fn refcell_pre_fix(session: &RefCell<Session>, id: &str) {
    let mut state = session.borrow_mut();
    let Some(current) = state.catalog.get(id).cloned() else { return };
    state.revision = commit_to_registry(&current).await;
}

async fn refcell_fixed(session: &RefCell<Session>, id: &str) {
    let Some(current) = session.borrow().catalog.get(id).cloned() else { return };
    let revision = commit_to_registry(&current).await;
    session.borrow_mut().revision = revision;
}

/// The futures here never wait: one poll finishes each.
fn run<F: Future<Output = ()>>(future: F) {
    let mut future = pin!(future);
    assert!(future.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_ready());
}

#[test]
fn lock_scope_shapes_still_run() {
    let session = Mutex::new(Session::default());
    session.lock().unwrap().catalog.insert("t1".into(), "value".into());
    run(progress_pre_fix(&session, "t1"));
    assert_eq!(session.lock().unwrap().revision, 5);
    session.lock().unwrap().revision = 0;
    run(progress_fixed(&session, "t1"));
    assert_eq!(session.lock().unwrap().revision, 5);

    let cell = RefCell::new(Session::default());
    cell.borrow_mut().catalog.insert("t1".into(), "value".into());
    run(refcell_pre_fix(&cell, "t1"));
    assert_eq!(cell.borrow().revision, 5);
    cell.borrow_mut().revision = 0;
    run(refcell_fixed(&cell, "t1"));
    assert_eq!(cell.borrow().revision, 5);
}
