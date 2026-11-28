use super::*;

#[test]
fn every_split_ships_off_so_everyone_gets_todays_walk() {
    assert!(SLOTS.iter().all(|slot| slot.split_permille == 0));
    for key in ["", "a", "install-1", "5f0c"] {
        let b = bundle(key);
        assert_eq!(b.id, "wb1-000000");
        assert_eq!(b.arms["screen"], "preview");
    }
}

#[test]
fn a_split_is_stable_per_install_and_near_its_share() {
    let slots = [Slot { id: "trust", arms: &["rows", "cards"], split_permille: 500 }];
    let first = bundle_for(&slots, "install-42");
    assert_eq!(first, bundle_for(&slots, "install-42"));
    let challengers = (0..10_000)
        .filter(|i| bundle_for(&slots, &format!("install-{i}")).arms["trust"] == "cards")
        .count();
    assert!((4_700..=5_300).contains(&challengers), "{challengers}");
}

#[test]
fn slots_split_independently() {
    let slots = [
        Slot { id: "a", arms: &["x", "y"], split_permille: 500 },
        Slot { id: "b", arms: &["x", "y"], split_permille: 500 },
    ];
    let ids: std::collections::BTreeSet<String> =
        (0..400).map(|i| bundle_for(&slots, &format!("k{i}")).id).collect();
    assert_eq!(ids.len(), 4, "{ids:?}");
}

#[test]
fn tally_counts_per_bundle_and_drops_old_versions() {
    let mut records = vec![
        outcome("wb1-000000", Ending::Started, 0),
        outcome("wb1-000000", Ending::Completed, 3),
        outcome("wb1-001000", Ending::Started, 0),
        outcome("wb1-001000", Ending::Skipped, 1),
    ];
    records.push(Outcome { version: 0, ..outcome("wb1-000000", Ending::Skipped, 0) });
    let counts = tally(&records);
    assert_eq!(counts["wb1-000000"], Tally { started: 1, completed: 1, skipped: 0 });
    assert_eq!(counts["wb1-001000"], Tally { started: 1, completed: 0, skipped: 1 });
}

#[test]
fn outcome_record_round_trips() {
    let json = serde_json::to_string(&outcome("wb1-000000", Ending::Completed, 3)).unwrap();
    assert_eq!(json, r#"{"version":1,"bundle":"wb1-000000","ending":"completed","screen":3}"#);
    assert_eq!(
        serde_json::from_str::<Outcome>(&json).unwrap(),
        outcome("wb1-000000", Ending::Completed, 3)
    );
}
