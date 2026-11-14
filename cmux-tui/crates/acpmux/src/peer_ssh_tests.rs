use super::*;

#[test]
fn only_known_failure_classes_leave_the_stderr_capture() {
    assert_eq!(reason(b"banner: secret-token"), None);
    assert_eq!(
        reason(b"secret-token: Permission denied (publickey)."),
        Some("Permission denied (SSH authentication failed)")
    );
    let mut huge = vec![b'x'; LIMIT];
    huge.extend_from_slice(b"Permission denied");
    assert_eq!(reason(&huge), None, "diagnostics are bounded");
}
