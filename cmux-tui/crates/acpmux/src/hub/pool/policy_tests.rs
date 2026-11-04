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
        machine: None,
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

/// Want a spare for `key` at `at` seconds and have its start finish with `session`.
fn spare_ready(
    pool: &mut Pool<&'static str>,
    key: PoolKey,
    at: u64,
    session: &'static str,
) -> Vec<&'static str> {
    let now = Duration::from_secs(at);
    let wanted = pool.want(Role::Spare, key.clone(), now);
    let generation = wanted.start.expect("a start for a new key");
    assert!(pool.complete(&key, generation, session, now).is_none());
    wanted.evicted
}

#[test]
fn a_harness_keeps_one_spare_and_a_newer_session_elsewhere_moves_it() {
    let mut pool = Pool::new(IDLE);
    assert!(spare_ready(&mut pool, key("/a", "claude"), 1, "claude-a").is_empty());
    assert!(spare_ready(&mut pool, key("/a", "codex"), 2, "codex-a").is_empty());
    let evicted = spare_ready(&mut pool, key("/b", "claude"), 3, "claude-b");
    assert_eq!(evicted, vec!["claude-a"]);
    assert_eq!(cwds(&pool), vec!["/a", "/b"]);
}

#[test]
fn a_taken_spare_is_refilled_by_the_next_want_of_its_key() {
    let mut pool = Pool::new(IDLE);
    let a = key("/a", "claude");
    spare_ready(&mut pool, a.clone(), 1, "claude-1");
    assert!(matches!(pool.take(&a), Take::Ready("claude-1")));
    assert_eq!(pool.empty_spares(), vec![a.clone()]);
    // The session that took it was created: its shape is wanted again.
    let again = pool.want(Role::Spare, a.clone(), Duration::from_secs(2));
    assert!(again.start.is_some(), "the taken spare starts again");
    assert!(pool.empty_spares().is_empty());
}

#[test]
fn a_spare_waits_its_own_idle_time_and_a_shorter_role_never_shortens_it() {
    let mut pool = Pool::new(IDLE);
    pool.set_spare_idle(IDLE * 6);
    let a = key("/a", "claude");
    spare_ready(&mut pool, a.clone(), 0, "claude-a");
    pool.want(Role::LastUsed, a.clone(), Duration::from_secs(1));
    assert!(pool.expire(IDLE * 2).is_empty(), "a spare outlives the pool's idle time");
    assert_eq!(pool.expire(IDLE * 6 + Duration::from_secs(1)), vec!["claude-a"]);
}

#[test]
fn a_last_used_entry_the_spare_moved_off_waits_only_the_pool_idle_time() {
    let mut pool = Pool::new(IDLE);
    pool.set_spare_idle(IDLE * 6);
    let a = key("/a", "claude");
    spare_ready(&mut pool, a.clone(), 0, "claude-a");
    pool.want(Role::LastUsed, a.clone(), Duration::ZERO);
    // A newer session of the harness elsewhere takes the spare role.
    pool.want(Role::Spare, key("/b", "claude"), Duration::from_secs(1));
    let kept = pool.view().into_iter().find(|v| v.key == a).expect("still last used");
    assert!(kept.last_used && !kept.spare, "{kept:?}");
    assert_eq!(pool.expire(IDLE + Duration::from_secs(1)), vec!["claude-a"]);
}

#[test]
fn a_spare_outlives_a_last_used_role_moving_away_in_its_folder() {
    let mut pool = Pool::new(IDLE);
    let a = key("/a", "claude");
    spare_ready(&mut pool, a.clone(), 1, "claude-a");
    pool.want(Role::LastUsed, a.clone(), Duration::from_secs(1));
    pool.want(Role::LastUsed, key("/a", "codex"), Duration::from_secs(2));
    let view = pool.view();
    let kept = view.iter().find(|v| v.key == a).expect("the spare stays");
    assert!(kept.spare && !kept.last_used, "{kept:?}");
}
