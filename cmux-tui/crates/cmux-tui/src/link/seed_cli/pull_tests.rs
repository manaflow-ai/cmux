use super::{Kept, Record, Route, SeedBase, SeedError, base_of, route};

#[test]
fn only_a_folder_with_no_seed_falls_back_to_the_copy() {
    let base = || {
        Ok(SeedBase {
            head: "h".into(),
            index: "i".into(),
            work: "w".into(),
            stash: None,
            stash_known: false,
        })
    };
    let none = || Err(SeedError::new("seed.no_previous", "no record"));
    assert!(matches!(route(base(), true, true), Route::Seed(_)));
    assert!(matches!(route(base(), true, false), Route::Seed(_)));
    // A seeded folder on a machine without the export: update it, never the copy.
    assert!(matches!(route(base(), false, true), Route::Outdated));
    assert!(matches!(route(base(), false, false), Route::Outdated));
    // No seed: the copy with --or-copy, whatever the machine serves.
    assert!(matches!(route(none(), false, true), Route::Copy));
    assert!(matches!(route(none(), true, true), Route::Copy));
    assert!(
        matches!(route(none(), true, false), Route::Fail(error) if error.code == "seed.no_previous")
    );
    let other = Err(SeedError::new("sync_failed", "x"));
    assert!(matches!(route(other, true, true), Route::Fail(error) if error.code == "sync_failed"));
}

fn seed(machine: Option<&str>) -> Record {
    Record {
        mode: Kept::Seed,
        machine: machine.map(str::to_owned),
        url: None,
        head: Some("h".into()),
        index: Some("i".into()),
        work: Some("w".into()),
        stash: None,
        stash_known: true,
        filling: None,
        hop: None,
    }
}

#[test]
fn the_record_is_the_base_only_for_a_seed_to_the_same_machine() {
    let base = base_of(Some(&seed(Some("m"))), Some("m")).unwrap();
    assert_eq!((base.head.as_str(), base.index.as_str(), base.work.as_str()), ("h", "i", "w"));
    assert!(base_of(Some(&seed(None)), Some("m")).is_ok(), "an unknown machine");
    for (kept, why) in [
        (None, "no record"),
        (Some(seed(Some("other"))), "another machine"),
        (Some(Record { mode: Kept::Copy, ..seed(Some("m")) }), "a copy"),
        (Some(Record { work: None, ..seed(Some("m")) }), "incomplete"),
    ] {
        let error = base_of(kept.as_ref(), Some("m")).unwrap_err();
        assert_eq!(error.code, "seed.no_previous", "{why}");
    }
}
