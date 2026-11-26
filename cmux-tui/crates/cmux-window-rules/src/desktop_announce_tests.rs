use super::*;

/// What the default policy decides for an agent in another chat while cmux is
/// in front: it rings and posts a banner.
fn rings() -> Said {
    Said { attention: true, desktop: true, app_active: true, ..Said::default() }
}

/// Kinds follow the agent's level, and only agents are said.
#[test]
fn kinds_follow_the_agents_level_and_only_agents_are_said() {
    assert_eq!(kind("warning", Some("agent")), Some(Kind::NeedsYou));
    assert_eq!(kind("error", Some("agent")), Some(Kind::Failed));
    assert_eq!(kind("info", Some("agent")), Some(Kind::Finished));
    assert_eq!(kind("warning", Some("terminal")), None);
    assert_eq!(kind("info", None), None);
    assert_eq!(kind("debug", Some("agent")), None);
}

/// Said when no banner shows while cmux is in front (`whenInactive`, `never`,
/// or the poster asked for none).
#[test]
fn said_when_no_banner_shows_while_cmux_is_in_front() {
    assert!(speaks(Said { desktop: false, ..rings() }));
}

/// A banner that shows is not said again, but a denied one is.
#[test]
fn a_banner_that_shows_is_not_said_again_but_a_denied_one_is() {
    assert!(!speaks(rings()));
    assert!(speaks(Said { banners_denied: true, ..rings() }));
}

/// Silent for a viewed pane, a muted workspace, a read-on-sight arrival or
/// cmux in back.
#[test]
fn silent_for_a_viewed_pane_a_muted_workspace_or_cmux_in_back() {
    let quiet = Said { desktop: false, ..rings() };
    assert!(!speaks(Said { pane_is_viewed: true, ..quiet }));
    assert!(!speaks(Said { attention: false, ..quiet }), "muted: the decision does not ring");
    assert!(!speaks(Said { acknowledge: true, ..quiet }));
    assert!(!speaks(Said { app_active: false, banners_denied: true, ..quiet }));
}
