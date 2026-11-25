//! Parity with the Swift tests these rules came from (`AttentionBannerTests`'s
//! `aRemoteMuteSavedBeforeQualifiedKeysStaysMuted` and
//! `aRemoteSoundRuleSavedBeforeQualifiedKeysStillApplies`), plus the key shape and Foundation's
//! base64 edges.

use super::*;

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

#[test]
fn a_remote_mute_saved_before_qualified_keys_stays_muted() {
    let none = set(&[]);
    let keys = set(&["ws_lab"]);
    assert!(
        mutes(&keys, "lab", "ws_lab", "local", &none),
        "an earlier build's remote mute was dropped on upgrade"
    );
    assert_eq!(workspace_ids(&keys, "lab", "local", &none), set(&["ws_lab"]));
    assert_eq!(
        legacy_remote_key(&keys, "lab", "ws_lab", "local", &none).as_deref(),
        Some("ws_lab")
    );
    let local_has = set(&["ws_lab"]);
    assert!(
        !mutes(&keys, "lab", "ws_lab", "local", &local_has),
        "a local mute reached a forked machine's same-id workspace"
    );
    assert!(workspace_ids(&keys, "lab", "local", &local_has).is_empty());
    let other_machine = qualified("other", "ws_lab");
    assert!(
        workspace_ids(&set(&[&other_machine]), "lab", "local", &none).is_empty(),
        "another machine's qualified key read as a bare id"
    );
}

#[test]
fn a_remote_sound_rule_saved_before_qualified_keys_still_applies() {
    let qualified_key = qualified("lab", "ws_lab");
    let key = |rules: &[&str], local_has: bool| {
        let local = if local_has { set(&["ws_lab"]) } else { set(&[]) };
        rule_key("lab", "ws_lab", "local", &set(rules), &local)
    };
    assert_eq!(
        key(&["ws_lab"], false),
        "ws_lab",
        "an earlier build's remote sound rule was dropped on upgrade"
    );
    assert_eq!(key(&[], false), qualified_key);
    assert_eq!(key(&["ws_lab", &qualified_key], false), qualified_key);
    assert_eq!(
        key(&["ws_lab"], true),
        qualified_key,
        "a local workspace's rule reached a forked machine's same-id workspace"
    );
    assert_eq!(rule_key("local", "ws_lab", "local", &set(&[]), &set(&["ws_lab"])), "ws_lab");
}

#[test]
fn a_qualified_key_is_both_ids_in_base64() {
    assert_eq!(qualified("lab", "ws_lab"), "machine:bGFi:workspace:d3NfbGFi");
    assert_eq!(qualified("", ""), "machine::workspace:");
    assert_eq!(qualified("mac-é", "ws/1"), "machine:bWFjLcOp:workspace:d3MvMQ==");
}

#[test]
fn the_local_machine_keeps_bare_ids_and_reads_every_key() {
    assert_eq!(settings_key("local", "ws_1", "local"), "ws_1");
    assert_eq!(settings_key("lab", "ws_1", "local"), qualified("lab", "ws_1"));
    let keys = set(&["ws_1", "machine:anything"]);
    assert_eq!(workspace_ids(&keys, "local", "local", &set(&["ws_1"])), keys);
    assert!(mutes(&set(&["ws_1"]), "local", "ws_1", "local", &set(&["ws_1"])));
    assert_eq!(legacy_remote_key(&set(&["ws_1"]), "local", "ws_1", "local", &set(&[])), None);
}

#[test]
fn a_remote_machine_reads_its_own_qualified_keys() {
    let keys = set(&[
        &qualified("lab", "ws_1"),
        &qualified("lab", "ws_2"),
        &qualified("other", "ws_3"),
        "ws_4",
    ]);
    assert_eq!(workspace_ids(&keys, "lab", "local", &set(&[])), set(&["ws_1", "ws_2", "ws_4"]));
    assert!(mutes(&keys, "lab", "ws_1", "local", &set(&[])));
    assert!(!mutes(&keys, "lab", "ws_3", "local", &set(&[])));
    assert!(mutes(&keys, "other", "ws_3", "local", &set(&[])));
}

#[test]
fn a_qualified_key_that_does_not_decode_is_dropped() {
    let prefix = format!("machine:{}:workspace:", base64_encode(b"lab"));
    let keys =
        set(&[&format!("{prefix}not base64"), &format!("{prefix}/w=="), &format!("{prefix}d3M")]);
    assert!(workspace_ids(&keys, "lab", "local", &set(&[])).is_empty());
    let bad_utf8 = format!("{prefix}{}", base64_encode(&[0xFF, 0xFE]));
    assert!(workspace_ids(&set(&[&bad_utf8]), "lab", "local", &set(&[])).is_empty());
}

#[test]
fn base64_matches_foundation() {
    for (raw, encoded) in
        [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg==")]
    {
        assert_eq!(base64_encode(raw.as_bytes()), encoded);
        assert_eq!(base64_decode(encoded).as_deref(), Some(raw.as_bytes()));
    }
    assert_eq!(base64_encode(&[0xFB, 0xFF]), "+/8=");
    assert_eq!(base64_decode("+/8="), Some(vec![0xFB, 0xFF]));
    for bad in ["Zg", "Zg=", "Z===", "Zg==Zg==", "Zm9v\n", "Zm-v", "Zm_v"] {
        assert_eq!(base64_decode(bad), None, "{bad:?}");
    }
}
