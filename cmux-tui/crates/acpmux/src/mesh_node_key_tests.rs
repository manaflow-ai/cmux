use super::*;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[test]
fn creates_a_stable_owner_only_key_and_public_encoding() {
    let dir = tempfile::tempdir().unwrap();
    let first = load_or_create_at(dir.path()).unwrap();
    let second = load_or_create_at(dir.path()).unwrap();
    assert_eq!(first.public_key, second.public_key);
    assert_eq!(first.public_key_base64().len(), 44);
    #[cfg(unix)]
    {
        let mode =
            std::fs::metadata(KeyFile::Node.path_in(dir.path())).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let bytes =
        base64::engine::general_purpose::STANDARD.decode(first.public_key_base64()).unwrap();
    assert_eq!(bytes.len(), 32);
    assert!(!format!("{first:?}").contains("private"));
    let holder = KeyHolder::acquire(dir.path()).unwrap();
    let (held, private) = load_or_create_held(dir.path(), &holder).unwrap();
    assert_eq!(held.public_key, first.public_key);
    assert_eq!(NodeKeypair::of(&private).public_key, first.public_key);
}

#[test]
fn replacing_a_key_gives_a_new_identity_that_then_stays() {
    let dir = tempfile::tempdir().unwrap();
    let copied = load_or_create_at(dir.path()).unwrap();
    let fresh = replace_at(dir.path()).unwrap();
    assert_ne!(copied.public_key, fresh.public_key);
    assert_eq!(load_or_create_at(dir.path()).unwrap().public_key, fresh.public_key);
    // What the hub carrier's key check reads: the replacement, never the copied key.
    assert_eq!(public_key_at(dir.path()), Some(fresh.public_key));
    // With no key yet, a replacement is a first key.
    let empty = tempfile::tempdir().unwrap();
    let first = replace_at(empty.path()).unwrap();
    assert_eq!(load_or_create_at(empty.path()).unwrap().public_key, first.public_key);
}

/// Review F1 at 2d63280a: a replacement is a compare-and-replace, asked under the key lock:
/// a key put in place after the caller's check stays, and a copied one goes.
#[test]
fn a_compare_and_replace_keeps_a_key_put_in_place_after_the_check() {
    let dir = tempfile::tempdir().unwrap();
    let checked = load_or_create_at(dir.path()).unwrap().public_key;
    record_copied_key(dir.path()).unwrap();
    // Another process replaced it after the check (a `host join`).
    let joined = replace_at(dir.path()).unwrap().public_key;
    assert!(replace_at_if(dir.path(), |now| *now == checked).unwrap().is_none());
    assert_eq!(public_key_at(dir.path()), Some(joined));
    assert!(replace_copied_at(dir.path()).unwrap().is_none(), "the join's key is not copied");
    assert_eq!(public_key_at(dir.path()), Some(joined));
    // An adopted key that is not the one asked about stays with no refusal.
    std::fs::create_dir_all(dir.path().join("link")).unwrap();
    std::fs::write(dir.path().join("link/key-adopted.json"), b"{}").unwrap();
    assert!(replace_at_if(dir.path(), |now| *now == checked).unwrap().is_none());
    std::fs::remove_file(dir.path().join("link/key-adopted.json")).unwrap();
    record_copied_key(dir.path()).unwrap();
    let fresh = replace_copied_at(dir.path()).unwrap().unwrap().public_key;
    assert_ne!(fresh, joined);
    assert!(!serves_copied_key(dir.path()));
}

/// Review F1 at fb84fe4b, the link's home record: cut short between its two writes, the
/// home already lists the link (written first), so a refusal the link keeps there keeps
/// acpmux off the key it names; the link's own half is written at its next start.
#[test]
fn a_link_home_record_cut_short_between_its_writes_still_lets_acpmux_find_the_refusal() {
    use base64::Engine as _;
    let home = tempfile::tempdir().unwrap();
    let link = tempfile::tempdir().unwrap();
    let key = load_or_create_at(home.path()).unwrap().public_key;
    hooks::BETWEEN_WRITES.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(|| panic!("cut short between the writes")));
    });
    let cut = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        record_link_home(link.path(), Some(home.path()))
    }));
    assert!(cut.is_err(), "the record was not cut short");
    assert!(recorded_home(link.path()).is_none(), "the link's half came first");
    assert!(recorded_link_dirs(home.path()).iter().any(|dir| dir == link.path()));
    let refusal = serde_json::json!({
        "acpmux_home": home.path(),
        "public_key": base64::engine::general_purpose::STANDARD.encode(key),
    });
    std::fs::write(link.path().join(LINK_COPIED), refusal.to_string()).unwrap();
    assert!(serves_copied_key(home.path()), "acpmux would serve the refused key");
    // Its next start writes the link's half.
    record_link_home(link.path(), Some(home.path())).unwrap();
    assert_eq!(recorded_home(link.path()).as_deref(), Some(home.path()));
}

/// A copied home's key is never replaced when the cmux link adopted it or another process
/// holds the key lock: the key stays, and the replacement says why.
#[test]
fn replacing_never_touches_an_adopted_or_held_key() {
    let dir = tempfile::tempdir().unwrap();
    let kept = load_or_create_at(dir.path()).unwrap();
    std::fs::create_dir_all(dir.path().join("link")).unwrap();
    std::fs::write(dir.path().join("link/key-adopted.json"), b"{}").unwrap();
    let refused = replace_at(dir.path()).unwrap_err();
    assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
    assert_eq!(public_key_at(dir.path()), Some(kept.public_key));
    std::fs::remove_file(dir.path().join("link/key-adopted.json")).unwrap();
    let held = KeyHolder::acquire(dir.path()).unwrap();
    let refused = replace_at(dir.path()).unwrap_err();
    assert!(refused.to_string().starts_with("node_key.held:"), "{refused}");
    assert_eq!(public_key_at(dir.path()), Some(kept.public_key));
    drop(held);
    // A record of another home's adoption does not keep this home's key.
    let other = tempfile::tempdir().unwrap();
    let record = serde_json::json!({ "key_dir": other.path() });
    std::fs::write(dir.path().join("link/key-adopted.json"), record.to_string()).unwrap();
    let fresh = replace_at(dir.path()).unwrap();
    assert_ne!(fresh.public_key, kept.public_key);
    // This home's own record does.
    let record = serde_json::json!({ "key_dir": dir.path() });
    std::fs::write(dir.path().join("link/key-adopted.json"), record.to_string()).unwrap();
    let refused = replace_at(dir.path()).unwrap_err();
    assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
    assert_eq!(public_key_at(dir.path()), Some(fresh.public_key));
}

/// Review F1 at 9e91bcea: acpmux's transport steps down only for a link that serves this
/// home's node key, by the home the app recorded for it or its adoption record, and never
/// for one that keeps a key of its own, is server-enrolled, or refuses a copied home.
#[test]
fn the_transport_steps_down_only_for_a_link_that_serves_this_homes_node_key() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("acpmux");
    let link = dir.path().join("link");
    std::fs::create_dir_all(&link).unwrap();
    assert!(!link_serves_node_key(None, &home));
    assert!(!link_serves_node_key(Some(&link), &home), "no link set up");
    std::fs::write(link.join("config.json"), r#"{"install":"inst_a","port":4101}"#).unwrap();
    assert!(!link_serves_node_key(Some(&link), &home), "a link with no home keeps its key");
    record_link_home(&link, Some(&home)).unwrap();
    assert_eq!(recorded_home(&link).as_deref(), Some(home.as_path()));
    assert_eq!(recorded_link_dir(&home).as_deref(), Some(link.as_path()));
    assert!(link_serves_node_key(Some(&link), &home));
    let other = dir.path().join("other");
    assert!(!link_serves_node_key(Some(&link), &other), "another home's link");
    // No home any more (a link on another state directory): the record goes.
    record_link_home(&link, None).unwrap();
    assert_eq!(recorded_home(&link), None);
    assert!(!link_serves_node_key(Some(&link), &home));
    // An adoption record naming this home serves it, recorded or not.
    let record = serde_json::json!({ "key_dir": home });
    std::fs::write(link.join("key-adopted.json"), record.to_string()).unwrap();
    assert!(link_serves_node_key(Some(&link), &home));
    // The link refuses a copied home: the transport does not step down for it.
    std::fs::write(link.join(LINK_COPIED), b"{}").unwrap();
    assert!(!link_serves_node_key(Some(&link), &home));
    std::fs::remove_file(link.join(LINK_COPIED)).unwrap();
    // A server-enrolled link keeps its enrollment's key.
    std::fs::write(
        link.join("config.json"),
        r#"{"install":"inst_a","port":4101,"server_identity":"/s"}"#,
    )
    .unwrap();
    assert!(!link_serves_node_key(Some(&link), &home));
}

/// Review F3 at 7837efd1: link L1 adopted this home's key, then link L2 was set up on the
/// same home without adopting. Both stay recorded, the guard reads both, and a leave (or a
/// copy's replacement) keeps L1's adopted key; the transport finds L1.
#[test]
fn a_second_link_dir_never_hides_the_first_ones_adoption() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("acpmux");
    let kept = load_or_create_at(&home).unwrap();
    let (l1, l2) = (dir.path().join("l1"), dir.path().join("l2"));
    for link in [&l1, &l2] {
        std::fs::create_dir_all(link).unwrap();
        std::fs::write(link.join("config.json"), r#"{"install":"inst_a","port":0}"#).unwrap();
    }
    record_link_home(&l1, Some(&home)).unwrap();
    let adopted = serde_json::json!({ "key_dir": home });
    std::fs::write(l1.join("key-adopted.json"), adopted.to_string()).unwrap();
    record_link_home(&l2, Some(&home)).unwrap();
    assert_eq!(recorded_link_dirs(&home), vec![l1.clone(), l2.clone()]);
    assert!(adoption_depends(&home), "L2 hid L1's adoption");
    assert!(matches!(lock_to_remove(&home).unwrap(), RemoveLock::Adopted));
    let refused = replace_at(&home).unwrap_err();
    assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
    assert_eq!(public_key_at(&home), Some(kept.public_key));
    assert_eq!(recorded_link_dir(&home), Some(l1.clone()), "the adopted link serves");
    // Recording L1 again changes nothing; neither does L2 dropping its home.
    record_link_home(&l1, Some(&home)).unwrap();
    record_link_home(&l2, None).unwrap();
    assert_eq!(recorded_link_dirs(&home), vec![l1, l2]);
    assert!(adoption_depends(&home));
}

/// Review F1 and F2 at c1898fca: a sign-out archives the adoption record with its install
/// (`key-adopted.<install>.json`), and that install's peers still know the link by the node
/// key. Every change of the key (a leave's delete, a copied home's replacement, a rekey's
/// promotion) is refused while an archived record names this home, as for a current one.
#[test]
fn an_archived_adoption_keeps_the_key_from_every_change() {
    let dir = tempfile::tempdir().unwrap();
    let kept = load_or_create_at(dir.path()).unwrap();
    let kept_bytes = std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap();
    std::fs::create_dir_all(dir.path().join("link")).unwrap();
    let archived = dir.path().join("link/key-adopted.inst_a.json");
    std::fs::write(&archived, serde_json::json!({ "key_dir": dir.path() }).to_string()).unwrap();
    assert!(adoption_depends(dir.path()));
    assert!(matches!(lock_to_remove(dir.path()).unwrap(), RemoveLock::Adopted));
    let refused = replace_at(dir.path()).unwrap_err();
    assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
    let holder = KeyHolder::acquire(dir.path()).unwrap();
    write_pending_held(dir.path(), &holder, &[9u8; 32]).unwrap();
    let refused = promote_pending_held(dir.path(), &holder).unwrap_err();
    assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
    assert!(KeyFile::NodePending.path_in(dir.path()).exists(), "the pending key stays");
    drop(holder);
    assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), kept_bytes);
    assert_eq!(public_key_at(dir.path()), Some(kept.public_key));
    // An archive that cannot be read counts as this home's too.
    std::fs::write(&archived, b"not json").unwrap();
    assert!(adoption_depends(dir.path()));
    // Files that are not adoption records (a write's temporary file) do not.
    std::fs::remove_file(&archived).unwrap();
    std::fs::write(dir.path().join("link/.key-adopted.json.1.tmp"), b"{}").unwrap();
    std::fs::write(dir.path().join("link/peers.inst_a.json"), b"{}").unwrap();
    assert!(!adoption_depends(dir.path()));
    // An archive naming another home keeps only that home's key.
    let other = tempfile::tempdir().unwrap();
    std::fs::write(&archived, serde_json::json!({ "key_dir": other.path() }).to_string()).unwrap();
    assert!(!adoption_depends(dir.path()));
    let holder = KeyHolder::acquire(dir.path()).unwrap();
    promote_pending_held(dir.path(), &holder).unwrap();
    drop(holder);
    assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), [9u8; 32]);
}

#[test]
fn refuses_a_truncated_key_without_echoing_bytes() {
    assert_invalid_length(b"too short");
}

#[test]
fn refuses_an_oversized_key_without_echoing_bytes() {
    assert_invalid_length(b"private key fixture longer than thirty-two bytes");
}

fn assert_invalid_length(bytes: &[u8]) {
    let dir = tempfile::tempdir().unwrap();
    // Start with the helper's owner-only file on every supported platform.
    load_or_create_at(dir.path()).unwrap();
    std::fs::write(KeyFile::Node.path_in(dir.path()), bytes).unwrap();
    let error = load_or_create_at(dir.path()).unwrap_err();
    assert_eq!(format!("{error:#}"), "node key has invalid length");
    assert!(!format!("{error:?}").contains(std::str::from_utf8(bytes).unwrap()));
    assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), bytes);
}

#[test]
fn concurrent_first_use_keeps_one_public_identity() {
    let dir = tempfile::tempdir().unwrap();
    let paths = std::iter::repeat_with(|| dir.path().to_owned()).take(8);
    let barrier = std::sync::Barrier::new(8);
    let keys = std::thread::scope(|scope| {
        let handles = paths
            .map(|path| {
                let barrier = &barrier;
                scope.spawn(move || {
                    barrier.wait();
                    load_or_create_at(&path).unwrap().public_key
                })
            })
            .collect::<Vec<_>>();
        handles.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>()
    });
    assert!(keys.windows(2).all(|pair| pair[0] == pair[1]));
}
