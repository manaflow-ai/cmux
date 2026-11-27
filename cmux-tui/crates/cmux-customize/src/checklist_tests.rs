use super::*;
use serde_json::json;

fn run(settings: Value, keybindings: usize, library_on: usize, connected: &[&str]) -> Checklist {
    let connected: BTreeSet<String> = connected.iter().map(|name| (*name).to_owned()).collect();
    checklist(&Inputs {
        settings: &settings,
        default_of: &schema_reads::default_of,
        keys_under: &schema_reads::keys_under,
        keybindings,
        library_on,
        connected: &connected,
    })
}

fn done(list: &Checklist) -> Vec<&'static str> {
    list.steps.iter().filter(|step| step.done).map(|step| step.id).collect()
}

#[test]
fn a_fresh_install_has_every_step_left_and_is_on() {
    let list = run(json!({}), 0, 0, &[]);
    assert!(list.enabled);
    assert_eq!(list.done, 0);
    assert_eq!(list.total, STEPS.len());
    assert_eq!(list.next, Some("theme"));
    assert!(list.total >= 10, "at least the ten steps of the ask");
}

#[test]
fn a_setting_that_differs_from_its_default_marks_its_step() {
    let list = run(json!({"appearance": {"theme": "Nord"}, "terminal.fontSize": 15}), 0, 0, &[]);
    assert_eq!(done(&list), ["theme", "terminalFont"]);
    assert_eq!(list.steps[0].done_by, Some(DoneBy::Setting));
    assert_eq!(list.next, Some("look"));
}

#[test]
fn a_setting_written_back_to_its_default_does_not_count() {
    // appearance.density defaults to "cozy"; sidebar.side to "left".
    let list = run(json!({"appearance.density": "cozy", "sidebar": {"side": "left"}}), 0, 0, &[]);
    assert_eq!(list.done, 0);
    let list = run(json!({"sidebar": {"side": "right"}}), 0, 0, &[]);
    assert_eq!(done(&list), ["sidebar"]);
}

#[test]
fn a_prefix_step_counts_any_row_under_it() {
    let list = run(json!({"notifications": {"sounds": {"volume": 0.5}}}), 0, 0, &[]);
    assert_eq!(done(&list), ["notifications"]);
}

#[test]
fn bindings_the_library_and_connections_mark_their_steps() {
    let list = run(json!({}), 2, 1, &["github", "mcp"]);
    assert_eq!(done(&list), ["look", "shortcut", "mcp", "github"]);
    let github = list.steps.iter().find(|step| step.id == "github").unwrap();
    assert_eq!(github.done_by, Some(DoneBy::Connected));
}

#[test]
fn any_step_can_be_checked_off_by_hand_and_unknown_ids_are_ignored() {
    let list =
        run(json!({"customize": {"checklist": {"done": ["phone", "gone-step", 3]}}}), 0, 0, &[]);
    assert_eq!(done(&list), ["phone"]);
    assert_eq!(list.steps.last().unwrap().done_by, Some(DoneBy::Checked));
    // A derived step wins over the hand check: it says why it is done.
    let list = run(json!({"customize.checklist.done": ["github"]}), 0, 0, &["github"]);
    let github = list.steps.iter().find(|step| step.id == "github").unwrap();
    assert_eq!(github.done_by, Some(DoneBy::Connected));
}

#[test]
fn dismissing_turns_it_off_and_everything_done_has_no_next() {
    let all: Vec<&str> = STEPS.iter().map(|step| step.id).collect();
    let list = run(json!({"customize.checklist": {"enabled": false, "done": all}}), 0, 0, &[]);
    assert!(!list.enabled);
    assert_eq!((list.done, list.total, list.next), (list.total, STEPS.len(), None));
}

#[test]
fn setting_reads_nested_flat_and_mixed_paths() {
    let settings = json!({"a": {"b.c": 1, "d": {"e": 2}}, "f.g": 3});
    assert_eq!(setting(&settings, "a.b.c"), Some(&json!(1)));
    assert_eq!(setting(&settings, "a.d.e"), Some(&json!(2)));
    assert_eq!(setting(&settings, "f.g"), Some(&json!(3)));
    assert_eq!(setting(&settings, "a.x"), None);
}

#[test]
fn ids_are_unique_and_every_watched_key_is_a_settings_row() {
    let ids: BTreeSet<&str> = STEPS.iter().map(|step| step.id).collect();
    assert_eq!(ids.len(), STEPS.len());
    let schema = cmux_config::Schema::embedded();
    for step in STEPS {
        assert!(step.title.key.starts_with("settingsPage.customizeProgress.step."));
        assert!(step.route.starts_with("/settings/"), "{}", step.id);
        if let Watch::Settings(keys) = step.watch {
            for key in keys {
                let known = if key.ends_with('.') {
                    !schema_reads::keys_under(key).is_empty()
                } else {
                    schema.row(key).is_some()
                };
                assert!(known, "step {} watches {key}, which no settings row has", step.id);
            }
        }
    }
    assert_eq!(facts().collect::<Vec<_>>(), ["models", "mcp", "github", "phone"]);
}

#[test]
fn the_checklist_keys_match_the_schema() {
    let schema = cmux_config::Schema::embedded();
    let enabled = schema.row(ENABLED_KEY).expect("customize.checklist.enabled row");
    assert_eq!(enabled.default, Some(json!(ENABLED_DEFAULT)));
    let done = schema.row(DONE_KEY).expect("customize.checklist.done row");
    assert_eq!(done.default, Some(json!([])));
}
