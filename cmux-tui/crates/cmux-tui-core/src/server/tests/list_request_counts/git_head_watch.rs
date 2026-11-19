//! The git HEAD cache with its file watch (git_heads.rs): a branch switch reaches clients from
//! the watch of the HEAD file, with no request and no timer; a directory whose HEAD did not
//! change costs no read; and a `list-workspaces` request draws a cached value at once and never
//! waits on a read of the file system.
//!
//! Before the watch, each cached value older than 2 seconds was read again for each client that
//! asked (K directories: K reads each 2 seconds of polling), a request with no `known` read its
//! stale directories on its own thread before it replied, and a branch switch reached a client
//! only once some request asked.

use super::*;

/// A session whose HEAD cache watches the HEAD files of its directories, as in a daemon.
fn watched(name: &str, workspaces: usize) -> Session {
    Session::of(name, workspaces)
}

/// Waits for the next `list-workspaces` reply with no `known` that has `branch` `count` times.
fn wait_for_branch(app: &Connection, mux: &Arc<Mux>, branch: &str, count: usize) -> bool {
    let field = format!("\"git_branch\":\"{branch}\"");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if app.list(mux).matches(&field).count() == count {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

/// A branch switched in a terminal's repository reaches a client that takes events, from the
/// watch of the HEAD file: no request asks, and no cached value is past any lifetime.
#[test]
fn a_branch_switch_reaches_clients_from_the_head_watch_with_no_request() {
    let session = watched("git-watch-push", 2);
    let mux = &session.mux;
    let (moving, still) =
        (session.repository("moving", "main"), session.repository("still", "main"));
    session.give_directories(&[moving.clone(), still]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let first = app.list(mux);
    assert_eq!(first.matches("\"git_branch\":\"main\"").count(), 2, "{}", start_of(&first));
    // The refresh that the first reply started watches each repository's HEAD.
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
    let events = mux.subscribe();

    set_branch(&moving, "next");
    let mut told = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while told.is_empty() && Instant::now() < deadline {
        told.extend(changed_tabs_on_branch(&events, "next"));
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        told,
        vec![(session.surfaces[0], true)],
        "after a branch switch in the repository of terminal 0, with no request: the \
         `tab-changed` events (each with whether it has the new branch)"
    );
    session.end();
}

/// K directories whose HEAD does not change, polled by a client with `known` as the sidebar
/// does: each poll past the old 2 second lifetime read every directory again (K reads each
/// 2 seconds, 30 K a minute). With the watch, an idle directory is read again only after the
/// long safety lifetime (git_heads.rs): no read in 45 seconds of polls.
#[test]
fn idle_watched_directories_cost_no_git_head_reads() {
    const K: usize = 8;
    const POLLS: usize = 15;
    let session = watched("git-watch-idle", K);
    let mux = &session.mux;
    session.give_directories(&[
        session.repository("first", "main"),
        session.repository("second", "main"),
    ]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let known = known_of(&app.list_since(mux, &json!({})));
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);

    Mux::watch_git_head_reads_below(&session.root, false);
    for _ in 0..POLLS {
        // Each poll comes past the old lifetime of each cached value (3 seconds later).
        assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
        assert_eq!(app.list_since(mux, &known)["unchanged"], json!(true), "nothing changed");
        wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
    }
    let reads = Mux::watched_git_head_reads();
    assert_eq!(
        reads, 0,
        "{POLLS} polls with `known`, 3 seconds apart, over {K} directories whose HEAD did not \
         change made {reads} git HEAD reads"
    );
    session.end();
}

/// A `list-workspaces` request with no `known` whose directories are all cached replies from the
/// cache at once, stale or not, and reads no HEAD on its thread: here each read is held, and the
/// reply does not wait for one. The refresh behind it brings the new branch, and the next reply
/// has it.
#[test]
fn a_request_with_no_known_tree_draws_cached_heads_and_waits_on_no_read() {
    let session = watched("git-watch-no-wait", 3);
    let mux = &session.mux;
    let moving = session.repository("moving", "main");
    session.give_directories(&[moving.clone(), session.repository("still", "main")]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let first = app.list(mux);
    assert_eq!(first.matches("\"git_branch\":\"main\"").count(), 3, "{}", start_of(&first));
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);

    // Each read below the session's directory waits from now (up to 5 seconds each).
    Mux::watch_git_head_reads_below(&session.root, true);
    set_branch(&moving, "next");
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    let before = Mux::git_head_reads_on_this_thread();
    let started = Instant::now();
    let reply = app.list(mux);
    let elapsed = started.elapsed();
    let reads = Mux::git_head_reads_on_this_thread() - before;
    Mux::watch_git_head_reads_below(&session.root, false);
    eprintln!("list-workspaces with no `known` and stale git HEADs: {elapsed:?}, {reads} reads");
    assert_eq!(reply.matches("\"git_branch\":\"main\"").count(), 3, "{}", start_of(&reply));
    assert_eq!(
        reads, 0,
        "a list-workspaces request with no `known` and 3 cached directories read {reads} git \
         HEADs on its thread (and took {elapsed:?} with each read held)"
    );
    assert!(wait_for_branch(&app, mux, "next", 2), "the refresh brought no new branch");
    session.end();
}
