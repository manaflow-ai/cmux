//! The link's Cloud tunnel inputs: the device install key and where a token may go.

use std::os::unix::fs::PermissionsExt as _;

use super::*;

#[test]
fn the_install_key_is_made_once_owner_only_and_kept() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(INSTALL_KEY_FILE);
    let made = load_or_create_install_key(&path).unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let again = load_or_create_install_key(&path).unwrap();
    assert_eq!(made.public_spki(), again.public_spki(), "the platform knows the device by it");
}

#[test]
fn an_install_key_file_that_is_not_one_is_refused_never_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(INSTALL_KEY_FILE);
    std::fs::write(&path, b"not a key").unwrap();
    assert!(load_or_create_install_key(&path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"not a key");

    let link = dir.path().join("linked.key");
    std::os::unix::fs::symlink(&path, &link).unwrap();
    assert!(load_or_create_install_key(&link).is_err(), "a symlink is never followed");
}

/// The hub goes where the app's own dial looks, whichever build's state directory
/// the link is on (launchd gives `serve` no `CMUX_TUI_STATE_DIR`).
#[test]
fn the_hub_socket_is_beside_the_links_own_state_directory() {
    let nightly = Path::new("/Users/me/Library/Application Support/cmux-tui-nightly/sessions/link");
    assert_eq!(
        hub_socket(nightly),
        Some(PathBuf::from(
            "/Users/me/Library/Application Support/cmux-tui-nightly/sessions/carrier/tunnel.sock"
        ))
    );
    assert_eq!(hub_socket(Path::new("/tmp/some-link-state")), None, "not an app's link");
}

#[test]
fn a_token_goes_only_to_the_platform_of_the_deployment_that_issued_it() {
    use cmux_cloud_environment as env;
    let (prod, staging) = (env::PRODUCTION_DEPLOYMENT, env::STAGING_DEPLOYMENT);
    assert!(same_deployment(prod.platform_origin, prod.api_origin));
    assert!(same_deployment(&format!("{}/", prod.platform_origin), prod.api_origin));
    assert!(!same_deployment(prod.platform_origin, staging.api_origin));
    assert!(!same_deployment(staging.platform_origin, prod.api_origin));
    assert!(same_deployment("http://127.0.0.1:8787", "http://localhost:9000"));
    assert!(!same_deployment("https://platform.example", "https://api.example"));
    assert!(!same_deployment("http://127.0.0.1:8787", prod.api_origin));
}
