use std::path::{Path, PathBuf};

use super::super::{Command as TryCommand, parse as parse_try};
use super::{
    Build, Command, Link, Way, choose, debug_socket, dev_apps, merged_commit, parse, parse_link,
    secret_key, share_tag, shareable_backend, store_from, team_of,
};

const STORE: &str = "https://cache.example.ts.net:18444/cmux-build-cache";
const FULL: &str = "0123456789abcdef0123456789abcdef01234567";

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn build(commit: Option<&str>, dirty: bool) -> Build {
    Build {
        app: PathBuf::from("/Users/a/Applications/cmux DEV cloud-fix.app"),
        bundle_id: "com.cmuxterm.app.debug.cloud-fix".to_owned(),
        name: "cmux DEV cloud-fix".to_owned(),
        commit: commit.map(str::to_owned),
        dirty,
        tag: Some("cloud-fix".to_owned()),
    }
}

#[test]
fn a_link_round_trips_with_its_backend() {
    let link = Link {
        store: STORE.to_owned(),
        tag: "share-cloud-fix-0123456789ab".to_owned(),
        backend: Some("staging".to_owned()),
    };
    let url = link.url();
    assert_eq!(url, format!("{STORE}/v1/tags/share-cloud-fix-0123456789ab?backend=staging"));
    assert_eq!(parse_link(&url), Some(link));
}

#[test]
fn a_tailnet_backend_is_escaped_in_the_link() {
    let backend = "https://stack.example.ts.net:8443".to_owned();
    let link = Link { store: STORE.to_owned(), tag: "share-x".to_owned(), backend: Some(backend) };
    assert_eq!(parse_link(&link.url()), Some(link));
}

#[test]
fn only_https_cache_tag_links_are_links() {
    for text in [
        "http://cache.example/v1/tags/share-x",
        "https://cache.example/v1/artifacts/share-x",
        "https://cache.example/v1/tags/",
        "https://cache.example/v1/tags/-bad",
        "https://cache.example/v1/tags/a/b",
        "https://user@cache.example/v1/tags/share-x",
        "https://cache.example/v1/tags/share-x?token=abc",
        "4242",
        FULL,
    ] {
        assert_eq!(parse_link(text), None, "{text}");
    }
    assert_eq!(
        parse_link("https://cache.example/v1/tags/share-x"),
        Some(Link {
            store: "https://cache.example".to_owned(),
            tag: "share-x".to_owned(),
            backend: None
        })
    );
}

#[test]
fn app_try_takes_a_share_link_and_still_takes_a_sha() {
    let url = format!("{STORE}/v1/tags/share-x?backend=prod");
    match parse_try(&words(&[&url, "--dry-run"])).unwrap() {
        TryCommand::Link { link, dry_run } => {
            assert!(dry_run);
            assert_eq!(link.backend.as_deref(), Some("prod"));
        }
        other => panic!("{other:?}"),
    }
    assert!(parse_try(&words(&[&url, "--app", "/A.app"])).is_err());
    assert!(matches!(parse_try(&words(&[FULL])).unwrap(), TryCommand::Try { .. }));
}

#[test]
fn share_parses_its_flags() {
    assert_eq!(
        parse(&words(&["--app", "/A.app", "--bundle", "--store=https://s", "--dry-run"])).unwrap(),
        Command::Share {
            app: Some(PathBuf::from("/A.app")),
            bundle: true,
            store: Some("https://s".to_owned()),
            dry_run: true,
        }
    );
    assert_eq!(parse(&words(&["--help"])).unwrap(), Command::Help);
    assert!(parse(&words(&["--app"])).is_err());
    assert!(parse(&words(&["--bogus"])).is_err());
}

#[test]
fn the_store_comes_from_the_flag_then_the_env_then_the_file() {
    let file = r#"{"store": "https://file.example/cmux-build-cache/"}"#;
    assert_eq!(
        store_from(Some("https://flag.example"), Some("https://env.example"), Some(file)).unwrap(),
        "https://flag.example"
    );
    assert_eq!(
        store_from(None, Some("https://env.example/"), Some(file)).unwrap(),
        "https://env.example"
    );
    assert_eq!(
        store_from(None, Some(" "), Some(file)).unwrap(),
        "https://file.example/cmux-build-cache"
    );
    assert!(store_from(None, None, None).unwrap_err().contains("app-share.json"));
    assert!(store_from(None, None, Some("not json")).is_err());
    assert!(store_from(Some("http://plain.example"), None, None).is_err());
}

#[test]
fn a_clean_merged_commit_is_shared_as_its_sha() {
    let way = choose(&build(Some("0123456"), false), false, |commit| {
        assert_eq!(commit, "0123456");
        Ok(Some(FULL.to_owned()))
    });
    assert_eq!(way, Way::Sha(FULL.to_owned()));
}

#[test]
fn anything_else_is_shared_as_the_build() {
    let never = |_: &str| -> Result<Option<String>, String> { panic!("no lookup") };
    assert!(matches!(choose(&build(Some("0123456"), true), false, never), Way::Bundle(_)));
    assert!(matches!(choose(&build(None, false), false, never), Way::Bundle(_)));
    assert!(matches!(choose(&build(Some("0123456"), false), true, never), Way::Bundle(_)));
    assert!(matches!(choose(&build(Some("0123456"), false), false, |_| Ok(None)), Way::Bundle(_)));
    assert!(matches!(
        choose(&build(Some("0123456"), false), false, |_| Err("rate limited".to_owned())),
        Way::Bundle(_)
    ));
}

#[test]
fn github_compare_says_whether_the_commit_is_merged() {
    let behind = format!(r#"{{"status":"behind","merge_base_commit":{{"sha":"{FULL}"}}}}"#);
    assert_eq!(merged_commit(200, behind.as_bytes()).unwrap(), Some(FULL.to_owned()));
    let identical = format!(r#"{{"status":"identical","merge_base_commit":{{"sha":"{FULL}"}}}}"#);
    assert_eq!(merged_commit(200, identical.as_bytes()).unwrap(), Some(FULL.to_owned()));
    let diverged = format!(r#"{{"status":"diverged","merge_base_commit":{{"sha":"{FULL}"}}}}"#);
    assert_eq!(merged_commit(200, diverged.as_bytes()).unwrap(), None);
    assert_eq!(merged_commit(404, b"{}").unwrap(), None);
    assert!(merged_commit(403, b"rate limit").is_err());
}

#[test]
fn the_tag_is_a_cache_tag_named_for_the_build() {
    let digest = "abcdef0123456789".repeat(4);
    assert_eq!(share_tag(&build(None, false), &digest), "share-cloud-fix-abcdef012345");
    let mut odd = build(None, false);
    odd.tag = None;
    odd.name = "cmux DEV  Ünïcode / name".to_owned();
    let tag = share_tag(&odd, &digest);
    assert_eq!(tag, "share-cmux-dev-n-code-name-abcdef012345");
    assert!(super::valid_tag(&tag));
    odd.name = "x".repeat(200);
    assert!(super::valid_tag(&share_tag(&odd, &digest)));
}

#[test]
fn a_local_backend_does_not_travel() {
    assert_eq!(shareable_backend("staging").as_deref(), Some("staging"));
    assert_eq!(shareable_backend("production").as_deref(), Some("prod"));
    assert_eq!(shareable_backend("local"), None);
    assert_eq!(shareable_backend("nonsense"), None);
}

#[test]
fn secret_looking_environment_keys_are_refused() {
    for key in ["CMUX_AUTH_TOKEN", "STACK_SECRET_SERVER_KEY", "OPENAI_API_KEY", "x_password"] {
        assert!(secret_key(key), "{key}");
    }
    for key in
        ["CMUX_TAG", "CMUX_AUTH_CREDENTIALS_FILE", "CMUX_API_BASE_URL", "CMUX_AUTH_ENVIRONMENT"]
    {
        assert!(!secret_key(key), "{key}");
    }
}

#[test]
fn running_dev_builds_are_the_dev_apps_that_answered() {
    let dev = PathBuf::from("/Users/a/Applications/cmux DEV cloud-fix.app");
    let answered = vec![dev.clone(), PathBuf::from("/Applications/cmux NIGHTLY.app"), dev.clone()];
    let found = dev_apps(answered, |app: &Path| app.to_string_lossy().contains("DEV"));
    assert_eq!(found, vec![dev]);
    assert!(debug_socket(Path::new("/tmp/cmux-debug-cloud-fix.sock")));
    assert!(!debug_socket(Path::new("/tmp/cmux-nightly.sock")));
    assert!(!debug_socket(Path::new("/tmp/cmux-debug-x.log")));
}

#[test]
fn codesign_names_the_team_or_none() {
    assert_eq!(team_of("Identifier=x\nTeamIdentifier=7WLXT3NR37\n").as_deref(), Some("7WLXT3NR37"));
    assert_eq!(team_of("Signature=adhoc\nTeamIdentifier=not set\n"), None);
    assert_eq!(team_of("Signature=adhoc\n"), None);
}
