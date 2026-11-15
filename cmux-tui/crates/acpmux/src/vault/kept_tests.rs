use std::time::{Duration, Instant};

use super::kept;
use super::store::{MemoryStore, SecretStore, UNAVAILABLE};

const KEY: &str = "r2-synthetic-KEPT-9999";

/// One test at a time touches the loaded kept entries.
static KEPT_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn hosts(list: &[&str]) -> Option<Vec<String>> {
    Some(list.iter().map(|h| (*h).to_owned()).collect())
}

fn given(
    home: &std::path::Path,
    store: &MemoryStore,
    taken: &[String],
) -> Vec<(String, String, Option<Vec<String>>)> {
    let at = Instant::now();
    kept::given_at(home, store, taken, at, at + Duration::from_secs(5))
        .into_iter()
        .map(|g| (g.name, g.value.as_str().to_owned(), g.proxy))
        .collect()
}

#[test]
fn a_kept_key_reaches_spawns_host_locked_and_its_file_never_holds_the_value() {
    let _serial = KEPT_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    kept::reset();
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let allowed = kept::check_hosts(&["*.r2.cloudflarestorage.com".into()]).unwrap();
    kept::keep(home.path(), &store, "R2_TOKEN", KEY, Some(allowed.clone()), &[], 1).unwrap();
    kept::keep(home.path(), &store, "PLAIN", "plain-value", None, &[], 2).unwrap();

    let file = std::fs::read_to_string(kept::path(home.path())).unwrap();
    assert!(!file.contains(KEY) && !file.contains("plain-value"), "a value in {file}");
    assert_eq!(store.get("kept.R2_TOKEN").unwrap().unwrap().as_str(), KEY);

    let got = given(home.path(), &store, &[]);
    assert_eq!(
        got,
        [
            ("PLAIN".to_owned(), "plain-value".to_owned(), None),
            ("R2_TOKEN".to_owned(), KEY.to_owned(), Some(allowed)),
        ]
    );
    // A pulled entry of the same name wins.
    let got = given(home.path(), &store, &["R2_TOKEN".to_owned()]);
    assert_eq!(got.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(), ["PLAIN"]);
}

#[test]
fn proxy_delivery_puts_the_placeholder_in_the_env_not_the_value() {
    let entries = vec![super::Given {
        name: "R2_TOKEN".into(),
        value: zeroize::Zeroizing::new(KEY.into()),
        proxy: hosts(&["example.com"]),
    }];
    let env = super::egress::child_env_with(entries, None, &|_| None);
    assert_eq!(env, [("R2_TOKEN".to_owned(), cmux_vault_egress::placeholder("R2_TOKEN"))]);
}

#[test]
fn an_edited_item_or_a_dropped_key_is_not_given_out() {
    let _serial = KEPT_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    kept::reset();
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    kept::keep(home.path(), &store, "R2_TOKEN", KEY, hosts(&["example.com"]), &[], 1).unwrap();
    kept::keep(home.path(), &store, "OTHER", "other", None, &[], 1).unwrap();
    store.put("kept.R2_TOKEN", "swapped-in").unwrap();
    kept::reset();
    let got = given(home.path(), &store, &[]);
    assert_eq!(got.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(), ["OTHER"]);

    assert!(kept::remove(home.path(), &store, "OTHER").unwrap());
    assert!(store.get("kept.OTHER").unwrap().is_none());
    assert!(given(home.path(), &store, &[]).is_empty());
    assert!(!kept::remove(home.path(), &store, "OTHER").unwrap());
}

#[test]
fn keep_refuses_unsafe_names_hosts_values_and_a_store_that_takes_no_write() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let keep = |name: &str, value: &str, pulled: &[String]| {
        kept::keep(home.path(), &store, name, value, None, pulled, 1)
    };
    for name in ["PATH", "LD_PRELOAD", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "a.b", ""] {
        assert_eq!(keep(name, KEY, &[]), Err("vault.bad_name"), "{name}");
    }
    assert_eq!(keep("R2_TOKEN", "", &[]), Err("vault.empty_value"));
    assert_eq!(keep("R2_TOKEN", "a\0b", &[]), Err("vault.bad_value"));
    assert_eq!(
        keep("R2_TOKEN", &"x".repeat(kept::MAX_VALUE_BYTES + 1), &[]),
        Err("vault.bad_value")
    );
    assert_eq!(keep("R2_TOKEN", KEY, &["R2_TOKEN".to_owned()]), Err("vault.name_taken"));
    assert_eq!(kept::check_hosts(&["https://x/y z".into()]), Err("vault.bad_host"));
    let many: Vec<String> = (0..17).map(|i| format!("h{i}.example.com")).collect();
    assert_eq!(kept::check_hosts(&many), Err("vault.too_many_hosts"));
    let none = MemoryStore { unavailable: true, ..MemoryStore::default() };
    assert_eq!(kept::keep(home.path(), &none, "R2_TOKEN", KEY, None, &[], 1), Err(UNAVAILABLE));
    assert!(store.items.lock().unwrap().is_empty());
    assert!(!kept::path(home.path()).exists());
}
