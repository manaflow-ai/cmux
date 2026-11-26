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
        prompt_suggestions: None,
        tool_servers: String::new(),
        settings_file: PathBuf::new(),
        model: None,
        effort: None,
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

/// A credentialed start (cmux#45953) misses an entry of its slot under another key and leaves it:
/// the folder's uncredentialed spare outlives a Cloud chat's start, which a plain start still takes.
#[test]
fn a_start_that_keeps_other_keys_leaves_the_slots_entry_for_its_own_start() {
    let mut pool: Pool<&'static str> = Pool::new(IDLE);
    let plain = key("/w", "claude");
    let now = Duration::from_secs(1);
    let generation = pool.want(Role::Spare, plain.clone(), now).start.expect("a start");
    assert!(pool.complete(&plain, generation, "spare", now).is_none());
    let credentialed = PoolKey { auth: "credentialed".into(), ..plain.clone() };
    assert!(matches!(pool.take_or_keep(&credentialed, false), Take::Miss));
    assert_eq!(cwds(&pool), vec!["/w".to_owned()]);
    assert!(matches!(pool.take(&plain), Take::Ready("spare")));
}

#[test]
fn a_reserved_entry_is_served_once_and_never_refilled_as_a_spare() {
    let mut pool = Pool::new(IDLE);
    pool.set_spare_idle(IDLE * 6);
    let r = key("/chats/r1", "claude");
    let now = Duration::from_secs(1);
    let wanted = pool.want(Role::Reserved, r.clone(), now);
    let generation = wanted.start.expect("a start for a new key");
    assert!(pool.complete(&r, generation, "reserved", now).is_none());
    assert!(!pool.has_spare("claude"), "a reserved entry is not the harness's spare");
    assert!(pool.empty_spares().is_empty());
    assert!(pool.expire(IDLE * 2).is_empty(), "a reserved entry waits the spare's time");
    assert!(matches!(pool.take(&r), Take::Ready("reserved")));
    assert!(matches!(pool.take(&r), Take::Miss), "the second chat finds nothing");
    assert!(pool.empty_spares().is_empty(), "a taken reserved entry is not refilled");
}

#[test]
fn a_reserved_entry_neither_moves_nor_is_moved_by_a_spare() {
    let mut pool = Pool::new(IDLE);
    let r = key("/chats/r1", "claude");
    let now = Duration::from_secs(1);
    let generation = pool.want(Role::Reserved, r.clone(), now).start.unwrap();
    assert!(pool.complete(&r, generation, "reserved", now).is_none());
    let evicted = spare_ready(&mut pool, key("/b", "claude"), 2, "spare");
    assert!(evicted.is_empty());
    assert_eq!(cwds(&pool), vec!["/chats/r1", "/b"]);
}

/// A spare of the reserved entry's harness in its folder, on another model or without the
/// credential the reserve named, is a new key for an occupied slot: wanted, it ended the reserved
/// entry, and the home chat the reserve was made for started cold. The pool says so first.
#[test]
fn the_reserved_entrys_slot_is_told_from_a_spare_of_another_key() {
    let mut pool = Pool::new(IDLE);
    let r = key("/chats/r1", "claude");
    let now = Duration::from_secs(1);
    let generation = pool.want(Role::Reserved, r.clone(), now).start.unwrap();
    assert!(pool.complete(&r, generation, "reserved", now).is_none());
    let mut other_model = r.clone();
    other_model.model = Some("claude-opus-5-5".into());
    let mut other_login = r.clone();
    other_login.auth = "another".into();
    assert!(pool.reserved_under_another_key(&other_model));
    assert!(pool.reserved_under_another_key(&other_login));
    assert!(!pool.reserved_under_another_key(&r), "its own key is the entry itself");
    assert!(!pool.reserved_under_another_key(&key("/chats/r1", "codex")), "another harness");
    assert!(!pool.reserved_under_another_key(&key("/b", "claude")), "another folder");
    // A spare may finish resolving its shape after the reservation was installed.
    // The pool must reject it at mutation time, even without a caller-side check.
    for key in [other_model.clone(), other_login] {
        let attempt = pool.want(Role::Spare, key, now);
        assert!(attempt.evicted.is_empty());
        assert!(attempt.start.is_none());
    }
    assert!(matches!(pool.take(&r), Take::Ready("reserved")));
    pool.end_reserved(&r);
    assert!(!pool.reserved_under_another_key(&other_model));
}

#[test]
fn a_taken_reserved_entry_is_reserved_no_more_and_leaves_room_for_the_next_folder() {
    let mut pool = Pool::new(IDLE);
    pool.set_spare_idle(IDLE * 6);
    let r1 = key("/chats/r1", "claude");
    let now = Duration::from_secs(1);
    let generation = pool.want(Role::Reserved, r1.clone(), now).start.unwrap();
    assert!(pool.complete(&r1, generation, "first", now).is_none());
    assert!(matches!(pool.take(&r1), Take::Ready("first")));
    let (reserved, ended) = pool.end_reserved(&r1);
    assert!(reserved && ended.is_empty());
    assert!(cwds(&pool).is_empty(), "the taken folder is the chat's, not the pool's");
    assert_eq!(pool.end_reserved(&r1), (false, Vec::new()), "a plain take is no reserved take");
    // The refill wants the next folder, which warms and serves the next chat.
    let r2 = key("/chats/r2", "claude");
    let generation = pool.want(Role::Reserved, r2.clone(), now).start.expect("a start");
    assert!(pool.complete(&r2, generation, "second", now).is_none());
    assert!(matches!(pool.take(&r2), Take::Ready("second")));
}
