use super::*;

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

#[test]
fn one_hour_fills_all_three() {
    let mut e = env(&[("ANTHROPIC_BASE_URL", "https://router.example")]);
    apply(&mut e, PromptCache::OneHour);
    assert_eq!(e.get(TTL_ENV).map(String::as_str), Some("1h"));
    assert_eq!(e.get(SUBAGENT_TTL_ENV).map(String::as_str), Some("1h"));
    assert_eq!(e.get(ONE_HOUR_ENV).map(String::as_str), Some("1"));
}

#[test]
fn profile_values_win() {
    let mut e = env(&[(TTL_ENV, "5m"), (SUBAGENT_TTL_ENV, "5m")]);
    apply(&mut e, PromptCache::OneHour);
    assert_eq!(e[TTL_ENV], "5m");
    assert_eq!(e[SUBAGENT_TTL_ENV], "5m");
    assert_eq!(e[ONE_HOUR_ENV], "1");
}

#[test]
fn force_five_minutes_sets_nothing() {
    let mut e = env(&[(FORCE_5M_ENV, "1")]);
    apply(&mut e, PromptCache::OneHour);
    assert_eq!(e, env(&[(FORCE_5M_ENV, "1")]));
}

#[test]
fn force_off_values_do_not_count() {
    for off in ["", "0", " 0 "] {
        let mut e = env(&[(FORCE_5M_ENV, off)]);
        apply(&mut e, PromptCache::OneHour);
        assert_eq!(e.get(TTL_ENV).map(String::as_str), Some("1h"), "{off:?}");
    }
}

#[test]
fn five_minutes_setting() {
    let mut e = BTreeMap::new();
    apply(&mut e, PromptCache::FiveMinutes);
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
