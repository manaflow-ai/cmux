//! The rollback decision (the Swift `RollbackDecision.decide` and the stores
//! check of `UpdaterService.rollbackDecision`), case by case.

mod updater_core_rollback {
    use cmux_updater_core::rollback::{KeptCandidate, Refusal, decide};
    use std::collections::BTreeMap;

    fn schemas(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
        pairs.iter().map(|(store, version)| ((*store).to_owned(), *version)).collect()
    }

    fn kept(build: &str, reads: Option<&[(&str, i64)]>, team: Option<&str>) -> KeptCandidate {
        KeptCandidate {
            build: build.to_owned(),
            store_schemas: reads.map(schemas),
            team_id: team.map(str::to_owned),
        }
    }

    fn two() -> Vec<KeptCandidate> {
        vec![
            kept("300", Some(&[("layout", 4), ("conversations", 2)]), Some("TEAM")),
            kept("200", Some(&[("layout", 3)]), Some("TEAM")),
        ]
    }

    #[test]
    fn the_newest_kept_build_that_reads_every_store_is_the_target() {
        let stored = schemas(&[("layout", 4), ("conversations", 1)]);
        assert_eq!(decide(&two(), None, Some(&stored), Some("TEAM")), Ok(0));
        assert_eq!(
            decide(&two(), Some("200"), Some(&schemas(&[("layout", 3)])), Some("TEAM")),
            Ok(1)
        );
    }

    #[test]
    fn unreadable_stores_refuse_before_anything_else() {
        assert_eq!(decide(&[], None, None, None), Err(Refusal::StoresUnknown));
    }

    #[test]
    fn nothing_kept_or_not_the_build_asked_for() {
        let stored = schemas(&[]);
        assert_eq!(decide(&[], None, Some(&stored), Some("TEAM")), Err(Refusal::NothingKept));
        // An asked build that is not kept never falls back to the newest one.
        assert_eq!(
            decide(&two(), Some("250"), Some(&stored), Some("TEAM")),
            Err(Refusal::NothingKept)
        );
    }

    #[test]
    fn another_team_or_no_team_is_a_signature_refusal() {
        let stored = schemas(&[]);
        assert_eq!(
            decide(&two(), None, Some(&stored), Some("OTHER")),
            Err(Refusal::Signature { kept: 0 })
        );
        assert_eq!(decide(&two(), None, Some(&stored), None), Err(Refusal::Signature { kept: 0 }));
        let unsigned = vec![kept("300", Some(&[]), None)];
        assert_eq!(
            decide(&unsigned, None, Some(&stored), Some("TEAM")),
            Err(Refusal::Signature { kept: 0 })
        );
    }

    #[test]
    fn a_build_without_store_schemas_predates_rollback() {
        let old = vec![kept("100", None, Some("TEAM"))];
        assert_eq!(
            decide(&old, None, Some(&schemas(&[])), Some("TEAM")),
            Err(Refusal::PredatesRollback { kept: 0 })
        );
    }

    #[test]
    fn a_newer_or_unknown_store_refuses_naming_the_first_store_in_order() {
        let stored = schemas(&[("layout", 5), ("conversations", 9)]);
        // "conversations" sorts first: it is the one named.
        assert_eq!(
            decide(&two(), None, Some(&stored), Some("TEAM")),
            Err(Refusal::StoreTooNew {
                kept: 0,
                store: "conversations".to_owned(),
                stored: 9,
                readable: 2
            })
        );
        let unknown = schemas(&[("agents", 1), ("layout", 3)]);
        assert_eq!(
            decide(&two(), Some("200"), Some(&unknown), Some("TEAM")),
            Err(Refusal::UnknownStore { kept: 1, store: "agents".to_owned() })
        );
    }
}
