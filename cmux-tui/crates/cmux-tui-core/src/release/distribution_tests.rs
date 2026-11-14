/// What the binary installs is what `DISTRIBUTION_VERSION` was when this
/// crate read the stamp itself: a release as stamped, anything else the
/// workspace crate version.
#[test]
fn only_a_release_stamp_is_reported_as_the_release() {
    use super::release_or_workspace;
    assert_eq!(release_or_workspace(Some("0.13.4")), "0.13.4");
    assert_eq!(release_or_workspace(Some("0.0.0-r2.sha-abc")), env!("CARGO_PKG_VERSION"));
    assert_eq!(release_or_workspace(Some("")), env!("CARGO_PKG_VERSION"));
    assert_eq!(release_or_workspace(None), env!("CARGO_PKG_VERSION"));
}
