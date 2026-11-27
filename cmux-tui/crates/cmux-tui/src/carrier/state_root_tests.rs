use super::state_root_with;
use std::path::{Path, PathBuf};

fn root(vars: &[(&str, &str)], home: &Path) -> Option<PathBuf> {
    let env = |key: &str| vars.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned());
    state_root_with(env, None, Some(home), || Some(PathBuf::from("/default/sessions")))
}

#[test]
fn the_app_bundles_cmux_finds_the_hub_its_apps_link_serves() {
    let home = Path::new("/Users/u");
    let next = home.join("Library/Application Support/cmux-next");
    // A tagged DEV build (the same rule as cmux NEXT's NIGHTLY `tags/cmux-next/tui`).
    let root_of = root(&[("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug.nx9")], home);
    assert_eq!(root_of, Some(next.join("tags/nx9/tui")));
    // Its link's state directory is `<root>/link`, whose hub is the dial's.
    let link = next.join("tags/nx9/tui/link");
    assert_eq!(
        crate::link::carrier_tunnel::hub_socket(&link),
        root_of.map(|root| root.join("carrier").join("tunnel.sock"))
    );
    // An untagged DEV build: names of its key.
    assert_eq!(
        root(&[("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug")], home),
        Some(next.join("builds/com.cmuxterm.app.debug/tui"))
    );
}

#[test]
fn the_variable_release_and_no_app_keep_cmux_tuis_root() {
    let home = Path::new("/Users/u");
    let default = Some(PathBuf::from("/default/sessions"));
    let tagged = ("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug.nx9");
    assert_eq!(root(&[tagged, ("CMUX_TUI_STATE_DIR", "/given")], home), default);
    assert_eq!(root(&[("CMUX_BUNDLE_ID", "com.cmuxterm.app")], home), default);
    assert_eq!(root(&[], home), default);
}
