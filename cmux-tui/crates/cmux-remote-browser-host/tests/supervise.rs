//! The shared remote browser host's supervisor (src/supervise.rs): one host
//! serves every tab, and a host that dies takes no tab with it.
//!
//! The pure rule runs with an injected clock; tests/shared_host_crash.rs runs
//! the process.

use std::path::Path;

use std::time::{Duration, Instant};

use cmux_remote_browser_host::supervise::{Action, Policy, Supervisor};
use serde_json::{Value, json};

fn policy() -> Policy {
    Policy { backoff: Duration::from_millis(250), window: Duration::from_secs(60) }
}

fn open(s: &mut Supervisor, id: &str, url: &str) -> Vec<Action> {
    let line = json!({"open": {"tab": id, "url": url}}).to_string();
    s.app_line(&line, || format!("token-{id}"))
}

fn spawned(actions: &[Action]) -> Option<(u64, Vec<Value>)> {
    actions.iter().find_map(|a| match a {
        Action::Spawn { generation, lines } => Some((
            *generation,
            lines.iter().map(|l| serde_json::from_str(l).expect("json")).collect(),
        )),
        _ => None,
    })
}

#[test]
fn three_tabs_share_one_host_and_each_has_its_own_cache_dir() {
    let mut s = Supervisor::new(Path::new("/r"), policy());
    let first = open(&mut s, "a", "https://a.test/");
    let (generation, lines) = spawned(&first).expect("the first tab starts the host");
    assert_eq!(generation, 1);
    assert_eq!(lines.last(), Some(&json!({"serve": true})));
    let second = open(&mut s, "b", "https://b.test/");
    let third = open(&mut s, "c", "https://c.test/");
    assert!(spawned(&second).is_none() && spawned(&third).is_none(), "one host for all tabs");
    assert!(second.iter().any(|a| matches!(a, Action::ToHost(l) if l.contains("\"b\""))));
    let dirs: Vec<_> = s.tabs().map(|t| t.cache.clone()).collect();
    assert_eq!(dirs.len(), 3);
    // Directly under the root: Chrome makes a profile only there.
    assert!(dirs.iter().all(|d| d.parent() == Some(Path::new("/r"))), "{dirs:?}");
    let mut unique = dirs.clone();
    unique.dedup();
    assert_eq!(unique.len(), 3, "every tab has its own request context directory: {dirs:?}");
}

#[test]
fn a_crashed_host_restarts_with_every_tab_at_its_last_url() {
    let t0 = Instant::now();
    let mut s = Supervisor::new(Path::new("/r"), policy());
    open(&mut s, "a", "https://a.test/");
    open(&mut s, "b", "https://b.test/");
    // The token goes to the app once the host knows the tab.
    let ready = s.host_line(1, r#"{"tab":"a","ready":true}"#);
    assert!(ready.iter().any(|a| matches!(a, Action::ToApp(l) if l.contains("token-a"))));
    s.host_line(1, r#"{"tab":"b","url":"https://b.test/moved"}"#);
    assert!(s.host_ended(1, t0).is_empty());
    assert!(s.tick(t0 + Duration::from_millis(100)).is_empty(), "the backoff waits");
    let (generation, lines) =
        spawned(&s.tick(t0 + Duration::from_millis(300))).expect("a new host starts");
    assert_eq!(generation, 2);
    let opens: Vec<(&str, &str, &str)> = lines
        .iter()
        .filter_map(|l| l.get("open"))
        .map(|o| {
            (o["tab"].as_str().unwrap(), o["url"].as_str().unwrap(), o["token"].as_str().unwrap())
        })
        .collect();
    assert_eq!(
        opens,
        vec![("a", "https://a.test/", "token-a"), ("b", "https://b.test/moved", "token-b")],
        "every tab, at its last URL, under the token its viewer already holds"
    );
    // A line from the dead host is ignored.
    assert!(s.host_line(1, r#"{"tab":"a","url":"https://stale/"}"#).is_empty());
    assert_eq!(s.generation(), Some(2));
}

#[test]
fn a_second_end_within_the_window_stays_down_until_a_tab_opens() {
    let t0 = Instant::now();
    let mut s = Supervisor::new(Path::new("/r"), policy());
    open(&mut s, "a", "https://a.test/");
    s.host_ended(1, t0);
    spawned(&s.tick(t0 + Duration::from_secs(1))).expect("restart");
    let down = s.host_ended(2, t0 + Duration::from_secs(30));
    assert!(down.iter().any(|a| matches!(a, Action::ToApp(l) if l.contains("\"down\""))));
    assert_eq!(s.deadline(), None, "no restart is pending");
    assert!(s.tick(t0 + Duration::from_secs(120)).is_empty());
    assert_eq!(s.tabs().count(), 1, "the tab's record is kept");
    let reopened = open(&mut s, "b", "https://b.test/");
    let (_, lines) = spawned(&reopened).expect("a new tab starts a host with every tab");
    assert_eq!(lines.iter().filter(|l| l.get("open").is_some()).count(), 2);
}

#[test]
fn an_end_after_the_window_restarts_again() {
    let t0 = Instant::now();
    let mut s = Supervisor::new(Path::new("/r"), policy());
    open(&mut s, "a", "https://a.test/");
    s.host_ended(1, t0);
    s.tick(t0 + Duration::from_secs(1));
    s.host_ended(2, t0 + Duration::from_secs(61));
    assert!(spawned(&s.tick(t0 + Duration::from_secs(62))).is_some());
}

#[test]
fn a_closed_tab_leaves_its_directory_to_the_host_then_removes_it() {
    let mut s = Supervisor::new(Path::new("/r"), policy());
    open(&mut s, "a", "https://a.test/");
    let dir = s.tabs().next().unwrap().cache.clone();
    let close = s.app_line(r#"{"close":{"tab":"a"}}"#, String::new);
    assert_eq!(close, vec![Action::ToHost(r#"{"close":{"tab":"a"}}"#.into())]);
    let closed = s.host_line(1, r#"{"tab":"a","closed":true}"#);
    assert_eq!(closed[0], Action::RemoveDir(dir));
    assert_eq!(s.tabs().count(), 0);
}
