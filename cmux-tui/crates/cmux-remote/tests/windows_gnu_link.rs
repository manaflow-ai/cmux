#![cfg(windows)]

use cmux_remote::crypto::{StaticIdentity, public_key_fingerprint};

#[test]
fn windows_gnu_test_binary_links_and_runs_remote_crypto() {
    let identity = StaticIdentity::from_private([7; 32]);
    let public_key = identity.public_key();

    assert_eq!(identity.fingerprint(), public_key_fingerprint(&public_key));
}
