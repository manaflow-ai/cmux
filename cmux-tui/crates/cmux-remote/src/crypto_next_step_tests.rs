use super::*;

#[test]
fn a_refused_device_is_told_what_to_do_next() {
    for message in [
        "device has been revoked",
        "invitation is expired",
        "invitation was already claimed by another device",
    ] {
        let text = CryptoError::Unauthorized(message.into()).to_string();
        assert!(text.starts_with(&format!("authorization failed: {message}; ")), "{text}");
        assert!(text.contains("cmux remote enroll create"), "{text}");
        assert!(text.contains("cmux remote connect --invite-file"), "{text}");
    }
    let other = CryptoError::Unauthorized("no such invitation".into()).to_string();
    assert_eq!(other, "authorization failed: no such invitation");
}
