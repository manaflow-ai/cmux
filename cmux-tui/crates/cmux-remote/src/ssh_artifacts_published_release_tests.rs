use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};

use super::*;

const COMMIT: &str = "5bdd4c9e4de3d3e93809a65135a039effc453c05";
const TARGET: &str = "x86_64-unknown-linux-musl";

fn key_pair() -> Ed25519KeyPair {
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
}

fn trust(pair: &Ed25519KeyPair) -> Vec<cmux_signed_envelope::Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(cmux_signed_envelope::key_id(&raw), raw)]
}

/// A release file as CI signs it (purpose cmux-linux-release), for
/// `commit`, its cmux-tui under `prefix`.
fn release(pair: &Ed25519KeyPair, commit: &str, prefix: &str, digest: &str) -> Vec<u8> {
    let payload = serde_json::to_vec(&serde_json::json!({
        "schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next",
        "commit": commit, "version": "1.0.0+20261101000000.5bdd4c9e4de3",
        "committed_at": 1, "published_at": 2, "expires_at": 3,
        "targets": {(TARGET): {
            "cmux-tui": {"url": format!("{prefix}cmux-tui-{TARGET}"), "sha256": digest, "size": 1234},
            "cmux-tui-hook": {"url": format!("{prefix}cmux-tui-hook-{TARGET}"), "sha256": digest, "size": 5},
        }},
    }))
    .unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    serde_json::to_vec(&serde_json::json!({
        "schema": 1,
        "payload": b64.encode(&payload),
        "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw), "sig": b64.encode(pair.sign(&payload).as_ref())}],
    }))
    .unwrap()
}

fn commit_prefix(commit: &str) -> String {
    format!("https://files.cmux.com/cmux-tui/{commit}/")
}

/// A DEV build ships no manifest; its own commit's signed release file
/// pins the Cloud machine's build (Cloud start proof, 2026-11-01: a fresh
/// machine's older image refused the first send and the DEV app could not
/// update it), with the size the file signs.
#[test]
fn a_dev_builds_signed_release_pins_the_linux_build() {
    let pair = key_pair();
    let digest = "b4311a86c5ea".to_owned() + &"0".repeat(52);
    let cache = Path::new("/tmp/cache");
    let body = release(&pair, COMMIT, &commit_prefix(COMMIT), &digest);
    let (pin, commit) =
        release_pin(&body, ReleasePlace::Commit(COMMIT), "linux", "x86_64", cache, &trust(&pair))
            .unwrap()
            .unwrap();
    assert_eq!(commit, COMMIT);
    assert_eq!(pin.url, format!("https://files.cmux.com/cmux-tui/{COMMIT}/cmux-tui-{TARGET}"));
    assert_eq!(pin.sha256, digest);
    assert_eq!(pin.size, Some(1234));
    assert_eq!(pin.cache_path, cache.join(format!("{digest}-cmux-tui-{TARGET}")));
}

/// What the unsigned manifest let through is refused: a file no release
/// key signed, another commit's genuine file, a URL off the commit's
/// prefix, or no entry for the platform.
#[test]
fn an_unsigned_foreign_or_incomplete_release_pins_nothing() {
    let (pair, other) = (key_pair(), key_pair());
    let digest = "a".repeat(64);
    let cache = Path::new("/tmp/cache");
    let keys = trust(&pair);
    let at = |body: &[u8], arch: &str| {
        release_pin(body, ReleasePlace::Commit(COMMIT), "linux", arch, cache, &keys)
    };
    let good = release(&pair, COMMIT, &commit_prefix(COMMIT), &digest);
    assert!(at(&release(&other, COMMIT, &commit_prefix(COMMIT), &digest), "x86_64").is_err());
    let another = "1".repeat(40);
    assert!(at(&release(&pair, &another, &commit_prefix(&another), &digest), "x86_64").is_err());
    assert!(at(&release(&pair, COMMIT, &commit_prefix(&another), &digest), "x86_64").is_err());
    assert!(at(&release(&pair, COMMIT, "https://evil.example/", &digest), "x86_64").is_err());
    assert!(at(&release(&pair, COMMIT, &commit_prefix(COMMIT), "short"), "x86_64").is_err());
    assert!(at(b"not json", "x86_64").is_err());
    let manifest = serde_json::to_vec(&serde_json::json!({
        "commit": COMMIT, "binaries": {(format!("cmux-tui-{TARGET}")): digest},
    }))
    .unwrap();
    assert!(at(&manifest, "x86_64").is_err(), "the unsigned manifest is not a release file");
    assert!(at(&good, "aarch64").is_err(), "a platform the release does not list");
    assert!(
        release_pin(&good, ReleasePlace::Commit(COMMIT), "plan9", "x86_64", cache, &keys)
            .unwrap()
            .is_none()
    );
    // The production keys do not trust a test key.
    let production = cmux_signed_envelope::linux_release::trusted_keys();
    assert!(!production.is_empty());
    assert!(
        release_pin(&good, ReleasePlace::Commit(COMMIT), "linux", "x86_64", cache, &production)
            .is_err()
    );
}

/// Review F1 (cmux#50221): a tree bundle whose commit has only the unsigned
/// manifest still takes its tree's signed release file.
#[test]
fn a_tree_bundle_tries_its_tree_before_refusing_an_unsigned_commit() {
    let unsigned = || Err::<Option<u8>, _>(unsigned_only(COMMIT));
    assert_eq!(commit_or_tree(unsigned(), Ok(Some(7))).unwrap(), Some(7));
    let refused = commit_or_tree(unsigned(), Ok(None)).unwrap_err().to_string();
    assert!(refused.contains("signed release file"), "{refused}");
    assert_eq!(commit_or_tree(Ok(Some(1)), Ok(Some(7))).unwrap(), Some(1));
    assert_eq!(commit_or_tree(Ok(None), Ok(Some(7))).unwrap(), Some(7));
    assert_eq!(commit_or_tree::<u8>(Ok(None), Ok(None)).unwrap(), None);
    let bad_tree = Err(BootstrapError::Configuration("bad tree".into()));
    assert!(commit_or_tree(unsigned(), bad_tree).is_err());
}

#[test]
fn a_commit_with_only_the_unsigned_manifest_says_why() {
    let message = unsigned_only(COMMIT).to_string();
    assert!(message.contains("5bdd4c9e4de3"), "{message}");
    assert!(message.contains("signed release file"), "{message}");
}

/// A tree-mode DEV bundle's own commit is never published on its own; its
/// tree's signed file pins it, or the signed file of the commit that
/// published the tree, which the tree's source must vouch for (Cloud
/// start proof, 2026-11-01: the DEV app's commit manifest was a 404).
#[test]
fn a_tree_bundle_takes_its_trees_signed_release() {
    let key = "df65220e9948cbe76924483c2a7ae1a98d52efbc";
    let version = format!("mode=tree\nkey={key}\ncommit={}\n", "6".repeat(40));
    assert_eq!(tree_key_in(&version).as_deref(), Some(key));
    assert_eq!(tree_key_in(&format!("mode=pin\nkey={key}\n")), None);
    assert_eq!(tree_key_in("mode=tree\nkey=\n"), None);

    let pair = key_pair();
    let keys = trust(&pair);
    let cache = Path::new("/tmp/cache");
    let digest = "c".repeat(64);
    // The tree's own file (phase 1b): its URLs under tree/<key>/.
    let payload = serde_json::to_vec(&serde_json::json!({
        "schema": 1, "purpose": "cmux-linux-release", "commit": COMMIT, "tree_key": key,
        "targets": {(TARGET): {"cmux-tui": {
            "url": format!("https://files.cmux.com/cmux-tui/tree/{key}/cmux-tui-{TARGET}"),
            "sha256": digest, "size": 9}}},
    }))
    .unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let tree_file = serde_json::to_vec(&serde_json::json!({
        "schema": 1, "payload": b64.encode(&payload),
        "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw), "sig": b64.encode(pair.sign(&payload).as_ref())}],
    }))
    .unwrap();
    let (pin, commit) =
        release_pin(&tree_file, ReleasePlace::Tree(key), "linux", "x86_64", cache, &keys)
            .unwrap()
            .unwrap();
    assert_eq!(commit, COMMIT);
    assert!(pin.url.contains(&format!("/tree/{key}/")));
    assert!(
        release_pin(
            &tree_file,
            ReleasePlace::Tree(&"e".repeat(40)),
            "linux",
            "x86_64",
            cache,
            &keys
        )
        .is_err()
    );

    // Before phase 1b: the source names the publishing commit, whose signed file pins it.
    let source = |key: &str, commit: &str, digest: &str| {
        serde_json::to_vec(&serde_json::json!({
            "key": key, "commit": commit, "run": "1",
            "binaries": {(format!("cmux-tui-{TARGET}")): digest},
        }))
        .unwrap()
    };
    assert_eq!(tree_commit(key, &source(key, COMMIT, &digest)).unwrap(), COMMIT);
    assert!(tree_commit(key, &source(&"e".repeat(40), COMMIT, &digest)).is_err());
    assert!(tree_commit(key, &source(key, "HEAD", &digest)).is_err());
    let body = release(&pair, COMMIT, &commit_prefix(COMMIT), &digest);
    let (pin, _) =
        release_pin(&body, ReleasePlace::Commit(COMMIT), "linux", "x86_64", cache, &keys)
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
