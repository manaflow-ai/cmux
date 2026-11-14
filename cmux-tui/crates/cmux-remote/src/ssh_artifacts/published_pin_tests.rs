use super::*;

const COMMIT: &str = "5bdd4c9e4de3d3e93809a65135a039effc453c05";
const BASE: &str = "https://files.cmux.com/cmux-tui/";

fn manifest(commit: &str, digest: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
            "commit": commit,
            "builtAt": "2026-11-01T00:00:00Z",
            "binaries": {"cmux-tui-x86_64-unknown-linux-musl": digest, "cmux-tui-aarch64-apple-darwin": "00"},
        }))
        .unwrap()
}

/// A DEV build ships no manifest; its own commit's published one pins the
/// Cloud machine's build (Cloud start proof, 2026-11-01: a fresh machine's
/// older image refused the first send and the DEV app could not update it).
#[test]
fn a_dev_builds_published_manifest_pins_the_linux_build() {
    let digest = "B4311A86C5EA".to_owned() + &"0".repeat(52);
    let cache = Path::new("/tmp/cache");
    let pin = published_pin(BASE, COMMIT, "linux", "x86_64", &manifest(COMMIT, &digest), cache)
        .unwrap()
        .unwrap();
    assert_eq!(
        pin.url,
        format!("https://files.cmux.com/cmux-tui/{COMMIT}/cmux-tui-x86_64-unknown-linux-musl")
    );
    assert_eq!(pin.sha256, digest.to_ascii_lowercase());
    assert_eq!(
        pin.cache_path,
        cache.join(format!("{}-cmux-tui-x86_64-unknown-linux-musl", digest.to_ascii_lowercase()))
    );
}

#[test]
fn another_commits_or_an_incomplete_manifest_pins_nothing() {
    let digest = "a".repeat(64);
    let cache = Path::new("/tmp/cache");
    let other = "1".repeat(40);
    assert!(
        published_pin(BASE, COMMIT, "linux", "x86_64", &manifest(&other, &digest), cache).is_err()
    );
    assert!(
        published_pin(BASE, COMMIT, "linux", "x86_64", &manifest(COMMIT, "short"), cache).is_err()
    );
    assert!(published_pin(BASE, COMMIT, "linux", "x86_64", b"not json", cache).is_err());
    assert!(
        published_pin(BASE, COMMIT, "linux", "aarch64", &manifest(COMMIT, &digest), cache).is_err(),
        "a platform the manifest does not pin"
    );
    assert!(
        published_pin(BASE, COMMIT, "plan9", "x86_64", &manifest(COMMIT, &digest), cache)
            .unwrap()
            .is_none()
    );
}

/// A tree-mode DEV bundle's own commit is never published on its own; the
/// commit that published its tree pins it (Cloud start proof,
/// 2026-11-01: the DEV app's commit manifest was a 404).
#[test]
fn a_tree_bundle_takes_its_trees_publishing_commit() {
    let key = "df65220e9948cbe76924483c2a7ae1a98d52efbc";
    let version = format!("mode=tree\nkey={key}\ncommit={}\n", "6".repeat(40));
    assert_eq!(tree_key_in(&version).as_deref(), Some(key));
    assert_eq!(tree_key_in(&format!("mode=pin\nkey={key}\n")), None);
    assert_eq!(tree_key_in("mode=tree\nkey=\n"), None);

    let digest = "c".repeat(64);
    let source = |key: &str, commit: &str, digest: &str| {
        serde_json::to_vec(&serde_json::json!({
            "key": key, "commit": commit, "run": "1",
            "binaries": {"cmux-tui-x86_64-unknown-linux-musl": digest},
        }))
        .unwrap()
    };
    assert_eq!(tree_commit(key, &source(key, COMMIT, &digest)).unwrap(), COMMIT);
    assert!(tree_commit(key, &source(&"e".repeat(40), COMMIT, &digest)).is_err());
    assert!(tree_commit(key, &source(key, "HEAD", &digest)).is_err());

    let pin = published_pin(
        BASE,
        COMMIT,
        "linux",
        "x86_64",
        &manifest(COMMIT, &digest),
        Path::new("/tmp/cache"),
    )
    .unwrap()
    .unwrap();
    assert!(tree_vouches(&source(key, COMMIT, &digest), &pin).is_ok());
    assert!(tree_vouches(&source(key, COMMIT, &"d".repeat(64)), &pin).is_err());
}

#[test]
fn only_a_plain_commit_is_looked_up() {
    assert!(is_commit(COMMIT));
    assert!(!is_commit(&COMMIT.to_ascii_uppercase()));
    assert!(!is_commit(&format!("{COMMIT}-dirty")));
    assert!(!is_commit("local"));
}
