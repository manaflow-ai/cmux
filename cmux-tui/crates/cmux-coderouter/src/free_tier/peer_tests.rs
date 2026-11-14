use super::*;

#[test]
fn a_peer_the_host_cannot_read_is_never_the_provider() {
    assert!(!provider_peer_allowed(&ProviderPeer::refused()));
}

/// Off macOS there is no app check: a same-user peer read at accept,
/// before the split, may be the provider.
#[cfg(all(unix, not(target_os = "macos")))]
#[tokio::test]
async fn a_same_user_unix_peer_read_at_accept_may_be_the_provider() {
    let (stream, _other) = tokio::net::UnixStream::pair().expect("socket pair");
    let peer = ProviderPeer::of_unix(&stream);
    let (_read, _write) = stream.into_split();
    assert!(provider_peer_allowed(&peer));
}
