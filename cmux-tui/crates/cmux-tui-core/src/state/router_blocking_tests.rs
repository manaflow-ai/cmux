//! The state chokepoints as checked scopes: the router's read closure and the
//! commit path reach the registry connection through `#[track_caller]`
//! functions, so a thread that disallows blocking records one `sqlite` site
//! at the code that asked, never in router.rs, commit.rs or the registry.

use std::sync::Arc;

use cmux_threads::blocking::{BlockingKind, BlockingMode, disallow_blocking, set_mode, snapshot};
use serde_json::json;

use crate::state::commit::StateEffects;
use crate::state::store::StateChanges;
use crate::{Mux, SurfaceOptions, WorkspaceMutation};

/// Runs `f` on a request-like thread that disallows blocking and returns
/// what it returns.
fn on_disallowed_thread<R: Send + 'static>(
    mux: &Arc<Mux>,
    f: impl FnOnce(&Mux) -> R + Send + 'static,
) -> R {
    set_mode(BlockingMode::Record);
    let mux = Arc::clone(mux);
    std::thread::Builder::new()
        .name("mux-conn-state-test".into())
        .spawn(move || {
            disallow_blocking();
            f(&mux)
        })
        .expect("spawn")
        .join()
        .expect("test thread")
}

fn sqlite_count_at(line: u32) -> u64 {
    snapshot()
        .site(file!(), line)
        .filter(|site| site.kinds.contains(BlockingKind::Sqlite))
        .map_or(0, |site| site.count)
}

#[test]
fn a_disallowed_router_read_records_one_sqlite_site_at_its_caller() {
    let mux = Mux::new_for_test("blocking-router-read", SurfaceOptions::default());
    let line = on_disallowed_thread(&mux, |mux| {
        let line = line!() + 1;
        super::read(mux, |connection| {
            Ok(connection.query_row("SELECT 1", [], |row| row.get::<_, i64>(0))?)
        })
        .expect("read");
        line
    });
    assert_eq!(sqlite_count_at(line), 1);
}

#[test]
fn a_disallowed_state_commit_records_one_sqlite_site_at_its_caller() {
    let mux = Mux::new_for_test("blocking-commit", SurfaceOptions::default());
    let (replay_line, commit_line) = on_disallowed_thread(&mux, |mux| {
        let mutation =
            WorkspaceMutation::new("blocking-commit-1", "test", crate::Actor::local_user())
                .expect("mutation");
        let fingerprint = json!({"key": "blocking-commit-1"});
        let replay_line = line!() + 1;
        let replay = mux.state_commit_replay(&mutation, "test.blocking", &fingerprint, None);
        assert!(replay.expect("replay").is_none());
        let commit_line = line!() + 1;
        mux.commit_state(
            &mutation,
            "test.blocking",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |_, _| Ok(StateChanges::new(json!({}), Vec::new())),
        )
        .expect("commit");
        (replay_line, commit_line)
    });
    assert_eq!(sqlite_count_at(replay_line), 1);
    assert_eq!(sqlite_count_at(commit_line), 1, "the pin is checked; its re-entries are not");
}

#[test]
fn an_allowed_state_read_records_nothing() {
    set_mode(BlockingMode::Record);
    let mux = Mux::new_for_test("blocking-allowed-state", SurfaceOptions::default());
    let line = line!() + 1;
    super::read(&mux, |_| Ok(())).expect("read");
    assert_eq!(sqlite_count_at(line), 0);
}
