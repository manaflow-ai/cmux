use super::*;

#[test]
fn each_build_kind_has_its_room() {
    assert_eq!(default_for(BuildKind::Release), Some(PRODUCTION));
    assert_eq!(default_for(BuildKind::Rc), Some(PRODUCTION));
    assert_eq!(default_for(BuildKind::Nightly), Some(STAGING));
    assert_eq!(default_for(BuildKind::Staging), Some(STAGING));
    assert_eq!(default_for(BuildKind::Dev), Some(DEVELOPMENT));
    assert_eq!(default_for(BuildKind::Unbundled), None);
}

#[test]
fn a_cloud_machine_uses_the_room_of_its_provisioned_platform() {
    assert_eq!(cloud_machine_room(Some(DEVELOPMENT)), Some(DEVELOPMENT));
    assert_eq!(cloud_machine_room(Some(&format!("{STAGING}/"))), Some(STAGING));
    assert_eq!(cloud_machine_room(Some(PRODUCTION)), Some(PRODUCTION));
    assert_eq!(cloud_machine_room(Some("https://evil.example")), None);
    assert_eq!(cloud_machine_room(Some("")), None);
    assert_eq!(cloud_machine_room(None), None);
}

#[test]
fn each_build_names_the_scheme_it_registers() {
    use crate::app_identity::AppIdentity;
    let app = |bundle: Option<&str>, tag: Option<&str>| AppIdentity {
        bundle_id: bundle.map(str::to_owned),
        tag: tag.map(str::to_owned),
        socket_override: None,
        shipped_tag: tag.map(str::to_owned),
    };
    let cases = [
        (app(Some("com.cmuxterm.app.nightly"), None), "cmux-nightly"),
        (app(Some("com.cmuxterm.app"), None), "cmux"),
        (app(Some("com.cmuxterm.app.rc"), None), "cmux-rc"),
        (app(Some("com.cmuxterm.app.debug.next"), None), "cmux-next-dev"),
        (app(Some("com.cmuxterm.app.debug"), None), "cmux-dev"),
        (
            app(Some("com.cmuxterm.app.debug.share.links"), Some("share-links")),
            "cmux-dev-share-links",
        ),
        (app(None, Some("share-links")), "cmux-dev-share-links"),
    ];
    for (identity, scheme) in cases {
        assert_eq!(scheme_of(&identity, None), scheme, "{identity:?}");
    }
    // The bundle's own setting wins (cmux NIGHTLY's LSEnvironment), unless it cannot be a scheme.
    let nightly = app(Some("com.cmuxterm.app.nightly"), None);
    assert_eq!(scheme_of(&nightly, Some("cmux-nightly")), "cmux-nightly");
    assert_eq!(scheme_of(&nightly, Some("1 bad")), "cmux-nightly");
}

/// The room the person names in `CMUX_SHARE_ROOM_URL` passes the egress gate in enforce
/// mode; a host nobody named is still refused.
#[test]
fn the_named_room_passes_the_gate() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let host = "room-share-room-test.org";
    assert!(cmux_egress::check(host, "test").is_err());
    assert_eq!(named_room(&format!(" https://{host} ")), format!("https://{host}"));
    assert!(cmux_egress::check(host, "test").is_ok());
    assert_eq!(named_room(" "), "");
    assert!(cmux_egress::check("unrelated-room-share-room-test.org", "test").is_err());
}
