//! The pool policy with plain values for sessions: the per-harness cap on hinted entries.

use super::*;

const IDLE: Duration = Duration::from_secs(600);

fn key(cwd: &str, harness: &str) -> PoolKey {
    PoolKey {
        origin: Origin::Local,
        cwd: PathBuf::from(cwd),
        harness: harness.to_owned(),
        preset: None,
        args: Vec::new(),
        system_prompt_sha256: None,
        auth: String::new(),
        account: None,
    }
}

/// Hint `key` at `at` seconds and have its start finish with `session`.
fn hint_ready(
    pool: &mut Pool<&'static str>,
    key: PoolKey,
    at: u64,
    session: &'static str,
) -> Vec<&'static str> {
    let now = Duration::from_secs(at);
    let wanted = pool.want(Role::Hinted, key.clone(), now);
    let generation = wanted.start.expect("a start for a new key");
    assert!(pool.complete(&key, generation, session, now).is_none());
    wanted.evicted
}

fn cwds(pool: &Pool<&'static str>) -> Vec<String> {
    pool.view().into_iter().map(|v| v.key.cwd.display().to_string()).collect()
}

#[test]
fn a_hint_in_another_folder_ends_the_older_hinted_entry_of_that_harness() {
    let mut pool = Pool::new(IDLE);
    assert!(hint_ready(&mut pool, key("/a", "claude"), 1, "claude-a").is_empty());
    let evicted = hint_ready(&mut pool, key("/b", "claude"), 2, "claude-b");
    assert_eq!(evicted, vec!["claude-a"]);
    assert_eq!(cwds(&pool), vec!["/b"]);
}

#[test]
fn each_harness_keeps_its_own_hinted_entry() {
    let mut pool = Pool::new(IDLE);
    hint_ready(&mut pool, key("/a", "claude"), 1, "claude-a");
    assert!(hint_ready(&mut pool, key("/b", "codex"), 2, "codex-b").is_empty());
    assert_eq!(cwds(&pool), vec!["/a", "/b"]);
}

#[test]
fn a_last_used_entry_outlives_a_hint_elsewhere_but_loses_its_hint() {
    let mut pool = Pool::new(IDLE);
    let a = key("/a", "claude");
    pool.want(Role::LastUsed, a.clone(), Duration::from_secs(1));
    pool.want(Role::Hinted, a.clone(), Duration::from_secs(1));
    assert!(hint_ready(&mut pool, key("/b", "claude"), 2, "claude-b").is_empty());
    let view = pool.view();
    let kept = view.iter().find(|v| v.key == a).expect("the last-used entry stays");
    assert!(kept.last_used && !kept.hinted, "{kept:?}");
}
