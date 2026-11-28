use super::*;

// MacScreenDefaultSharingTests.eachStateTakesItsStep
#[test]
fn each_state_takes_its_step() {
    use SharingStep::*;
    let step = default_sharing_step;
    assert_eq!(step(Some(false), true, true, Some(false)), TurnOn);
    assert_eq!(step(Some(false), true, true, Some(true)), None);
    assert_eq!(step(Some(true), true, false, Some(false)), TurnOff);
    assert_eq!(step(Some(true), true, false, Some(true)), TurnOff);
    assert_eq!(step(Some(false), true, false, Some(false)), None);
    assert_eq!(step(Option::None, true, true, Some(false)), None);
    assert_eq!(step(Some(true), false, false, Some(false)), None);
    assert_eq!(step(Some(false), true, true, Option::None), None);
    assert_eq!(step(Some(true), true, true, Some(false)), None);
}

// MacScreenDefaultSharingTests.theMachineRecordNamesTheState
#[test]
fn the_machine_record_names_the_state() {
    use SharingState::*;
    assert_eq!(sharing_state(true, true, false, false), NeedsGrant);
    assert_eq!(sharing_state(false, true, false, true), NeedsGrant);
    assert_eq!(sharing_state(true, true, true, false), On);
    assert_eq!(sharing_state(false, true, true, true), TurnedOff);
    assert_eq!(sharing_state(false, true, true, false), Off);
    assert_eq!(serde_json::to_value(NeedsGrant).unwrap(), "needs_grant");
    assert_eq!(serde_json::to_value(TurnedOff).unwrap(), "turned_off");
}
