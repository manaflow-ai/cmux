use super::*;

// Run 45882763507 (2026-11-26): a default 2x4096 create on the bare `autocloud` template, snapshotted
// at 4x8192, came back 4x8192 and the platform claimed it as a default-size spare.
fn snap(id: &str, vcpus: u8, mem_mib: u32) -> SnapshotMeta {
    SnapshotMeta {
        id: id.into(),
        source_machine: "m".into(),
        image: "i".into(),
        vcpus,
        mem_mib,
        egress: Egress::default(),
        created_unix_ms: 0,
    }
}

#[test]
fn only_a_snapshot_at_the_asked_size_is_chosen() {
    let bare = ("autocloud".to_owned(), snap("s-bare", 4, 8192));
    // Only the bare template, at 4x8192: a 2x4096 create is refused and told the size there is.
    assert_eq!(choose(std::slice::from_ref(&bare), 2, 4096), Err("autocloud is 4x8192".into()));
    // The bare template still serves a create at its own size.
    assert_eq!(choose(std::slice::from_ref(&bare), 4, 8192), Ok("s-bare".into()));
    // A sized template wins; one PUT at the wrong size is named, never used.
    let sized = ("autocloud@2x4096".to_owned(), snap("s-2x4", 2, 4096));
    assert_eq!(choose(&[sized, bare.clone()], 2, 4096), Ok("s-2x4".into()));
    let wrong = ("autocloud@2x4096".to_owned(), snap("s-wrong", 4, 8192));
    assert_eq!(
        choose(&[wrong, bare], 2, 4096),
        Err("autocloud@2x4096 is 4x8192, autocloud is 4x8192".into())
    );
    // No template at all is template_not_found (an empty list), not size_unavailable.
    assert_eq!(choose(&[], 2, 4096), Err(String::new()));
}

#[test]
fn contract_patterns() {
    assert!(valid_vm_id("vm-0123abcd"));
    assert!(!valid_vm_id("-vm"));
    assert!(!valid_vm_id("vm/1"));
    assert!(valid_vm_name("cmux-next-abc-1"));
    assert!(!valid_vm_name("Upper"));
    assert!(!valid_vm_name(&"a".repeat(129)));
    assert!(valid_tag_key("cmux_next_team"));
    assert!(!valid_tag_key("1team"));
    assert!(valid_template("autocloud@2x4096"));
    assert!(!valid_template("../x"));
    assert!(!valid_template(".x"));
}

#[test]
fn create_key_ignores_tag_order() {
    let a: BTreeMap<String, String> =
        [("b".into(), "2".into()), ("a".into(), "1".into())].into_iter().collect();
    let k = |tag: &BTreeMap<String, String>| {
        digest(&CreateKey {
            template_id: "t",
            vcpus: 2,
            mem_mib: 4096,
            disk_gib: 10,
            name: "n",
            tag,
        })
    };
    let mut b = BTreeMap::new();
    b.insert("a".to_owned(), "1".to_owned());
    b.insert("b".to_owned(), "2".to_owned());
    assert_eq!(k(&a), k(&b));
    b.insert("a".to_owned(), "9".to_owned());
    assert_ne!(k(&a), k(&b));
}

#[test]
fn prune_drops_oldest() {
    let mut m = BTreeMap::new();
    for i in 0..(LEDGER_CAP + 3) {
        let id = format!("r{i}");
        m.insert(
            id.clone(),
            Record {
                request_id: id,
                verb: Verb::Pause,
                body: String::new(),
                vm_id: "v".into(),
                at_ms: i as u64,
            },
        );
    }
    prune(&mut m);
    assert_eq!(m.len(), LEDGER_CAP);
    assert!(!m.contains_key("r0") && !m.contains_key("r2") && m.contains_key("r3"));
}

#[test]
fn times_are_rfc3339() {
    assert_eq!(rfc3339(0), "1970-01-01T00:00:00.000Z");
}
