use super::*;

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

#[test]
fn one_hour_fills_all_three() {
    let mut e = env(&[("ANTHROPIC_BASE_URL", "https://router.example")]);
    apply(&mut e, PromptCache::OneHour, &|_| None);
    assert_eq!(e.get(TTL_ENV).map(String::as_str), Some("1h"));
    assert_eq!(e.get(SUBAGENT_TTL_ENV).map(String::as_str), Some("1h"));
    assert_eq!(e.get(ONE_HOUR_ENV).map(String::as_str), Some("1"));
}

#[test]
fn profile_values_win() {
    let mut e = env(&[(TTL_ENV, "5m"), (SUBAGENT_TTL_ENV, "5m")]);
    apply(&mut e, PromptCache::OneHour, &|_| None);
    assert_eq!(e[TTL_ENV], "5m");
    assert_eq!(e[SUBAGENT_TTL_ENV], "5m");
    assert_eq!(e[ONE_HOUR_ENV], "1");
}

#[test]
fn force_five_minutes_sets_nothing() {
    let mut e = env(&[(FORCE_5M_ENV, "1")]);
    apply(&mut e, PromptCache::OneHour, &|_| None);
    assert_eq!(e, env(&[(FORCE_5M_ENV, "1")]));
}

#[test]
fn force_off_values_do_not_count() {
    for off in ["", "0", " 0 "] {
        let mut e = env(&[(FORCE_5M_ENV, off)]);
        apply(&mut e, PromptCache::OneHour, &|_| None);
        assert_eq!(e.get(TTL_ENV).map(String::as_str), Some("1h"), "{off:?}");
    }
}

#[test]
fn five_minutes_setting() {
    let mut e = BTreeMap::new();
    apply(&mut e, PromptCache::FiveMinutes, &|_| None);
    assert_eq!(e.get(TTL_ENV).map(String::as_str), Some("5m"));
    assert_eq!(e.get(SUBAGENT_TTL_ENV).map(String::as_str), Some("5m"));
    assert!(!e.contains_key(ONE_HOUR_ENV));
}

#[test]
fn parse_defaults_to_one_hour() {
    assert_eq!(PromptCache::parse(None), PromptCache::OneHour);
    assert_eq!(PromptCache::parse(Some("1h")), PromptCache::OneHour);
    assert_eq!(PromptCache::parse(Some("bogus")), PromptCache::OneHour);
    assert_eq!(PromptCache::parse(Some("5m")), PromptCache::FiveMinutes);
}

#[test]
fn a_login_shell_value_wins() {
    // `export CLAUDE_CODE_PROMPT_CACHE_TTL=5m` in the login shell reaches the
    // agent after this env is built: acpmux must not cover it.
    let login = |key: &str| (key == TTL_ENV).then(|| "5m".to_owned());
    let mut e = BTreeMap::new();
    apply(&mut e, PromptCache::OneHour, &login);
    assert!(!e.contains_key(TTL_ENV), "{e:?}");
    assert_eq!(e.get(SUBAGENT_TTL_ENV).map(String::as_str), Some("1h"));
    let force = |key: &str| (key == FORCE_5M_ENV).then(|| "1".to_owned());
    let mut e = BTreeMap::new();
    apply(&mut e, PromptCache::OneHour, &force);
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn caching_turned_off_sets_nothing() {
    for key in ["DISABLE_PROMPT_CACHING", "DISABLE_PROMPT_CACHING_OPUS"] {
        let mut e = env(&[(key, "1")]);
        apply(&mut e, PromptCache::OneHour, &|_| None);
        assert_eq!(e, env(&[(key, "1")]), "{key}");
        let mut e = BTreeMap::new();
        apply(&mut e, PromptCache::OneHour, &|k: &str| (k == key).then(|| "1".to_owned()));
        assert!(e.is_empty(), "login {key}: {e:?}");
    }
}
