//! The search-everything index end to end in the daemon (`search-v1`,
//! plans/cmux-next/search-everything-DESIGN.md): terminal output that
//! scrolled off, a full-screen program's frame and workspace names are
//! found by one query.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
mod support;
use cmux_search::{Hit, Kind, Query};
use cmux_tui_core::{Mux, SurfaceOptions};
use support::{DaemonMuxOps, wait_for};

fn shell_opts(script: &str) -> SurfaceOptions {
    SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), script.to_string()]),
        ..Default::default()
    }
}

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
}

fn find(mux: &std::sync::Arc<Mux>, text: &str, kind: Kind, snippet: &str) -> Option<Hit> {
    let mut query = Query::new(text, now_ms());
    query.limit = 200;
    mux.search_everything(&query)
        .hits
        .into_iter()
        .find(|hit| hit.kind == kind && hit.snippet.contains(snippet))
}

#[test]
fn search_everything_finds_terminal_lines_that_scrolled_off_the_screen() {
    let script =
        "i=1; while [ $i -le 200 ]; do echo \"line $i scrollneedle$i\"; i=$((i+1)); done; sleep 30";
    let mux = Mux::new(unique_session("test-search-scrollback"), shell_opts(script));
    let surface = mux.new_workspace(None, Some((60, 10))).unwrap();
    let hit = wait_for(
        || find(&mux, "scrollneedle17", Kind::Scrollback, "line 17 scrollneedle17"),
        Duration::from_secs(20),
    );
    let hit = hit.unwrap_or_else(|| panic!("scrollback line 17 never became searchable"));
    assert_eq!(hit.snippet, "line 17 scrollneedle17");
    assert!(!hit.is_name);
    assert!(hit.position.is_some());
    // Each scrolled-off line is indexed once.
    let mut query = Query::new("\"scrollneedle42\"", now_ms());
    query.limit = 200;
    let copies = mux
        .search_everything(&query)
        .hits
        .into_iter()
        .filter(|hit| hit.snippet == "line 42 scrollneedle42")
        .count();
    assert_eq!(copies, 1);
    let _ = mux.close_surface(surface.id);
}

#[test]
fn search_everything_finds_a_full_screen_programs_frame() {
    let script = "printf '\\033[?1049h\\033[H'; printf 'FRAMEALPHA top\\r\\nsecond row\\r\\nthird row\\r\\nfourth row\\r\\n'; sleep 30";
    let mux = Mux::new(unique_session("test-search-screen"), shell_opts(script));
    let surface = mux.new_workspace(None, Some((60, 10))).unwrap();
    let hit = wait_for(
        || find(&mux, "framealpha", Kind::Screen, "FRAMEALPHA top"),
        Duration::from_secs(20),
    );
    assert!(hit.is_some(), "the alternate screen frame never became searchable");
    let _ = mux.close_surface(surface.id);
}

#[test]
fn search_everything_finds_workspaces_by_name() {
    let mux = Mux::new(unique_session("test-search-names"), shell_opts("sleep 30"));
    let surface = mux.new_workspace(Some("Quokka Lab".into()), Some((60, 10))).unwrap();
    let hit = wait_for(
        || {
            mux.search_everything(&Query::new("quok", now_ms()))
                .hits
                .into_iter()
                .find(|hit| hit.kind == Kind::Workspace)
        },
        Duration::from_secs(10),
    );
    let hit = hit.unwrap_or_else(|| panic!("workspace name never became searchable"));
    assert_eq!(hit.title, "Quokka Lab");
    assert!(hit.is_name);
    assert!(hit.target.starts_with("ws_"), "{}", hit.target);
    let _ = mux.close_surface(surface.id);
}

/// A word that names the place (the workspace) narrows content hits too.
#[test]
fn search_everything_matches_a_terminal_line_by_its_workspace_name() {
    let script =
        "i=1; while [ $i -le 40 ]; do echo \"error: placeneedle $i\"; i=$((i+1)); done; sleep 30";
    let mux = Mux::new(unique_session("test-search-context"), shell_opts(script));
    let surface = mux.new_workspace(Some("Narwhal".into()), Some((60, 10))).unwrap();
    let hit = wait_for(
        || find(&mux, "narwhal placeneedle", Kind::Scrollback, "placeneedle"),
        Duration::from_secs(20),
    );
    assert!(hit.is_some(), "the workspace name never narrowed a scrollback hit");
    let _ = mux.close_surface(surface.id);
}
