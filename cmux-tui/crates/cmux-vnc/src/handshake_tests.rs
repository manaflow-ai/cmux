use super::*;

#[test]
fn versions_negotiate_like_real_servers() {
    assert_eq!(Version::negotiate(b"RFB 003.008\n").unwrap(), Version::V3_8);
    assert_eq!(Version::negotiate(b"RFB 003.889\n").unwrap(), Version::V3_8, "macOS");
    assert_eq!(Version::negotiate(b"RFB 003.007\n").unwrap(), Version::V3_7);
    assert_eq!(Version::negotiate(b"RFB 003.006\n").unwrap(), Version::V3_3, "UltraVNC 1.0");
    assert_eq!(Version::negotiate(b"RFB 003.003\n").unwrap(), Version::V3_3);
    assert_eq!(Version::negotiate(b"RFB 004.001\n").unwrap(), Version::V3_8);
    assert!(Version::negotiate(b"SSH-2.0-Open").is_err());
}
