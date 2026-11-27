use super::*;

fn begun(workspace: &str, travels: bool, machine: Option<&str>) -> Option<Move> {
    step(
        None,
        Event::Begin {
            workspace: Some(workspace.into()),
            travels,
            machine: machine.map(Into::into),
        },
    )
}

#[test]
fn a_drops_machine_stays_when_the_run_begins_without_one() {
    let dropped = begun("w", true, Some("m-1"));
    let run = step(
        dropped,
        Event::Begin { workspace: Some("other".into()), travels: false, machine: None },
    );
    assert_eq!(
        run,
        Some(Move {
            workspace: Some("w".into()),
            travels: true,
            machine: Some("m-1".into()),
            ..Move::default()
        })
    );
}

#[test]
fn the_run_names_the_machine_and_an_unknown_move_stays_unknown() {
    assert_eq!(
        step(begun("w", true, None), Event::Reach { machine: "m-2".into() })
            .unwrap()
            .machine
            .as_deref(),
        Some("m-2")
    );
    assert_eq!(step(None, Event::Reach { machine: "m-2".into() }), None);
}

#[test]
fn the_bar_never_runs_back_and_stays_in_bounds() {
    let half =
        step(begun("w", true, None), Event::Show { line: "2 of 4".into(), fraction: Some(0.5) });
    let back = step(half, Event::Show { line: "3 of 4".into(), fraction: Some(0.45) }).unwrap();
    assert_eq!((back.line.as_deref(), back.fraction), (Some("3 of 4"), Some(0.5)));
    let over =
        step(Some(back), Event::Show { line: "4 of 4".into(), fraction: Some(7.0) }).unwrap();
    assert_eq!(over.fraction, Some(1.0));
    assert_eq!(
        step(Some(over), Event::Show { line: "x".into(), fraction: None }).unwrap().fraction,
        Some(1.0)
    );
}

#[test]
fn a_travelled_row_waits_after_landing_until_its_workspace_leaves() {
    let landed = step(begun("w", true, Some("m-1")), Event::Landed);
    assert!(landed.as_ref().is_some_and(|landed| landed.landed));
    let ended = step(landed, Event::End);
    assert!(ended.is_some(), "the run's end keeps a landed row");
    assert_eq!(step(ended, Event::Left), None);
}

#[test]
fn a_row_that_stayed_or_a_failed_move_ends_at_once() {
    assert_eq!(step(begun("w", false, Some("m-1")), Event::Landed), None);
    assert_eq!(step(begun("w", true, Some("m-1")), Event::End), None);
}

#[test]
fn a_new_move_after_a_landing_starts_afresh() {
    let landed = step(begun("w", true, Some("m-1")), Event::Landed);
    let again =
        step(landed, Event::Begin { workspace: Some("v".into()), travels: false, machine: None })
            .unwrap();
    assert_eq!(again, Move { workspace: Some("v".into()), ..Move::default() });
}
