//! A person's chat takes the warm spare its folder has (gui-chat-harness-bench, 2026-11-25: the
//! second chat in a folder started cold, 6.8 s against ~2 s, the daemon logging "pooled session
//! discarded: its key changed"). The chat's spawn env carried the sr2 person mark
//! (`sr2_priority::mark`) and the spare's did not, and the key hashed the whole env.

use super::*;
use std::collections::BTreeMap;

fn env(person: bool) -> BTreeMap<String, String> {
    let mut e = BTreeMap::from([
        ("CLAUDE_CODE_PROMPT_CACHE_TTL".to_owned(), "1h".to_owned()),
        ("ENABLE_TOOL_SEARCH".to_owned(), "true".to_owned()),
    ]);
    crate::sr2_priority::mark(&mut e, person);
    e
}

fn hashed(env: &BTreeMap<String, String>) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    key_env(env).hash(&mut h);
    h.finish()
}

fn key(auth: &str) -> PoolKey {
    PoolKey {
        origin: Origin::Local,
        cwd: PathBuf::from("/a"),
        harness: "claude".into(),
        preset: None,
        args: Vec::new(),
        system_prompt_sha256: None,
        auth: auth.into(),
        account: None,
        machine: None,
        prompt_suggestions: None,
        tool_servers: String::new(),
        settings_file: PathBuf::new(),
        model: Some("haiku".into()),
        effort: None,
    }
}

#[test]
fn the_person_mark_never_splits_a_key() {
    assert!(env(true).contains_key(crate::sr2_priority::PERSON_ENV));
    assert_eq!(hashed(&env(true)), hashed(&env(false)));
}

#[test]
fn any_other_env_change_still_does() {
    let mut other = env(true);
    other.insert("CLAUDE_CODE_PROMPT_CACHE_TTL".into(), "5m".into());
    assert_ne!(hashed(&env(true)), hashed(&other));
}

fn spare_ready(pool: &mut Pool<&'static str>, key: &PoolKey) {
    let wanted = pool.want(Role::Spare, key.clone(), Duration::ZERO);
    let generation = wanted.start.expect("a start for a new key");
    assert!(pool.complete(key, generation, "warm", Duration::ZERO).is_none());
}

#[test]
fn a_persons_chat_takes_the_spare_and_a_discard_names_what_differed() {
    let auth = |e| format!("{:016x}", hashed(&e));
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    // The spare as `pool_spec_in` drafts it (the person's) and a person's chat: one key.
    spare_ready(&mut pool, &key(&auth(env(true))));
    assert!(matches!(pool.take_or_keep(&key(&auth(env(true))), true), Take::Ready("warm")));
    // Before: the spare drafted with no creator, the chat the person's.
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    spare_ready(&mut pool, &key(&auth(env(false))));
    assert!(matches!(pool.take_or_keep(&key(&auth(env(true))), true), Take::Ready("warm")));
    // A chat on another model: the spare is discarded and the log names `model`.
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    spare_ready(&mut pool, &key(&auth(env(true))));
    let other = PoolKey { model: Some("opus".into()), ..key(&auth(env(true))) };
    match pool.take_or_keep(&other, true) {
        Take::Discard(Some("warm"), fields) => assert_eq!(fields, ["model"]),
        _ => panic!("a chat on another model took or kept the spare"),
    }
}
