//! ActionContractTests (`Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/ActionContractTests.swift`),
//! checked in this crate so a catalog row breaks here and not only after the app FFI is re-pinned.
//! c4736440a47 added `home.meetChief` with no `cli_name`; nothing failed until the Swift suite ran
//! on the re-pin.
use std::collections::HashMap;

/// `ActionContractTests.topLevelVerbs` and `nestedNames`: the CLI names that are not `noun verb`.
const NOT_NOUN_VERB: &[(&str, &str)] =
    &[("remote.openRemote", "open-remote"), ("home.createChannel", "chat channel create")];

/// `everyActionHasAUniqueNounVerbCLIName`: every action has a lowercase `noun verb` CLI name
/// no other action uses.
#[test]
fn every_action_has_a_unique_noun_verb_cli_name() {
    let mut seen: HashMap<&str, &str> = HashMap::new();
    for action in cmux_action_catalog::actions() {
        let name = action.cli_name;
        assert!(!name.is_empty(), "{}: no cli_name", action.id);
        match NOT_NOUN_VERB.iter().find(|(id, _)| *id == action.id) {
            Some((_, expected)) => assert_eq!(name, *expected, "{}", action.id),
            None => assert_eq!(
                name.split(' ').count(),
                2,
                "{}: cli_name {name:?} is not `noun verb`",
                action.id
            ),
        }
        assert_eq!(name, name.to_lowercase(), "{}: cli_name {name:?} is not lowercase", action.id);
        if let Some(other) = seen.insert(name, action.id) {
            panic!("cli_name {name:?} used by {other} and {}", action.id);
        }
    }
}

/// `everyActionIsInThePaletteUnlessExempt`'s per-row rule: a row the palette hides is
/// `paletteInternal` exactly when it requires `paletteOpen`.
#[test]
fn palette_internal_rows_are_the_ones_that_require_an_open_palette() {
    for action in cmux_action_catalog::actions().filter(|action| !action.is_palette_visible()) {
        let internal =
            action.surface_plan.palette == cmux_action_catalog::Decision::Exempt("paletteInternal");
        assert_eq!(internal, action.requires.contains(&"paletteOpen"), "{}", action.id);
    }
}
