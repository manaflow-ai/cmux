use super::*;

#[test]
fn a_marked_end_counts_once_and_a_missing_one_is_a_death_once() {
    let dir = std::env::temp_dir().join(format!("supervise-ends-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let files = Files::new(&dir, "daemon", 5);
    assert_eq!(settle_previous(&files, &[], &record::write_file), Previous::None);

    // A child stands in for the previous daemon: recorded, then killed with no end.
    let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
    let who = crate::identity::of(child.id()).unwrap();
    let rec = OwnerRecord::new(who, None, vec!["sleep".into()]);
    record::store(&files.owner, &rec).unwrap();
    assert!(matches!(settle_previous(&files, &[], &record::write_file), Previous::Running(_)));
    child.kill().unwrap();
    child.wait().unwrap();
    let owned = vec!["sessions".to_owned()];
    match settle_previous(&files, &owned, &record::write_file) {
        Previous::Died(d) => assert_eq!((d.owner.epoch, d.owned), (1, owned.clone())),
        other => panic!("{other:?}"),
    }
    // Settled once: a second look reads the end it wrote.
    assert!(matches!(settle_previous(&files, &owned, &record::write_file), Previous::Ended(..)));
    assert_eq!(files.budget.today().faults, 1);
    assert_eq!(death::read_all(&files.deaths).len(), 1);

    // This process takes over, then stops on purpose.
    let me = record::claim_current_with(&files.owner, &record::write_file).unwrap();
    mark(&files, me.epoch, StopCause::Intentional("shutdown".into()), &record::write_file).unwrap();
    match settle_previous(&files, &owned, &record::write_file) {
        Previous::Ended(r, m) => {
            assert_eq!(r.epoch, 2);
            assert_eq!(m.cause, StopCause::Intentional("shutdown".into()));
        }
        other => panic!("{other:?}"),
    }
    let ledger = files.budget.today();
    assert_eq!((ledger.stops, ledger.faults), (2, 1));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_record_from_an_earlier_boot_is_named_as_the_host_restart() {
    let dir = std::env::temp_dir().join(format!("supervise-ends-boot-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let files = Files::new(&dir, "daemon", 5);
    let mut who = crate::identity::current().unwrap();
    who.boot_id = "an-earlier-boot".into();
    let rec = OwnerRecord::new(who, None, vec!["daemon".into()]);
    record::store(&files.owner, &rec).unwrap();
    match settle_previous(&files, &[], &record::write_file) {
        Previous::Died(d) => {
            let StopCause::Died(why) = &d.cause else { panic!("{:?}", d.cause) };
            assert!(why.contains("host's restart"), "{why}");
            assert!(why.contains("an-earlier-boot"), "{why}");
        }
        other => panic!("{other:?}"),
    }
    let _ = std::fs::remove_dir_all(&dir);

    // Same boot: a death of the process itself, never a host restart.
    let same = OwnerRecord { boot_id: "b1".into(), ..rec };
    assert!(!died_reason(&same, Some("b1")).contains("host's restart"));
    assert!(died_reason(&same, Some("b2")).contains("boot b1 ended; now boot b2"));
    assert!(!died_reason(&same, None).contains("host's restart"));
}
