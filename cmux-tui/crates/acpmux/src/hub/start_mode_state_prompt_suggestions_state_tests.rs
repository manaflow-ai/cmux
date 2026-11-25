use super::StartModeState;

/// A forced `agents.promptSuggestions` survives a save and load (a daemon restart before the
/// app pushes again), and a file written before the field existed loads as nothing forced.
#[test]
fn the_forced_prompt_suggestions_value_round_trips_and_an_older_file_forces_nothing() {
    let state = StartModeState { prompt_suggestions_managed: Some(false), ..Default::default() };
    let saved = serde_json::to_vec(&state).unwrap();
    let loaded: StartModeState = serde_json::from_slice(&saved).unwrap();
    assert_eq!(loaded.prompt_suggestions_managed, Some(false));
    let older: StartModeState =
        serde_json::from_str(r#"{"managed":null,"fullAccessManaged":false}"#).unwrap();
    assert_eq!(older.prompt_suggestions_managed, None);
    assert_eq!(older.full_access_managed, Some(false));
}
