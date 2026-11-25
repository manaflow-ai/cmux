use super::*;

fn config() -> BrainsConfig {
    BrainsConfig {
        executable: PathBuf::new(),
        home: PathBuf::from("/tmp/chief-home"),
        app: AppValues::default(),
    }
}

/// A named Chief's brain (and the Chief acpmux it shares) starts from an empty environment:
/// the owner's build space must reach it, or a dev build's Chief talks to nightly's backend.
#[test]
fn a_named_chief_brain_keeps_the_owners_build_space() {
    let inherited = |key: &str| (key == "CMUX_BUILD_SPACE").then(|| "dev:my-tag".to_owned());
    let env = brain_environment(&config(), "c1", None, &inherited);
    assert_eq!(env.get("CMUX_BUILD_SPACE").map(String::as_str), Some("dev:my-tag"));
}

/// An owner refused a space (`unusable`): the brain keeps the refusal, never drops to nightly.
#[test]
fn an_unusable_build_space_reaches_the_brain_as_is() {
    let inherited = |key: &str| (key == "CMUX_BUILD_SPACE").then(|| "unusable".to_owned());
    let env = brain_environment(&config(), "c1", None, &inherited);
    assert_eq!(env.get("CMUX_BUILD_SPACE").map(String::as_str), Some("unusable"));
}

#[test]
fn a_nightly_owners_brain_gets_no_build_space() {
    let env = brain_environment(&config(), "c1", None, &|_| None);
    assert!(!env.contains_key("CMUX_BUILD_SPACE"));
}
