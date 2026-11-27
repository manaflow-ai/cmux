use super::*;

fn app(id: &str) -> TargetApp {
    TargetApp { id: id.into(), name: id.into() }
}

fn req<'a>(access: Access, target: Option<&'a TargetApp>, origin: &'a OriginKind) -> Request<'a> {
    Request { access, target, origin, foreground: false, session_granted: false }
}

#[test]
fn full_access_is_the_default_and_allows_ordinary_apps() {
    let config = PolicyConfig::default();
    assert_eq!(config.mode, Mode::FullAccess);
    let safari = app("com.apple.Safari");
    let d = decide(
        &config,
        &SavedApprovals::default(),
        &req(Access::Act, Some(&safari), &OriginKind::Local),
    );
    assert_eq!(d, Decision::Allow);
}

/// Leo, 2026-11-22, on "Computer Use isn't allowed to act there.": "why
/// not. it should be able to". cmux and terminals are usable by default;
/// password managers and System Settings stay denied, and cmux Remote
/// (where Computer Use's own approval prompt shows) stays protected.
#[test]
fn agents_act_in_cmux_and_terminals_by_default_but_not_in_password_managers() {
    let config = PolicyConfig::default();
    let saved = SavedApprovals::default();
    let act = |id: &str| {
        let target = app(id);
        decide(&config, &saved, &req(Access::Act, Some(&target), &OriginKind::Local))
    };
    for id in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.debug.my-tag",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "windowsterminal.exe",
        "org.gnome.Terminal",
    ] {
        assert_eq!(act(id), Decision::Allow, "{id}");
    }
    for id in ["com.1password.1password", "com.apple.keychainaccess", "com.apple.systempreferences"]
    {
        assert_eq!(act(id), Decision::Refuse(Refusal::Denied), "{id}");
    }
    for id in ["com.cmuxterm.remote", "com.cmuxterm.remote.dev", "com.apple.securityagent"] {
        assert_eq!(act(id), Decision::Refuse(Refusal::Protected), "{id}");
    }
    for id in retired_default_denied_apps() {
        assert!(!default_denied_apps().contains(id), "{id}");
    }
}

#[test]
fn a_copy_of_the_earlier_default_drops_terminals_and_cmux_and_keeps_the_persons_entries() {
    let mut earlier: Vec<String> = default_denied_apps()
        .iter()
        .chain(retired_default_denied_apps())
        .map(|s| (*s).to_string())
        .collect();
    earlier.push("name:Diary".into());
    let mut want: Vec<String> = default_denied_apps().iter().map(|s| (*s).to_string()).collect();
    want.push("name:Diary".into());
    assert_eq!(migrate_denied_apps(earlier), want);
    // The person removed one retired entry already: their list, kept as is.
    let shaped: Vec<String> =
        retired_default_denied_apps().iter().skip(1).map(|s| (*s).to_string()).collect();
    assert_eq!(migrate_denied_apps(shaped.clone()), shaped);
    assert!(migrate_denied_apps(vec![]).is_empty());
}

#[test]
fn deny_list_beats_full_access_and_always() {
    let config = PolicyConfig::default();
    let mut saved = SavedApprovals::default();
    saved.set_always("com.1password.1password");
    let one = app("com.1password.1password");
    let d = decide(&config, &saved, &req(Access::Observe, Some(&one), &OriginKind::Local));
    assert_eq!(d, Decision::Refuse(Refusal::Denied));
}

#[test]
fn protected_apps_are_refused_even_with_an_empty_deny_list() {
    let config = PolicyConfig::cloud_vm();
    let agent = app("com.apple.SecurityAgent");
    let d = decide(
        &config,
        &SavedApprovals::default(),
        &req(Access::Act, Some(&agent), &OriginKind::Local),
    );
    assert_eq!(d, Decision::Refuse(Refusal::Protected));
}

#[test]
fn look_only_refuses_acting_but_allows_observing() {
    let config = PolicyConfig { mode: Mode::LookOnly, ..PolicyConfig::default() };
    let s = app("com.apple.Safari");
    let saved = SavedApprovals::default();
    assert_eq!(
        decide(&config, &saved, &req(Access::Observe, Some(&s), &OriginKind::Local)),
        Decision::Allow
    );
    assert_eq!(
        decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
        Decision::Refuse(Refusal::LookOnly)
    );
}

#[test]
fn approved_apps_asks_once_then_remembers() {
    let config = PolicyConfig { mode: Mode::ApprovedApps, ..PolicyConfig::default() };
    let s = app("com.apple.Safari");
    let mut saved = SavedApprovals::default();
    assert_eq!(
        decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
        Decision::Ask { remember: true }
    );
    saved.set_always(&s.id);
    assert_eq!(
        decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
        Decision::Allow
    );
    saved.set_never(&s.id);
    assert_eq!(
        decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
        Decision::Refuse(Refusal::NeverAllowed)
    );
}

#[test]
fn remote_needs_same_account_and_the_setting() {
    let mut config = PolicyConfig::default();
    let s = app("com.apple.Safari");
    let saved = SavedApprovals::default();
    let foreign = OriginKind::Remote { machine: "m".into(), same_account: false };
    assert_eq!(
        decide(&config, &saved, &req(Access::Discover, None, &foreign)),
        Decision::Refuse(Refusal::ForeignAccount)
    );
    let mine = OriginKind::Remote { machine: "m".into(), same_account: true };
    assert_eq!(decide(&config, &saved, &req(Access::Act, Some(&s), &mine)), Decision::Allow);
    config.allow_own_machines = false;
    assert_eq!(
        decide(&config, &saved, &req(Access::Act, Some(&s), &mine)),
        Decision::Refuse(Refusal::RemoteNotAllowed)
    );
}

#[test]
fn foreground_needs_its_setting() {
    let config = PolicyConfig::default();
    let s = app("com.apple.Safari");
    let r = Request {
        access: Access::Act,
        target: Some(&s),
        origin: &OriginKind::Local,
        foreground: true,
        session_granted: false,
    };
    assert_eq!(
        decide(&config, &SavedApprovals::default(), &r),
        Decision::Refuse(Refusal::ForegroundNotAllowed)
    );
    assert_eq!(decide(&PolicyConfig::cloud_vm(), &SavedApprovals::default(), &r), Decision::Allow);
}

#[test]
fn earlier_build_modes_read_as_the_nearest_mode() {
    assert_eq!(Mode::parse("standard"), Some(Mode::FullAccess));
    assert_eq!(Mode::parse("unrestricted"), Some(Mode::FullAccess));
    assert_eq!(Mode::parse("bounded"), Some(Mode::ApprovedApps));
    assert_eq!(Mode::parse("ask"), Some(Mode::AskEveryTime));
    assert_eq!(Mode::parse("god"), None);
}

#[test]
fn matchers() {
    let a = TargetApp { id: "com.agilebits.onepassword7".into(), name: "1Password 7".into() };
    assert!(AppMatcher::parse("com.agilebits.onepassword*").unwrap().matches(&a));
    assert!(AppMatcher::parse("name:1password 7").unwrap().matches(&a));
    assert!(!AppMatcher::parse("com.agilebits").unwrap().matches(&a));
}
