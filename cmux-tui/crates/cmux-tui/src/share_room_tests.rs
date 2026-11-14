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
